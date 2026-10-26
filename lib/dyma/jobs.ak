//// Dyma Jobs escrow: paid work a project posts outside its campaigns (see docs/JOBS.md).
////
//// One job UTxO per funded job, holding the job token ("J" ++ key), the pool (the reward and
//// Dyma's fee for every period locked) and the owner's refundable ADA deposit. Dyma's API never
//// moves the pool by itself: it signs short-lived tickets (a new job) and approvals (an
//// assignment, a release to the worker, a withdrawal for the owner), and the owner or the worker
//// signs the transaction that uses them. A release can only pay the worker the datum names, and
//// only with the worker's signature. After `expires_at`, the owner takes everything back alone.
////
//// Every action spends exactly one job UTxO and checks its outputs by position, so no output can
//// pay for two inputs.

use aiken/cbor
use aiken/crypto.{
  VerificationKey, VerificationKeyHash, blake2b_224, blake2b_256,
  verify_ed25519_signature,
}
use aiken/primitive/bytearray
use cardano/address.{Address, Credential, Script, VerificationKey as Key}
use cardano/assets.{AssetName, Assets, PolicyId}
use cardano/transaction.{OutputReference}
use dyma/auth.{valid_key_hash, valid_multisig}
use dyma/constants.{bps_denominator, hard_max_fee_bps}
use dyma/holdings.{holds_exactly, is_ada, pool_tokens, quantity}
use dyma/text.{valid_campaign_id}
use dyma/types.{Asset, MultiSig, Owner}

/// The configuration UTxO's NFT.
pub const config_nft_name: ByteArray = "dyma-jobs"

/// First byte of a job token's name ("J"), then the 28-byte job key.
pub const job_token_prefix: ByteArray = "J"

pub const ticket_version: Int = 1

pub const approval_version: Int = 1

/// Lowest ADA deposit a ticket may set (the API computes the exact one, with a margin).
pub const min_deposit: Int = 2_000_000

/// Tickets and approvals live at most one day.
pub const max_signed_life_ms: Int = 86_400_000

/// How far in the future a ticket or an approval may be issued (clock skew).
pub const max_issue_skew_ms: Int = 600_000

/// Datum of the configuration UTxO (the one holding the configuration NFT).
pub type JobsConfig {
  governance: MultiSig,
  /// Ed25519 public key (32 bytes) that signs tickets and approvals.
  attester: VerificationKey,
  /// Receives Dyma's fee on every release.
  treasury: Address,
  /// Highest fee a ticket may set (at most 10%).
  max_fee_bps: Int,
  /// Stops new jobs and every approved action; the owner's `Reclaim` still works.
  paused: Bool,
}

/// Datum of a job UTxO (the one holding its job token).
pub type JobState {
  /// Dyma's job id, `[a-z0-9-]{1,64}`.
  job_id: ByteArray,
  /// 28 bytes, from the funding transaction's seed input.
  key: ByteArray,
  /// Authorises the owner's actions; `address` receives every refund.
  owner: Owner,
  /// ADA, or one native token (Dyma's API only signs ADA and known stablecoins).
  asset: Asset,
  /// The reward of one task or one period, for display: releases name their own amount.
  reward: Int,
  fee_bps: Int,
  /// True: the project pays the fee on top of the reward. False: it comes out of the reward.
  fee_on_top: Bool,
  /// The payment key of the hired worker, once there is one.
  worker: Option<VerificationKeyHash>,
  /// Lovelace kept for the UTxO itself, back to the owner when the job closes.
  deposit: Int,
  /// From then on, the owner can take everything back without Dyma.
  expires_at: Int,
  /// Approvals name the current nonce; every approved action increments it.
  nonce: Int,
  /// Paid to workers and to the treasury so far.
  released: Int,
  fees_paid: Int,
}

/// What Dyma's API signs for one job funding: every parameter of the new job.
pub type JobTicket {
  version: Int,
  /// The job escrow: binds the network and the deployment.
  policy: PolicyId,
  job_id: ByteArray,
  /// An input of the funding transaction: makes the ticket single-use and names the job key.
  seed: OutputReference,
  owner: Owner,
  asset: Asset,
  reward: Int,
  fee_bps: Int,
  fee_on_top: Bool,
  worker: Option<VerificationKeyHash>,
  min_funding: Int,
  deposit: Int,
  expires_at: Int,
  issued_at: Int,
  valid_until: Int,
}

pub type ApprovedAction {
  /// Hire (or change, or remove) the worker. The owner signs too.
  AssignWorker { worker: Option<VerificationKeyHash> }
  /// Pay approved work: `gross` is the reward released. The worker signs.
  ReleasePay { gross: Int, close: Bool }
  /// Give unused funds back to the owner. The owner signs too.
  WithdrawFunds { amount: Int, close: Bool }
}

/// What Dyma's API signs for one action on one job.
pub type JobApproval {
  version: Int,
  policy: PolicyId,
  key: ByteArray,
  nonce: Int,
  action: ApprovedAction,
  issued_at: Int,
  valid_until: Int,
}

pub type JobMint {
  /// The one-shot configuration NFT (with the seed).
  Init
  /// Funds a new job from a ticket signed by Dyma.
  Create { ticket: JobTicket, signature: ByteArray }
  /// Burns job tokens of jobs that close in the same transaction (their spend decides).
  Burn
}

pub type JobSpend {
  /// Governance changes the configuration.
  UpdateConfig
  /// The owner adds funds and may push `expires_at` later.
  TopUp { expires_at: Int }
  /// An action Dyma approved (`approval.action`).
  Approved { approval: JobApproval, signature: ByteArray }
  /// The owner takes everything back after `expires_at`.
  Reclaim
  /// Governance takes back anything sent to the address that is not a job or the configuration.
  Rescue
}

// ## Keys and tokens

/// The 28-byte job key: unique, since the seed input can only be spent once.
pub fn job_key(seed: OutputReference) -> ByteArray {
  blake2b_224(cbor.serialise(seed))
}

pub fn job_token(key: ByteArray) -> AssetName {
  bytearray.concat(job_token_prefix, key)
}

// ## Signatures

fn signed(data: Data, signature: ByteArray, attester: VerificationKey) -> Bool {
  bytearray.length(signature) == 64 && verify_ed25519_signature(
    attester,
    blake2b_256(cbor.serialise(data)),
    signature,
  )
}

/// Issued now (within the skew), still valid after the transaction, and short-lived.
fn fresh(issued_at: Int, valid_until: Int, lower: Int, upper: Int) -> Bool {
  and {
    issued_at <= lower + max_issue_skew_ms,
    valid_until > upper,
    valid_until - issued_at <= max_signed_life_ms,
  }
}

// ## Rules

fn credential_hash(credential: Credential) -> ByteArray {
  when credential is {
    Key(hash) -> hash
    Script(hash) -> hash
  }
}

/// ADA, or one native token that is not the escrow's own.
pub fn valid_asset(asset: Asset, own_policy: PolicyId) -> Bool {
  if is_ada(asset) {
    True
  } else {
    and {
      bytearray.length(asset.policy) == 28,
      bytearray.length(asset.name) <= 32,
      asset.policy != own_policy,
    }
  }
}

/// No worker, or a payment key that is neither the owner's nor the treasury's.
pub fn valid_worker(
  worker: Option<VerificationKeyHash>,
  owner: Owner,
  treasury: Address,
) -> Bool {
  when worker is {
    None -> True
    Some(key) -> and {
        valid_key_hash(key),
        owner.credential != Key(key),
        owner.address.payment_credential != Key(key),
        treasury.payment_credential != Key(key),
      }
  }
}

pub fn valid_config(config: JobsConfig) -> Bool {
  and {
    valid_multisig(config.governance),
    bytearray.length(config.attester) == 32,
    bytearray.length(credential_hash(config.treasury.payment_credential)) == 28,
    config.max_fee_bps >= 0,
    config.max_fee_bps <= hard_max_fee_bps,
  }
}

pub fn valid_ticket(
  ticket: JobTicket,
  signature: ByteArray,
  config: JobsConfig,
  own_policy: PolicyId,
  lower: Int,
  upper: Int,
) -> Bool {
  and {
    ticket.version == ticket_version,
    ticket.policy == own_policy,
    valid_campaign_id(ticket.job_id),
    bytearray.length(credential_hash(ticket.owner.credential)) == 28,
    valid_asset(ticket.asset, own_policy),
    ticket.reward > 0,
    ticket.fee_bps >= 0,
    ticket.fee_bps <= config.max_fee_bps,
    ticket.min_funding > 0,
    ticket.deposit >= min_deposit,
    valid_worker(ticket.worker, ticket.owner, config.treasury),
    ticket.expires_at > upper,
    fresh(ticket.issued_at, ticket.valid_until, lower, upper),
    signed(ticket, signature, config.attester),
  }
}

/// An approval for this job's current nonce, signed by the attester and still fresh.
pub fn valid_approval(
  approval: JobApproval,
  signature: ByteArray,
  config: JobsConfig,
  own_policy: PolicyId,
  state: JobState,
  lower: Int,
  upper: Int,
) -> Bool {
  and {
    approval.version == approval_version,
    approval.policy == own_policy,
    approval.key == state.key,
    approval.nonce == state.nonce,
    fresh(approval.issued_at, approval.valid_until, lower, upper),
    signed(approval, signature, config.attester),
  }
}

/// The state a ticket creates.
pub fn initial_state(ticket: JobTicket) -> JobState {
  JobState {
    job_id: ticket.job_id,
    key: job_key(ticket.seed),
    owner: ticket.owner,
    asset: ticket.asset,
    reward: ticket.reward,
    fee_bps: ticket.fee_bps,
    fee_on_top: ticket.fee_on_top,
    worker: ticket.worker,
    deposit: ticket.deposit,
    expires_at: ticket.expires_at,
    nonce: 0,
    released: 0,
    fees_paid: 0,
  }
}

// ## Money

/// Dyma's fee on a released amount, rounded down.
pub fn fee_of(gross: Int, fee_bps: Int) -> Int {
  gross * fee_bps / bps_denominator
}

/// `(to the worker, to the treasury, taken from the pool)` for a release of `gross`.
pub fn split(state: JobState, gross: Int) -> (Int, Int, Int) {
  let fee = fee_of(gross, state.fee_bps)
  if state.fee_on_top {
    (gross, fee, gross + fee)
  } else {
    (gross - fee, fee, gross)
  }
}

/// The pool a job UTxO's value holds (its deposit set apart).
pub fn pool_of(state: JobState, value: Assets) -> Int {
  if is_ada(state.asset) {
    assets.lovelace_of(value) - state.deposit
  } else {
    quantity(value, state.asset)
  }
}

/// Exactly the deposit, the job token and the pool: nothing else.
pub fn holds(
  value: Assets,
  own_policy: PolicyId,
  state: JobState,
  pool: Int,
) -> Bool {
  let lovelace = if is_ada(state.asset) {
    state.deposit + pool
  } else {
    state.deposit
  }
  pool >= 0 && holds_exactly(
    value,
    lovelace,
    [(own_policy, job_token(state.key), 1), ..pool_tokens(state.asset, pool)],
  )
}

/// At least `amount` of the asset, and at least `lovelace` more ADA than an ADA asset needs.
pub fn carries(value: Assets, asset: Asset, amount: Int, lovelace: Int) -> Bool {
  if is_ada(asset) {
    assets.lovelace_of(value) >= amount + lovelace
  } else {
    quantity(value, asset) >= amount && assets.lovelace_of(value) >= lovelace
  }
}

test fee_rounds_down() {
  and {
    fee_of(2_000_000_000, 500) == 100_000_000,
    fee_of(19, 500) == 0,
    fee_of(20, 500) == 1,
    fee_of(1_000, 0) == 0,
  }
}
