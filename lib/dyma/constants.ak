//// Hard limits, identical to the CosmWasm contracts (`dyma-escrow-types`) unless noted. Durations
//// are in seconds, like CosmWasm; instants are POSIX time in milliseconds, which is what Cardano
//// gives a script through the transaction's validity range.

/// Milliseconds in a second.
pub const ms_per_sec: Int = 1000

/// One day, in seconds.
pub const day_secs: Int = 86_400

/// The protocol fee can never exceed 10% (`HARD_MAX_FEE_BPS`).
pub const hard_max_fee_bps: Int = 1000

/// Basis points in 100%.
pub const bps_denominator: Int = 10_000

pub const hard_max_challenge_secs: Int = 7 * day_secs

pub const hard_max_commit_window_secs: Int = 90 * day_secs

pub const hard_max_recommit_secs: Int = 14 * day_secs

pub const hard_max_dispute_timeout_secs: Int = 14 * day_secs

pub const hard_max_claim_window_secs: Int = 365 * day_secs

pub const hard_max_pause_secs: Int = 7 * day_secs

pub const hard_max_start_delay_secs: Int = 365 * day_secs

pub const hard_max_campaign_secs: Int = 365 * day_secs

/// Pauses of any kind can stop one escrow's clock for at most 90 days in total.
pub const hard_max_frozen_secs: Int = 90 * day_secs

/// The pauser key can freeze one escrow for at most `2 × max_pause_secs` in total.
pub const pauser_budget_pauses: Int = 2

/// A rejected allocation moves the commit deadline at most twice per escrow.
pub const max_recommit_extensions: Int = 2

/// Dispute and rejection reasons: 1 to 280 characters (UTF-8 code points).
pub const max_reason_chars: Int = 280

/// Allocation file URI recorded at finalize.
pub const max_uri_bytes: Int = 256

/// Campaign ids are `[a-z0-9-]{1,64}`.
pub const max_campaign_id_bytes: Int = 64

/// Cardano only: committed entries are paid out from claim shards of at most this many entries.
pub const shard_size: Int = 20

/// Cardano only: a commit batch is a whole number of shards (except the first batch committed,
/// which ends the allocation), at most this many entries.
pub const hard_max_commit_batch: Int = 200

/// Cardano only: an allocation has at most this many entries (the owner's ADA deposit covers
/// one claim shard per 20 entries).
pub const hard_max_recipients: Int = 20_000

/// Cardano only: the registry keeps the latest global pauses (newest first).
pub const max_global_history: Int = 16

/// Cardano only: transactions that write a pause span at most one hour (their lower bound is the
/// pause's start or end).
pub const max_pause_tx_window_ms: Int = 3_600_000

/// Cardano only: every other time-dependent transaction spans at most one day.
pub const max_tx_window_ms: Int = 86_400_000

/// Cardano only: the treasury's fee output may carry at most this many lovelace taken from the
/// owner's deposit (Cardano requires some ADA in every output).
pub const max_treasury_output_lovelace: Int = 2_000_000

/// Cardano only: lowest deposits a ticket may set (the API computes the exact ones from the
/// protocol parameters, with a margin).
pub const min_state_deposit: Int = 2_000_000

pub const min_shard_deposit: Int = 2_000_000

/// Version of the campaign ticket format signed by Dyma.
pub const ticket_version: Int = 1

/// Asset name of the registry NFT ("dyma-registry").
pub const registry_nft_name: ByteArray = "dyma-registry"

/// First byte of a campaign's state token name ("S"), then the 28-byte campaign key.
pub const state_token_prefix: ByteArray = "S"

/// First byte of a campaign's claim shard token name ("L"), then the 28-byte campaign key.
pub const shard_token_prefix: ByteArray = "L"
