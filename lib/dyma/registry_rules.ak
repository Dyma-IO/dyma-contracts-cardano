//// The registry's configuration rules (the CosmWasm factory's instantiate and `update_config`
//// validation) and how escrows find it.

use aiken/collection/list
use aiken/primitive/bytearray
use cardano/address.{VerificationKey}
use cardano/assets.{PolicyId}
use cardano/transaction.{InlineDatum, Transaction}
use dyma/auth.{valid_key_hash, valid_multisig}
use dyma/constants.{
  hard_max_challenge_secs, hard_max_claim_window_secs, hard_max_commit_batch,
  hard_max_commit_window_secs, hard_max_dispute_timeout_secs, hard_max_fee_bps,
  hard_max_pause_secs, hard_max_recommit_secs, max_global_history,
  registry_nft_name, shard_size,
}
use dyma/types.{GlobalSegment, Limits, RegistryDatum}

pub fn valid_limits(l: Limits) -> Bool {
  and {
    l.min_challenge_secs > 0,
    l.min_challenge_secs <= l.max_challenge_secs,
    l.max_challenge_secs <= hard_max_challenge_secs,
    l.min_commit_window_secs > 0,
    l.min_commit_window_secs <= l.max_commit_window_secs,
    l.max_commit_window_secs <= hard_max_commit_window_secs,
    l.min_recommit_secs >= 1,
    l.min_recommit_secs <= hard_max_recommit_secs,
    l.min_claim_window_secs > 0,
    l.min_claim_window_secs <= l.max_claim_window_secs,
    l.max_claim_window_secs <= hard_max_claim_window_secs,
    l.dispute_timeout_secs >= 1,
    l.dispute_timeout_secs <= hard_max_dispute_timeout_secs,
    l.max_pause_secs >= 1,
    l.max_pause_secs <= hard_max_pause_secs,
    l.max_commit_batch >= shard_size,
    l.max_commit_batch <= hard_max_commit_batch,
    l.max_commit_batch % shard_size == 0,
  }
}

/// Global pauses are kept newest first, never overlapping, each with `start <= until`.
pub fn valid_history(history: List<GlobalSegment>) -> Bool {
  when history is {
    [] -> True
    [segment, ..older] -> {
      let ordered = when older is {
        [] -> True
        [previous, ..] -> previous.until <= segment.start
      }
      and {
        segment.start <= segment.until,
        segment.guardian_before >= 0,
        segment.pauser_before >= 0,
        ordered,
        valid_history(older),
      }
    }
  }
}

/// A complete, consistent configuration, with the CosmWasm factory's role separation: the
/// guardian is neither the operator nor the pauser, and the operator never receives the fees.
pub fn valid_registry(d: RegistryDatum) -> Bool {
  and {
    valid_multisig(d.governance),
    valid_multisig(d.guardian),
    valid_key_hash(d.operator),
    valid_key_hash(d.pauser),
    bytearray.length(d.ticket_key) == 32,
    bytearray.length(d.escrow.policy) == 28,
    bytearray.length(d.escrow.state) == 28,
    bytearray.length(d.escrow.shard) == 28,
    d.max_fee_bps >= 0,
    d.max_fee_bps <= hard_max_fee_bps,
    valid_limits(d.limits),
    !list.has(d.guardian.keys, d.operator),
    !list.has(d.guardian.keys, d.pauser),
    d.treasury.payment_credential != VerificationKey(d.operator),
    list.length(d.global_pauses) <= max_global_history,
    valid_history(d.global_pauses),
  }
}

/// The registry, read as a reference input (the one holding the registry NFT).
pub fn find_registry(tx: Transaction, registry: PolicyId) -> RegistryDatum {
  expect Some(input) = list.find(
    tx.reference_inputs,
    fn(input) {
      assets.quantity_of(input.output.value, registry, registry_nft_name) == 1
    },
  )
  expect InlineDatum(data) = input.output.datum
  expect datum: RegistryDatum = data
  datum
}

/// Every key the escrow refuses as a recipient (roles at commit time).
pub fn privileged_keys(d: RegistryDatum) -> List<ByteArray> {
  let treasury = when d.treasury.payment_credential is {
    VerificationKey(key) -> [key]
    _ -> []
  }
  list.concat(
    [d.operator, d.pauser, ..treasury],
    list.concat(d.guardian.keys, d.governance.keys),
  )
}
