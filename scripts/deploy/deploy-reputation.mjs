#!/usr/bin/env node
// Deploys the reputation badges (validators/reputation.ak): the configuration NFT and datum, then
// the script as a reference script at its own address (only governance can move it). Every
// confirmed step goes to deployments/<network>.reputation.json; a re-run resumes from there.
//
// Usage: node deploy-reputation.mjs --network <preprod|preview|mainnet> --wallet <mnemonic file> [--plan]
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { MeshTxBuilder, MeshWallet } from '@meshsdk/core';
import { CONFIG_NFT, badgeConfigDatum, badgeScript, loadBadgeConfig } from './lib/badge.mjs';
import { Koios } from './lib/koios.mjs';
import { constr } from './lib/plutus.mjs';
import { loadBlueprint } from './lib/scripts.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
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
  console.error('usage: node deploy-reputation.mjs --network <preprod|preview|mainnet> --wallet <mnemonic file> [--plan]');
  process.exit(2);
}
if (network === 'mainnet' && !args.plan && !args['confirm-mainnet']) {
  console.error('mainnet: run --plan first, then deploy with --confirm-mainnet');
  process.exit(2);
}
const networkId = network === 'mainnet' ? 1 : 0;
const configFile = path.join(ROOT, 'deployments', `${network}.reputation.config.json`);
const recordFile = path.join(ROOT, 'deployments', `${network}.reputation.json`);

const git = (...a) => execFileSync('git', ['-C', ROOT, ...a], { encoding: 'utf8' }).trim();
const dirty = git('status', '--porcelain', '--', 'plutus.json', 'aiken.toml', 'aiken.lock', 'validators', 'lib');
if (dirty && !args.plan) {
  console.error(`commit the contracts before deploying:\n${dirty}`);
  process.exit(1);
}
const blueprint = loadBlueprint(path.join(ROOT, 'plutus.json'));
const config = loadBadgeConfig(configFile, network);

const words = fs.readFileSync(args.wallet, 'utf8').trim().split(/\s+/);
const koios = new Koios(network);
const wallet = new MeshWallet({ networkId, fetcher: koios.provider, submitter: koios.provider, key: { type: 'mnemonic', words } });
await wallet.init();
const deployer = await wallet.getChangeAddress();
const { params, costModels } = await koios.protocol();

let record = fs.existsSync(recordFile) ? JSON.parse(fs.readFileSync(recordFile, 'utf8')) : null;
if (record?.status === 'deployed') {
  console.log(`${network} badges are already deployed (${path.relative(ROOT, recordFile)}).`);
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
const script = badgeScript(blueprint, seed, networkId);
if (record && record.policy_id !== script.hash) throw new Error(`the blueprint changed since ${record.commit}`);
record ??= {
  network,
  status: 'in progress',
  commit: git('rev-parse', 'HEAD'),
  compiler: blueprint.preamble.compiler.version,
  seed: { tx_hash: seed.txHash, index: seed.outputIndex },
  policy_id: script.hash,
  address: script.address,
  size: script.size,
  config_utxo: null,
  reference: null,
  configuration: config,
  transactions: {},
};
const save = () => fs.writeFileSync(recordFile, JSON.stringify(record, null, 2) + '\n');
const builder = () => {
  const tx = new MeshTxBuilder({ fetcher: koios.provider, evaluator: koios.provider, params });
  tx.setNetwork(costModels);
  return tx;
};
async function submit(label, unsigned) {
  const txHash = await koios.submit(await wallet.signTx(unsigned));
  console.log(`${label}: submitted ${txHash}, waiting for a confirmation…`);
  await koios.confirm(txHash);
  console.log(`${label}: confirmed`);
  return txHash;
}

const configTx = (seedUtxo) =>
  builder()
    .txIn(seedUtxo.input.txHash, seedUtxo.input.outputIndex, seedUtxo.output.amount, seedUtxo.output.address)
    .mintPlutusScriptV3()
    .mint('1', script.hash, CONFIG_NFT)
    .mintingScript(script.code)
    .mintRedeemerValue(constr(0), 'JSON')
    .txOut(script.address, [{ unit: script.hash + CONFIG_NFT, quantity: '1' }])
    .txOutInlineDatumValue(badgeConfigDatum(config), 'JSON')
    .txInCollateral(seedUtxo.input.txHash, seedUtxo.input.outputIndex, seedUtxo.output.amount, seedUtxo.output.address)
    .setTotalCollateral('5000000')
    .setCollateralReturnAddress(deployer)
    .changeAddress(deployer)
    .selectUtxosFrom(utxos)
    .complete();

const seedUtxo = utxos.find((u) => u.input.txHash === seed.txHash && u.input.outputIndex === seed.outputIndex);
if (args.plan) {
  console.log(`network     ${network}\ndeployer    ${deployer}\nseed        ${seed.txHash}#${seed.outputIndex}`);
  console.log(`badges      ${script.hash} (${script.size} bytes)\naddress     ${script.address}\ntiers       ${config.tiers.length}`);
  if (!seedUtxo) throw new Error('the seed output is not in the wallet');
  const unsigned = await configTx(seedUtxo);
  const [budget] = await koios.provider.evaluateTx(unsigned);
  console.log(`configuration transaction: ${unsigned.length / 2} bytes; Init runs in ${budget.budget.mem} memory units (nothing submitted)`);
  process.exit(0);
}

if (!record.transactions.config) {
  if (!seedUtxo) throw new Error('the seed is spent but no configuration was recorded');
  save();
  const txHash = await submit('configuration', await configTx(seedUtxo));
  record.transactions.config = txHash;
  record.config_utxo = { tx_hash: txHash, index: 0 };
  save();
}
if (!record.reference) {
  utxos = await koios.utxos(deployer);
  const unsigned = await builder()
    .txOut(script.address, [])
    .txOutReferenceScript(script.code, 'V3')
    .changeAddress(deployer)
    .selectUtxosFrom(utxos.filter(pureAda))
    .complete();
  const txHash = await submit('reference script', unsigned);
  record.reference = { tx_hash: txHash, index: 0 };
  record.transactions.reference = txHash;
  save();
}
record.status = 'deployed';
save();
console.log(`\n${network} badges deployed: ${path.relative(ROOT, recordFile)} (policy ${script.hash})`);
