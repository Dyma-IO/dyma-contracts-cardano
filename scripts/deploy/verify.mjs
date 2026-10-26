#!/usr/bin/env node
// Reads a deployment back from the chain and checks it against deployments/<network>.json and
// the blueprint of the recorded commit: script hashes, reference scripts, the registry UTxO and its
// datum, and the reward accounts. Exits non-zero on any mismatch.
//
// Usage: node verify.mjs --network <preprod|preview|mainnet>
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { serializeData } from '@meshsdk/core';
import { registryDatum } from './lib/config.mjs';
import { Koios } from './lib/koios.mjs';
import { utf8Hex } from './lib/plutus.mjs';
import { SCRIPT_NAMES, escrowScripts } from './lib/scripts.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const { values: args } = parseArgs({ options: { network: { type: 'string' } } });
const network = args.network;
if (!['preprod', 'preview', 'mainnet'].includes(network)) {
  console.error('usage: node verify.mjs --network <preprod|preview|mainnet>');
  process.exit(2);
}
const record = JSON.parse(fs.readFileSync(path.join(ROOT, 'deployments', `${network}.json`), 'utf8'));
const koios = new Koios(network);
let failures = 0;
const check = (ok, label, detail = '') => {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${label}${detail ? `: ${detail}` : ''}`);
  if (!ok) failures += 1;
};

// ## The recorded commit's blueprint gives the same scripts.
const blueprint = JSON.parse(
  execFileSync('git', ['-C', ROOT, 'show', `${record.commit}:plutus.json`], { encoding: 'utf8', maxBuffer: 64 << 20 }),
);
const seed = { txHash: record.seed.tx_hash, outputIndex: record.seed.index };
const scripts = escrowScripts(blueprint, seed, network === 'mainnet' ? 1 : 0);
for (const name of SCRIPT_NAMES) {
  check(scripts[name].hash === record.scripts[name].hash, `${name} hash from the blueprint of ${record.commit.slice(0, 7)}`);
}
check(record.registry.policy_id === scripts.registry.hash, 'registry policy id is the registry script hash');
check(
  record.escrow.policy === scripts.campaign_policy.hash &&
    record.escrow.state === scripts.campaign_state.hash &&
    record.escrow.shard === scripts.campaign_shard.hash,
  'escrow version (policy, state, shard)',
);

// ## Reference scripts: unspent, at the registry address, carrying the expected script.
const refs = SCRIPT_NAMES.map((name) => `${record.scripts[name].reference.tx_hash}#${record.scripts[name].reference.index}`);
const refInfo = await koios.utxoInfo(refs);
for (const [i, name] of SCRIPT_NAMES.entries()) {
  const utxo = refInfo.find((u) => `${u.tx_hash}#${u.tx_index}` === refs[i]);
  check(Boolean(utxo) && !utxo.is_spent, `${name} reference UTxO is unspent`, refs[i]);
  if (!utxo) continue;
  check(utxo.address === record.registry.address, `${name} reference sits at the registry address`);
  check(utxo.reference_script?.hash === record.scripts[name].hash, `${name} reference script hash`, utxo.reference_script?.hash);
}

// ## Registry UTxO: the NFT, nothing else but ADA, and the recorded configuration.
const nft = record.registry.policy_id + utf8Hex('dyma-registry');
const holders = (await koios.utxos(record.registry.address)).filter((u) => u.output.amount.some((a) => a.unit === nft));
check(holders.length === 1, 'exactly one UTxO holds the registry NFT', `${holders.length}`);
const [registry] = holders;
if (registry) {
  const ref = `${registry.input.txHash}#${registry.input.outputIndex}`;
  check(ref === `${record.registry.utxo.tx_hash}#${record.registry.utxo.index}`, 'registry UTxO is the recorded one', ref);
  check(
    registry.output.amount.length === 2 && registry.output.amount.every((a) => a.unit === 'lovelace' || a.unit === nft),
    'registry UTxO holds only ADA and the NFT',
  );
  const [info] = await koios.utxoInfo([ref]);
  const expected = serializeData(registryDatum(record.configuration, record.escrow), 'JSON');
  check(info?.inline_datum?.bytes === expected, 'registry datum is the recorded configuration');
}

// ## Reward accounts of the forwarding scripts.
const accounts = ['campaign_payout', 'campaign_admin'].map((name) => record.scripts[name].reward_address);
const accountInfo = await koios.accountInfo(accounts);
for (const account of accounts) {
  const status = accountInfo.find((a) => a.stake_address === account)?.status ?? 'unknown';
  check(status === 'registered', `reward account ${account} is registered`, status);
}

const tip = await koios.tip();
console.log(`\n${failures ? `${failures} check(s) failed` : 'all checks passed'} (${network}, block ${tip.block_no})`);
process.exit(failures ? 1 : 0);
