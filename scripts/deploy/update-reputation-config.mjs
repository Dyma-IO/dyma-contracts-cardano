#!/usr/bin/env node
// Updates a deployed reputation badge configuration (validators/reputation.ak `UpdateConfig`):
// the configuration UTxO is spent and recreated, with its NFT, under the configuration in
// deployments/<network>.reputation.config.json. Governance signs (at least its threshold of keys);
// the deployer wallet pays the fee and the collateral. The record gets the transaction and the
// new configuration UTxO.
//
//   node scripts/deploy/update-reputation-config.mjs --network preprod \
//     --wallet ../secrets/cardano/preprod-deployer.mnemonic \
//     --signer ../secrets/cardano/preprod-governance-1.mnemonic \
//     --signer ../secrets/cardano/preprod-governance-2.mnemonic [--plan]
//
// Badges already minted keep the configuration they were claimed under: a change applies to the
// claims that follow (new badges and upgrades).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { MeshTxBuilder, MeshWallet, deserializeAddress } from '@meshsdk/core';
import { CONFIG_NFT, badgeConfigDatum, loadBadgeConfig } from './lib/badge.mjs';
import { Koios } from './lib/koios.mjs';
import { constr } from './lib/plutus.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const { values: args } = parseArgs({
  options: {
    network: { type: 'string' },
    wallet: { type: 'string' },
    signer: { type: 'string', multiple: true },
    plan: { type: 'boolean', default: false },
    'confirm-mainnet': { type: 'boolean', default: false },
  },
});
const network = args.network;
if (!['preprod', 'preview', 'mainnet'].includes(network) || !args.wallet || !args.signer?.length) {
  console.error('usage: update-reputation-config.mjs --network <preprod|preview|mainnet> --wallet <mnemonic file> --signer <governance mnemonic file>... [--plan]');
  process.exit(2);
}
if (network === 'mainnet' && !args.plan && !args['confirm-mainnet']) {
  console.error('mainnet: run with --plan first, then add --confirm-mainnet');
  process.exit(2);
}
const networkId = network === 'mainnet' ? 1 : 0;
const configFile = path.join(ROOT, 'deployments', `${network}.reputation.config.json`);
const recordFile = path.join(ROOT, 'deployments', `${network}.reputation.json`);
const record = JSON.parse(fs.readFileSync(recordFile, 'utf8'));
if (record.status !== 'deployed') throw new Error(`${network} badges are not deployed`);
const config = loadBadgeConfig(configFile, network);

const koios = new Koios(network);
const open = async (file) => {
  const words = fs.readFileSync(file, 'utf8').trim().split(/\s+/);
  const wallet = new MeshWallet({ networkId, fetcher: koios.provider, submitter: koios.provider, key: { type: 'mnemonic', words } });
  await wallet.init();
  return wallet;
};
const wallet = await open(args.wallet);
const deployer = await wallet.getChangeAddress();
const signers = await Promise.all(args.signer.map(open));
const signerKeys = await Promise.all(signers.map(async (signer) => deserializeAddress(await signer.getChangeAddress()).pubKeyHash));

const [current] = await koios.provider.fetchAddressUTxOs(record.address, record.policy_id + CONFIG_NFT);
if (!current?.output.plutusData) throw new Error('the configuration UTxO is not at the script address');
const governance = record.configuration?.governance ?? config.governance;
const signing = signerKeys.filter((key) => governance.keys.includes(key));
if (signing.length < governance.required) {
  throw new Error(`${signing.length} of the signers are governance keys; ${governance.required} are needed`);
}
if (JSON.stringify(config.governance) !== JSON.stringify(governance)) {
  console.log('note: the governance changes; the new governance must sign too (pass its keys with --signer)');
}

const { params, costModels } = await koios.protocol();
const pureAda = (u) => u.output.amount.every((a) => a.unit === 'lovelace') && !u.output.plutusData && !u.output.scriptRef;
const utxos = (await koios.utxos(deployer)).filter(pureAda);
const collateral = utxos.find((u) => BigInt(u.output.amount[0].quantity) >= 5_000_000n);
if (!collateral) throw new Error(`the deployer ${deployer} holds no ADA-only UTxO of 5 ADA for the collateral`);

const tx = new MeshTxBuilder({ fetcher: koios.provider, evaluator: koios.provider, params });
tx.setNetwork(costModels);
tx.spendingPlutusScriptV3()
  .txIn(current.input.txHash, current.input.outputIndex, current.output.amount, current.output.address)
  .spendingTxInReference(record.reference.tx_hash, record.reference.index, String(record.size), record.policy_id)
  .txInInlineDatumPresent()
  .txInRedeemerValue(constr(0), 'JSON')
  .txOut(record.address, [{ unit: record.policy_id + CONFIG_NFT, quantity: '1' }])
  .txOutInlineDatumValue(badgeConfigDatum(config), 'JSON');
for (const key of signing.slice(0, governance.required)) tx.requiredSignerHash(key);
tx.txInCollateral(collateral.input.txHash, collateral.input.outputIndex, collateral.output.amount, collateral.output.address)
  .setTotalCollateral('5000000')
  .setCollateralReturnAddress(deployer)
  .changeAddress(deployer)
  .selectUtxosFrom(utxos);
const unsigned = await tx.complete();

console.log(`network        ${network}\nbadges         ${record.policy_id}\nconfiguration  ${current.input.txHash}#${current.input.outputIndex}`);
console.log(`signers        ${signing.slice(0, governance.required).join(', ')}\ntiers          ${config.tiers.map((t) => t.name).join(', ')}`);
if (args.plan) {
  const [budget] = await koios.provider.evaluateTx(unsigned);
  console.log(`update transaction: ${unsigned.length / 2} bytes; UpdateConfig runs in ${budget.budget.mem} memory units (nothing submitted)`);
  process.exit(0);
}

let signed = await wallet.signTx(unsigned, true);
for (const signer of signers) {
  const key = deserializeAddress(await signer.getChangeAddress()).pubKeyHash;
  if (signing.slice(0, governance.required).includes(key)) signed = await signer.signTx(signed, true);
}
const txHash = await koios.submit(signed);
console.log(`update: submitted ${txHash}, waiting for a confirmation…`);
await koios.confirm(txHash);
record.config_utxo = { tx_hash: txHash, index: 0 };
record.configuration = config;
record.transactions.config_updates = [...(record.transactions.config_updates ?? []), txHash];
fs.writeFileSync(recordFile, JSON.stringify(record, null, 2) + '\n');
console.log(`update: confirmed; ${path.relative(ROOT, recordFile)} records the new configuration UTxO`);
