#!/usr/bin/env node
// Deploys the Dyma escrow (docs/RUNBOOK.md §3):
//   1. the registry: spends the seed, mints the registry NFT and writes the configuration;
//   2. one reference script per validator, held at the registry address under governance;
//   3. the reward accounts of campaign_payout and campaign_admin (their zero-ADA withdrawals).
// Every confirmed step is written to deployments/<network>.json; a re-run resumes from there.
//
// Usage: node deploy.mjs --network <preprod|preview|mainnet> --wallet <mnemonic file> [--plan]
//   --plan  prints the scripts, addresses and deposits, and builds and evaluates the registry
//           transaction without submitting anything.
// The wallet file holds the deployer's 24 words; they are never printed.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { MeshTxBuilder, MeshWallet, getOutputMinLovelace } from '@meshsdk/core';
import { loadConfig, registryDatum } from './lib/config.mjs';
import { Koios } from './lib/koios.mjs';
import { constr, utf8Hex } from './lib/plutus.mjs';
import { SCRIPT_NAMES, escrowScripts, loadBlueprint } from './lib/scripts.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const REGISTRY_NFT = utf8Hex('dyma-registry');
const COLLATERAL = '5000000';

const { values: args } = parseArgs({
  options: {
    network: { type: 'string' },
    wallet: { type: 'string' },
    plan: { type: 'boolean', default: false },
    'confirm-mainnet': { type: 'boolean', default: false },
  },
});
const network = args.network;
if (!['preprod', 'preview', 'mainnet'].includes(network) || !args.wallet) {
  console.error('usage: node deploy.mjs --network <preprod|preview|mainnet> --wallet <mnemonic file> [--plan]');
  process.exit(2);
}
if (network === 'mainnet' && !args.plan && !args['confirm-mainnet']) {
  console.error('mainnet: run --plan first, then deploy with --confirm-mainnet');
  process.exit(2);
}
const networkId = network === 'mainnet' ? 1 : 0;
const configFile = path.join(ROOT, 'deployments', `${network}.config.json`);
const recordFile = path.join(ROOT, 'deployments', `${network}.json`);
const ada = (lovelace) => `${(Number(lovelace) / 1e6).toFixed(2)} ADA`;

// ## The blueprint must be the committed build.
const git = (...a) => execFileSync('git', ['-C', ROOT, ...a], { encoding: 'utf8' }).trim();
const dirty = git('status', '--porcelain', '--', 'plutus.json', 'aiken.toml', 'aiken.lock', 'validators', 'lib');
if (dirty && !args.plan) {
  console.error(`commit the contracts before deploying:\n${dirty}`);
  process.exit(1);
}
const blueprint = loadBlueprint(path.join(ROOT, 'plutus.json'));
const config = loadConfig(configFile, network);

// ## Deployer wallet and chain.
const words = fs.readFileSync(args.wallet, 'utf8').trim().split(/\s+/);
if (![12, 15, 24].includes(words.length)) throw new Error('the wallet file must hold a 12, 15 or 24-word mnemonic');
const koios = new Koios(network);
const wallet = new MeshWallet({
  networkId,
  fetcher: koios.provider,
  submitter: koios.provider,
  key: { type: 'mnemonic', words },
});
await wallet.init();
const deployer = await wallet.getChangeAddress();
const { params, costModels } = await koios.protocol();

// ## Resume or start a record.
let record = fs.existsSync(recordFile) ? JSON.parse(fs.readFileSync(recordFile, 'utf8')) : null;
if (record?.status === 'deployed') {
  console.log(`${network} is already deployed (${path.relative(ROOT, recordFile)}). Run verify.mjs.`);
  process.exit(0);
}
let utxos = await koios.utxos(deployer);
const pureAda = (u) => u.output.amount.every((a) => a.unit === 'lovelace') && !u.output.plutusData && !u.output.scriptRef;
let seed = record ? { txHash: record.seed.tx_hash, outputIndex: record.seed.index } : null;
if (!seed) {
  const [largest] = utxos.filter(pureAda).sort((a, b) => Number(BigInt(b.output.amount[0].quantity) - BigInt(a.output.amount[0].quantity)));
  if (!largest) throw new Error(`the deployer ${deployer} holds no ADA`);
  seed = largest.input;
}

const scripts = escrowScripts(blueprint, seed, networkId);
const escrow = { policy: scripts.campaign_policy.hash, state: scripts.campaign_state.hash, shard: scripts.campaign_shard.hash };
const datum = registryDatum(config, escrow);
const nftUnit = scripts.registry.hash + REGISTRY_NFT;

if (record) {
  for (const name of SCRIPT_NAMES) {
    if (record.scripts[name].hash !== scripts[name].hash) {
      throw new Error(`${name} differs from the recorded deployment: the blueprint changed since ${record.commit}`);
    }
  }
  if (JSON.stringify(record.configuration) !== JSON.stringify(config)) {
    throw new Error(`${path.relative(ROOT, configFile)} changed since the deployment started`);
  }
} else {
  record = {
    network,
    status: 'in progress',
    commit: git('rev-parse', 'HEAD'),
    compiler: blueprint.preamble.compiler.version,
    seed: { tx_hash: seed.txHash, index: seed.outputIndex },
    registry: { policy_id: scripts.registry.hash, address: scripts.registry.address, utxo: null },
    scripts: Object.fromEntries(
      SCRIPT_NAMES.map((name) => {
        const { hash, size, address, reward_address } = scripts[name];
        return [name, { hash, size, ...(address && { address }), ...(reward_address && { reward_address }), reference: null }];
      }),
    ),
    escrow,
    configuration: config,
    transactions: {},
  };
}
const save = () => fs.writeFileSync(recordFile, JSON.stringify(record, null, 2) + '\n');

function builder() {
  const tx = new MeshTxBuilder({ fetcher: koios.provider, evaluator: koios.provider, params });
  tx.setNetwork(costModels);
  return tx;
}

async function submit(label, unsigned) {
  const signed = await wallet.signTx(unsigned);
  const txHash = await koios.submit(signed);
  console.log(`${label}: submitted ${txHash}, waiting for a confirmation…`);
  await koios.confirm(txHash);
  console.log(`${label}: confirmed`);
  return txHash;
}

async function outputIndex(txHash, predicate) {
  const outputs = await koios.txOutputs(txHash);
  const output = outputs.find(predicate);
  if (!output) throw new Error(`no expected output in ${txHash}`);
  return output.tx_index;
}

// ## 1. Registry
function registryTx(seedUtxo) {
  return builder()
    .txIn(seedUtxo.input.txHash, seedUtxo.input.outputIndex, seedUtxo.output.amount, seedUtxo.output.address)
    .mintPlutusScriptV3()
    .mint('1', scripts.registry.hash, REGISTRY_NFT)
    .mintingScript(scripts.registry.code)
    .mintRedeemerValue(constr(0), 'JSON')
    .txOut(scripts.registry.address, [{ unit: nftUnit, quantity: '1' }])
    .txOutInlineDatumValue(datum, 'JSON')
    .txInCollateral(seedUtxo.input.txHash, seedUtxo.input.outputIndex, seedUtxo.output.amount, seedUtxo.output.address)
    .setTotalCollateral(COLLATERAL)
    .setCollateralReturnAddress(deployer)
    .changeAddress(deployer)
    .selectUtxosFrom(utxos)
    .complete();
}

if (args.plan) {
  const seedUtxo = utxos.find((u) => u.input.txHash === seed.txHash && u.input.outputIndex === seed.outputIndex);
  const balance = utxos.reduce((sum, u) => sum + BigInt(u.output.amount.find((a) => a.unit === 'lovelace')?.quantity ?? 0), 0n);
  console.log(`network      ${network}\ndeployer     ${deployer} (${ada(balance)})`);
  console.log(`seed         ${seed.txHash}#${seed.outputIndex}\n`);
  let deposits = 0n;
  for (const name of SCRIPT_NAMES) {
    const { hash, size, code } = scripts[name];
    const min = BigInt(getOutputMinLovelace(
      { address: scripts.registry.address, amount: [{ unit: 'lovelace', quantity: '1000000000' }], referenceScript: { code, version: 'V3' } },
      params.coinsPerUtxoSize,
    ));
    deposits += min;
    console.log(`${name.padEnd(16)} ${hash}  ${String(size).padStart(6)} bytes  reference deposit ${ada(min)}`);
  }
  console.log(`\nregistry     ${scripts.registry.address}`);
  console.log(`escrow       ${scripts.campaign_state.address}`);
  console.log(`shards       ${scripts.campaign_shard.address}`);
  console.log(`payout       ${scripts.campaign_payout.reward_address}`);
  console.log(`admin        ${scripts.campaign_admin.reward_address}`);
  console.log(`\nreference-script deposits ${ada(deposits)}, reward-account deposits ${ada(2n * BigInt(params.keyDeposit))}`);
  if (!seedUtxo) throw new Error('the seed output is not in the wallet');
  const unsigned = await registryTx(seedUtxo);
  const [budget] = await koios.provider.evaluateTx(unsigned);
  console.log(
    `registry transaction: ${unsigned.length / 2} bytes; the node runs its minting policy in ` +
      `${budget.budget.mem} memory units and ${budget.budget.steps} CPU steps (nothing submitted)`,
  );
  process.exit(0);
}

if (!record.transactions.registry) {
  const seedUtxo = utxos.find((u) => u.input.txHash === seed.txHash && u.input.outputIndex === seed.outputIndex);
  if (!seedUtxo) throw new Error(`the seed ${seed.txHash}#${seed.outputIndex} is spent but no registry was recorded`);
  save();
  const txHash = await submit('registry', await registryTx(seedUtxo));
  const index = await outputIndex(txHash, (o) => o.asset_list?.some((a) => a.policy_id === scripts.registry.hash));
  record.transactions.registry = txHash;
  record.registry.utxo = { tx_hash: txHash, index };
  save();
}

// ## 2. Reference scripts, at the registry address (only governance can move them).
for (const name of SCRIPT_NAMES) {
  if (record.scripts[name].reference) continue;
  utxos = await koios.utxos(deployer);
  const unsigned = await builder()
    .txOut(scripts.registry.address, [])
    .txOutReferenceScript(scripts[name].code, 'V3')
    .changeAddress(deployer)
    .selectUtxosFrom(utxos.filter(pureAda))
    .complete();
  const txHash = await submit(`reference ${name}`, unsigned);
  const index = await outputIndex(txHash, (o) => o.reference_script?.hash === scripts[name].hash);
  record.scripts[name].reference = { tx_hash: txHash, index };
  record.transactions[`reference_${name}`] = txHash;
  save();
}

// ## 3. Reward accounts of the forwarding scripts.
if (!record.transactions.reward_accounts) {
  const accounts = ['campaign_payout', 'campaign_admin'].map((name) => scripts[name].reward_address);
  const info = await koios.accountInfo(accounts);
  const registered = new Set(info.filter((a) => a.status === 'registered').map((a) => a.stake_address));
  const missing = accounts.filter((account) => !registered.has(account));
  if (missing.length) {
    utxos = await koios.utxos(deployer);
    const tx = builder();
    for (const account of missing) tx.registerStakeCertificate(account);
    const unsigned = await tx.changeAddress(deployer).selectUtxosFrom(utxos.filter(pureAda)).complete();
    record.transactions.reward_accounts = await submit('reward accounts', unsigned);
  } else {
    record.transactions.reward_accounts = 'registered before this deployment';
  }
  save();
}

record.status = 'deployed';
save();
console.log(`\n${network} deployed: ${path.relative(ROOT, recordFile)}`);
console.log(`registry policy ${record.registry.policy_id}, escrow state script ${record.escrow.state}`);
console.log('next: node verify.mjs --network ' + network);
