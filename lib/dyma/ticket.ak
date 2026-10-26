//// Campaign tickets: Dyma's API signs, for one campaign funding attempt, the exact rules the
//// owner's pool will follow (the CosmWasm factory's `CampaignTicket`). The escrow checks them
//// when the campaign is created, in the factory's order.

use aiken/cbor
use aiken/collection/list
use aiken/crypto.{blake2b_224, blake2b_256, verify_ed25519_signature}
use aiken/primitive/bytearray
use cardano/address.{Script, VerificationKey}
use cardano/assets.{PolicyId}
use cardano/transaction.{OutputReference, Transaction}
use dyma/auth.{owner_authorised}
use dyma/clock.{new_ledger}
use dyma/constants.{
  hard_max_campaign_secs, hard_max_recipients, hard_max_start_delay_secs,
  min_shard_deposit, min_state_deposit, ms_per_sec, ticket_version,
}
use dyma/holdings.{is_ada}
use dyma/text.{valid_campaign_id}
use dyma/types.{Asset, Campaign, EscrowState, RegistryDatum, Ticket}

/// The 28-byte campaign key: unique, since the seed input can only be spent once.
pub fn campaign_key(seed: OutputReference) -> ByteArray {
  blake2b_224(cbor.serialise(seed))
}

/// What the ticket key signs.
pub fn message(ticket: Ticket) -> ByteArray {
  blake2b_256(cbor.serialise(ticket))
}

pub fn valid_signature(
  ticket: Ticket,
  signature: ByteArray,
  registry: RegistryDatum,
) -> Bool {
  bytearray.length(signature) == 64 && verify_ed25519_signature(
    registry.ticket_key,
    message(ticket),
    signature,
  )
}

/// ADA, or one native token that is neither the escrow's nor the registry's.
pub fn valid_asset(
  asset: Asset,
  escrow_policy: PolicyId,
  registry_policy: PolicyId,
) -> Bool {
  if is_ada(asset) {
    True
  } else {
    and {
      bytearray.length(asset.policy) == 28,
      bytearray.length(asset.name) <= 32,
      asset.policy != escrow_policy,
      asset.policy != registry_policy,
    }
  }
}

fn valid_credential_hash(hash: ByteArray) -> Bool {
  bytearray.length(hash) == 28
}

/// The ticket's rules, as the factory checks them (`lower`/`upper`: the validity range).
pub fn valid_rules(
  ticket: Ticket,
  registry: RegistryDatum,
  registry_policy: PolicyId,
  escrow_policy: PolicyId,
  lower: Int,
  upper: Int,
) -> Bool {
  let limits = registry.limits
  let owner_hash = when ticket.owner.credential is {
    VerificationKey(hash) -> hash
    Script(hash) -> hash
  }
  and {
    ticket.version == ticket_version,
    ticket.registry == registry_policy,
    // The current escrow version only: its policy mints, its state script holds the campaign.
    registry.escrow.policy == escrow_policy,
    ticket.escrow_script == registry.escrow.state,
    valid_credential_hash(owner_hash),
    ticket.expires_at > upper,
    valid_campaign_id(ticket.campaign_id),
    ticket.attempt >= 1,
    ticket.starts_at < ticket.ends_at,
    ticket.ends_at > upper,
    ticket.starts_at <= lower + hard_max_start_delay_secs * ms_per_sec,
    ticket.ends_at - ticket.starts_at <= hard_max_campaign_secs * ms_per_sec,
    ticket.fee_bps >= 0,
    ticket.fee_bps <= registry.max_fee_bps,
    ticket.max_share_bps >= 1,
    ticket.max_share_bps <= 10_000,
    ticket.min_payout >= 0,
    ticket.challenge_secs >= limits.min_challenge_secs,
    ticket.challenge_secs <= limits.max_challenge_secs,
    ticket.commit_window_secs >= limits.min_commit_window_secs,
    ticket.commit_window_secs <= limits.max_commit_window_secs,
    ticket.claim_window_secs >= limits.min_claim_window_secs,
    ticket.claim_window_secs <= limits.max_claim_window_secs,
    ticket.min_funding > 0,
    valid_asset(ticket.asset, escrow_policy, registry_policy),
    ticket.max_recipients >= 1,
    ticket.max_recipients <= hard_max_recipients,
    ticket.state_deposit >= min_state_deposit,
    ticket.shard_deposit >= min_shard_deposit,
  }
}

/// The ticket's seed is spent and its owner authorised the transaction.
pub fn used_by_owner(ticket: Ticket, tx: Transaction) -> Bool {
  and {
    list.any(tx.inputs, fn(input) { input.output_reference == ticket.seed }),
    owner_authorised(tx, ticket.owner),
  }
}

/// The state a ticket creates, funded with `funded` (the pool) at time `lower`.
pub fn initial_state(
  ticket: Ticket,
  registry: RegistryDatum,
  lower: Int,
  funded: Int,
) -> EscrowState {
  EscrowState {
    campaign: Campaign {
      campaign_id: ticket.campaign_id,
      attempt: ticket.attempt,
      key: campaign_key(ticket.seed),
      asset: ticket.asset,
      starts_at: ticket.starts_at,
      ends_at: ticket.ends_at,
      fee_bps: ticket.fee_bps,
      min_payout: ticket.min_payout,
      max_share_bps: ticket.max_share_bps,
      challenge_secs: ticket.challenge_secs,
      commit_window_secs: ticket.commit_window_secs,
      claim_window_secs: ticket.claim_window_secs,
      max_recipients: ticket.max_recipients,
      state_deposit: ticket.state_deposit,
      shard_deposit: ticket.shard_deposit,
      min_funding: ticket.min_funding,
      limits: registry.limits,
      created_at: lower,
    },
    owner: ticket.owner,
    pending_owner: None,
    version: 0,
    entry_count: 0,
    total_points: 0,
    chain_head: "",
    lowest_committed: "",
    commit_deadline: ticket.ends_at + ticket.commit_window_secs * ms_per_sec,
    recommit_extensions: 0,
    funded_total: funded,
    finalized: None,
    dispute: None,
    distribution: None,
    clock: new_ledger(ticket.ends_at),
  }
}
