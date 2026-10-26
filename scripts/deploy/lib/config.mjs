// A deployment configuration (deployments/<network>.config.json) and the registry datum it
// produces. The checks mirror lib/dyma/registry_rules.ak, so a bad file fails here with a clear
// message instead of failing the registry's minting policy.
import fs from 'node:fs';
import { deserializeAddress } from '@meshsdk/core';
import { addressData, bytes, constr, int, list } from './plutus.mjs';

const DAY = 86_400;
// lib/dyma/constants.ak
const HARD = {
  fee_bps: 1000,
  challenge_secs: 7 * DAY,
  commit_window_secs: 90 * DAY,
  recommit_secs: 14 * DAY,
  claim_window_secs: 365 * DAY,
  dispute_timeout_secs: 14 * DAY,
  pause_secs: 7 * DAY,
  commit_batch: 200,
  shard_size: 20,
};
// Field order of `Limits` (part of the on-chain encoding).
const LIMIT_FIELDS = [
  'min_challenge_secs',
  'max_challenge_secs',
  'min_commit_window_secs',
  'max_commit_window_secs',
  'min_recommit_secs',
  'min_claim_window_secs',
  'max_claim_window_secs',
  'dispute_timeout_secs',
  'max_pause_secs',
  'max_commit_batch',
];

const isHex = (value, length) => typeof value === 'string' && new RegExp(`^[0-9a-f]{${length * 2}}$`).test(value);

function check(condition, message) {
  if (!condition) throw new Error(`invalid configuration: ${message}`);
}

function checkMultisig(name, multisig) {
  check(Array.isArray(multisig?.keys), `${name}.keys must be a list`);
  check(multisig.keys.every((key) => isHex(key, 28)), `${name}.keys must be 28-byte key hashes`);
  check(new Set(multisig.keys).size === multisig.keys.length, `${name}.keys must be distinct`);
  check(
    Number.isInteger(multisig.required) && multisig.required >= 1 && multisig.required <= multisig.keys.length,
    `${name}.required must be between 1 and the number of keys`,
  );
}

function checkLimits(l) {
  for (const field of LIMIT_FIELDS) check(Number.isInteger(l?.[field]), `limits.${field} must be an integer`);
  const rules = [
    [l.min_challenge_secs > 0 && l.min_challenge_secs <= l.max_challenge_secs && l.max_challenge_secs <= HARD.challenge_secs, 'challenge window'],
    [l.min_commit_window_secs > 0 && l.min_commit_window_secs <= l.max_commit_window_secs && l.max_commit_window_secs <= HARD.commit_window_secs, 'commit window'],
    [l.min_recommit_secs >= 1 && l.min_recommit_secs <= HARD.recommit_secs, 're-commit floor'],
    [l.min_claim_window_secs > 0 && l.min_claim_window_secs <= l.max_claim_window_secs && l.max_claim_window_secs <= HARD.claim_window_secs, 'claim window'],
    [l.dispute_timeout_secs >= 1 && l.dispute_timeout_secs <= HARD.dispute_timeout_secs, 'dispute timeout'],
    [l.max_pause_secs >= 1 && l.max_pause_secs <= HARD.pause_secs, 'pause length'],
    [l.max_commit_batch >= HARD.shard_size && l.max_commit_batch <= HARD.commit_batch && l.max_commit_batch % HARD.shard_size === 0, 'commit batch (a multiple of 20, at most 200)'],
  ];
  for (const [ok, what] of rules) check(ok, `limits: ${what} outside the hard limits`);
}

export function loadConfig(file, network) {
  const config = JSON.parse(fs.readFileSync(file, 'utf8'));
  check(config.network === network, `network is ${config.network}, expected ${network}`);
  checkMultisig('governance', config.governance);
  checkMultisig('guardian', config.guardian);
  check(isHex(config.operator, 28), 'operator must be a 28-byte key hash');
  check(isHex(config.pauser, 28), 'pauser must be a 28-byte key hash');
  check(isHex(config.ticket_key, 32), 'ticket_key must be a 32-byte Ed25519 public key');
  check(Number.isInteger(config.max_fee_bps) && config.max_fee_bps >= 0 && config.max_fee_bps <= HARD.fee_bps, 'max_fee_bps must be 0 to 1000');
  checkLimits(config.limits);
  check(!config.guardian.keys.includes(config.operator), 'the operator cannot be a guardian');
  check(!config.guardian.keys.includes(config.pauser), 'the pauser cannot be a guardian');
  const treasury = deserializeAddress(config.treasury);
  check(treasury.pubKeyHash || treasury.scriptHash, 'treasury must be a Shelley address');
  check(treasury.pubKeyHash !== config.operator, 'the operator cannot receive the fees');
  const testnet = config.treasury.startsWith('addr_test1');
  check(testnet === (network !== 'mainnet'), `treasury address is not a ${network} address`);
  return config;
}

const multisig = ({ required, keys }) => constr(0, [int(required), list(keys.map(bytes))]);

/** `RegistryDatum` (lib/dyma/types.ak), with an empty global pause history. */
export function registryDatum(config, escrow) {
  return constr(0, [
    multisig(config.governance),
    multisig(config.guardian),
    bytes(config.operator),
    bytes(config.pauser),
    bytes(config.ticket_key),
    addressData(config.treasury),
    constr(0, [bytes(escrow.policy), bytes(escrow.state), bytes(escrow.shard)]),
    int(config.max_fee_bps),
    constr(0, LIMIT_FIELDS.map((field) => int(config.limits[field]))),
    list([]),
  ]);
}
