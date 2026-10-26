// The job escrow (validators/job_escrow.ak) and its configuration datum.
import fs from 'node:fs';
import { applyParamsToScript, resolveScriptHash, serializePlutusScript } from '@meshsdk/core';
import { addressData, bytes, constr, int, list, outputReference } from './plutus.mjs';

const isHex = (value, length) => typeof value === 'string' && new RegExp(`^[0-9a-f]{${length * 2}}$`).test(value);

function check(condition, message) {
  if (!condition) throw new Error(`invalid jobs configuration: ${message}`);
}

/** The configuration rules of lib/dyma/jobs.ak `valid_config`. */
export function loadJobsConfig(file, network) {
  const config = JSON.parse(fs.readFileSync(file, 'utf8'));
  check(config.network === network, `network is ${config.network}, expected ${network}`);
  const { required, keys } = config.governance ?? {};
  check(Array.isArray(keys) && keys.every((key) => isHex(key, 28)) && new Set(keys).size === keys.length, 'governance keys');
  check(Number.isInteger(required) && required >= 1 && required <= keys.length, 'governance threshold');
  check(isHex(config.attester, 32), 'attester must be a 32-byte Ed25519 public key');
  check(typeof config.treasury === 'string' && config.treasury.startsWith(network === 'mainnet' ? 'addr1' : 'addr_test1'), 'treasury address');
  check(Number.isInteger(config.max_fee_bps) && config.max_fee_bps >= 0 && config.max_fee_bps <= 1000, 'max_fee_bps (0 to 1000)');
  check(typeof config.paused === 'boolean', 'paused');
  return config;
}

/** `JobsConfig` (field order of lib/dyma/jobs.ak). */
export function jobsConfigDatum(config) {
  return constr(0, [
    constr(0, [int(config.governance.required), list(config.governance.keys.map(bytes))]),
    bytes(config.attester),
    addressData(config.treasury),
    int(config.max_fee_bps),
    constr(config.paused ? 1 : 0),
  ]);
}

export const CONFIG_NFT = Buffer.from('dyma-jobs', 'utf8').toString('hex');

export function jobsScript(blueprint, seed, networkId) {
  const validator = blueprint.validators.find((v) => v.title.startsWith('job_escrow.job_escrow.'));
  if (!validator) throw new Error('job_escrow is not in the blueprint');
  const code = applyParamsToScript(validator.compiledCode, [outputReference(seed)], 'JSON');
  const hash = resolveScriptHash(code, 'V3');
  return { code, hash, size: code.length / 2, address: serializePlutusScript({ code, version: 'V3' }, undefined, networkId).address };
}
