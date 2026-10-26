// The reputation badge script (validators/reputation.ak) and its configuration datum.
import fs from 'node:fs';
import { applyParamsToScript, resolveScriptHash, serializePlutusScript } from '@meshsdk/core';
import { bytes, constr, int, list, outputReference } from './plutus.mjs';

const text = (value) => bytes(Buffer.from(value, 'utf8').toString('hex'));
const isHex = (value, length) => typeof value === 'string' && new RegExp(`^[0-9a-f]{${length * 2}}$`).test(value);

function check(condition, message) {
  if (!condition) throw new Error(`invalid badge configuration: ${message}`);
}

/** The configuration rules of lib/dyma/badge.ak `valid_config`. */
export function loadBadgeConfig(file, network) {
  const config = JSON.parse(fs.readFileSync(file, 'utf8'));
  check(config.network === network, `network is ${config.network}, expected ${network}`);
  const { required, keys } = config.governance ?? {};
  check(Array.isArray(keys) && keys.every((key) => isHex(key, 28)) && new Set(keys).size === keys.length, 'governance keys');
  check(Number.isInteger(required) && required >= 1 && required <= keys.length, 'governance threshold');
  check(isHex(config.attester, 32), 'attester must be a 32-byte Ed25519 public key');
  check(typeof config.paused === 'boolean', 'paused');
  check(Buffer.byteLength(config.collection ?? '') >= 1 && Buffer.byteLength(config.collection) <= 64, 'collection name');
  check(Buffer.byteLength(config.description ?? '') <= 512, 'description');
  const tiers = config.tiers ?? [];
  check(tiers.length >= 1 && tiers.length <= 32, '1 to 32 tiers');
  tiers.forEach((tier, index) => {
    check(Number.isInteger(tier.tier) && tier.tier >= 0 && tier.tier <= 255, `tier ${index}`);
    check(Buffer.byteLength(tier.name ?? '') >= 1 && Buffer.byteLength(tier.name) <= 64, `tier ${index} name`);
    check(Number.isInteger(tier.min_score) && tier.min_score >= 0, `tier ${index} min_score`);
    check(Number.isInteger(tier.boost_bps) && tier.boost_bps >= 10_000 && tier.boost_bps <= 50_000, `tier ${index} boost`);
    check(Buffer.byteLength(tier.image ?? '') <= 256, `tier ${index} image`);
    if (index > 0) {
      const previous = tiers[index - 1];
      check(previous.tier < tier.tier && previous.min_score < tier.min_score && previous.boost_bps <= tier.boost_bps, 'tiers ascend');
    }
  });
  return config;
}

/** `ReputationConfig` (field order of lib/dyma/badge.ak). */
export function badgeConfigDatum(config) {
  return constr(0, [
    constr(0, [int(config.governance.required), list(config.governance.keys.map(bytes))]),
    bytes(config.attester),
    constr(config.paused ? 1 : 0),
    text(config.collection),
    text(config.description),
    list(config.tiers.map((t) => constr(0, [int(t.tier), text(t.name), int(t.min_score), int(t.boost_bps), text(t.image)]))),
  ]);
}

export const CONFIG_NFT = Buffer.from('dyma-reputation', 'utf8').toString('hex');

export function badgeScript(blueprint, seed, networkId) {
  const validator = blueprint.validators.find((v) => v.title.startsWith('reputation.reputation.'));
  if (!validator) throw new Error('reputation is not in the blueprint');
  const code = applyParamsToScript(validator.compiledCode, [outputReference(seed)], 'JSON');
  const hash = resolveScriptHash(code, 'V3');
  return { code, hash, size: code.length / 2, address: serializePlutusScript({ code, version: 'V3' }, undefined, networkId).address };
}
