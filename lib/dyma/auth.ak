//// Who signed a transaction.

use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use aiken/primitive/bytearray
use cardano/address.{Credential, Script, VerificationKey}
use cardano/transaction.{Transaction}
use dyma/types.{MultiSig, Owner}

pub fn signed_by(tx: Transaction, key: VerificationKeyHash) -> Bool {
  list.has(tx.extra_signatories, key)
}

/// At least `required` distinct keys of the multisig signed.
pub fn multisig_signed(tx: Transaction, multisig: MultiSig) -> Bool {
  let signed = list.foldl(
    multisig.keys,
    0,
    fn(key, count) {
      if signed_by(tx, key) {
        count + 1
      } else {
        count
      }
    },
  )
  signed >= multisig.required
}

/// A multisig that can be satisfied: 1 <= required <= keys, distinct keys of 28 bytes.
pub fn valid_multisig(multisig: MultiSig) -> Bool {
  and {
    multisig.required >= 1,
    multisig.required <= list.length(multisig.keys),
    list.length(list.unique(multisig.keys)) == list.length(multisig.keys),
    list.all(multisig.keys, valid_key_hash),
  }
}

pub fn valid_key_hash(key: ByteArray) -> Bool {
  bytearray.length(key) == 28
}

/// A credential authorised the transaction: a key signed, or a script (e.g. a native multisig
/// wallet) spent one of its own inputs.
pub fn credential_authorised(tx: Transaction, credential: Credential) -> Bool {
  when credential is {
    VerificationKey(key) -> signed_by(tx, key)
    Script(hash) ->
      list.any(
        tx.inputs,
        fn(input) { input.output.address.payment_credential == Script(hash) },
      )
  }
}

pub fn owner_authorised(tx: Transaction, owner: Owner) -> Bool {
  credential_authorised(tx, owner.credential)
}
