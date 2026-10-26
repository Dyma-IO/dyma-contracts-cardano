// The escrow's scripts with their parameters applied, in dependency order (docs/RUNBOOK.md §3).
import fs from 'node:fs';
import {
  applyParamsToScript,
  resolveScriptHash,
  serializePlutusScript,
  serializeRewardAddress,
} from '@meshsdk/core';
import { bytes, outputReference } from './plutus.mjs';

export const SCRIPT_NAMES = [
  'registry',
  'campaign_policy',
  'campaign_state',
  'campaign_payout',
  'campaign_admin',
  'campaign_shard',
];

export function loadBlueprint(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function compiledCode(blueprint, name) {
  const validator = blueprint.validators.find((v) => v.title.startsWith(`${name}.${name}.`));
  if (!validator) throw new Error(`${name} is not in the blueprint`);
  return validator.compiledCode;
}

/**
 * Applies every parameter, starting from the registry's seed output:
 * registry(seed), campaign_policy(registry), campaign_shard(registry, policy),
 * campaign_payout and campaign_admin(registry, policy, shard),
 * campaign_state(registry, policy, shard, payout, admin).
 */
export function escrowScripts(blueprint, seed, networkId) {
  const scripts = {};
  const apply = (name, params) => {
    const code = applyParamsToScript(compiledCode(blueprint, name), params, 'JSON');
    scripts[name] = { code, hash: resolveScriptHash(code, 'V3'), size: code.length / 2 };
    return scripts[name].hash;
  };
  const registry = apply('registry', [outputReference(seed)]);
  const policy = apply('campaign_policy', [bytes(registry)]);
  const shard = apply('campaign_shard', [bytes(registry), bytes(policy)]);
  const payout = apply('campaign_payout', [bytes(registry), bytes(policy), bytes(shard)]);
  const admin = apply('campaign_admin', [bytes(registry), bytes(policy), bytes(shard)]);
  apply('campaign_state', [bytes(registry), bytes(policy), bytes(shard), bytes(payout), bytes(admin)]);

  const address = (name) =>
    serializePlutusScript({ code: scripts[name].code, version: 'V3' }, undefined, networkId).address;
  scripts.registry.address = address('registry');
  scripts.campaign_state.address = address('campaign_state');
  scripts.campaign_shard.address = address('campaign_shard');
  for (const name of ['campaign_payout', 'campaign_admin']) {
    scripts[name].reward_address = serializeRewardAddress(scripts[name].hash, true, networkId);
  }
  return scripts;
}
