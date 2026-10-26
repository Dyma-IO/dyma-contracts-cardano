// Plutus Data in Mesh's JSON form, shaped like the types of lib/dyma/types.ak.
import { deserializeAddress } from '@meshsdk/core';

export const constr = (index, fields = []) => ({ constructor: index, fields });
export const bytes = (hex) => ({ bytes: hex });
export const list = (items) => ({ list: items });
export const some = (value) => constr(0, [value]);
export const none = () => constr(1);

// Mesh takes numbers for integers that fit and bigints for the others.
export function int(value) {
  const v = BigInt(value);
  const safe = BigInt(Number.MAX_SAFE_INTEGER);
  return { int: v <= safe && v >= -safe ? Number(v) : v };
}

export const keyCredential = (hash) => constr(0, [bytes(hash)]);
export const scriptCredential = (hash) => constr(1, [bytes(hash)]);
export const outputReference = ({ txHash, outputIndex }) =>
  constr(0, [bytes(txHash), int(outputIndex)]);

/** `Address { payment_credential, stake_credential }` of a bech32 address (inline stake only). */
export function addressData(bech32) {
  const a = deserializeAddress(bech32);
  const payment = a.pubKeyHash ? keyCredential(a.pubKeyHash) : scriptCredential(a.scriptHash);
  let stake = none();
  if (a.stakeCredentialHash) stake = some(constr(0, [keyCredential(a.stakeCredentialHash)]));
  else if (a.stakeScriptCredentialHash) {
    stake = some(constr(0, [scriptCredential(a.stakeScriptCredentialHash)]));
  }
  return constr(0, [payment, stake]);
}

export const utf8Hex = (text) => Buffer.from(text, 'utf8').toString('hex');
