//// Data types shared by the registry and the campaign escrow, and by Dyma's API (through the
//// blueprint, `plutus.json`). Field order is part of the on-chain encoding: never reorder.

use aiken/crypto.{ScriptHash, VerificationKey, VerificationKeyHash}
use cardano/address.{Address, Credential}
use cardano/assets.{AssetName, PolicyId}
use cardano/transaction.{OutputReference}

// ## Common

/// The campaign asset: ADA (empty policy and name) or one native token.
pub type Asset {
  policy: PolicyId,
  name: AssetName,
}

/// `required` of `keys` must sign (governance, guardian).
pub type MultiSig {
  required: Int,
  keys: List<VerificationKeyHash>,
}

/// Who owns a campaign: `credential` authorises owner actions (a key signature, or a script
/// spending one of its own inputs in the transaction, e.g. a multisig wallet); `address`
/// receives every refund.
pub type Owner {
  credential: Credential,
  address: Address,
}

/// Bounds the registry imposes on new campaigns (copied into each escrow at creation, like the
/// CosmWasm factory's `limits`). Durations in seconds.
pub type Limits {
  min_challenge_secs: Int,
  max_challenge_secs: Int,
  min_commit_window_secs: Int,
  max_commit_window_secs: Int,
  min_recommit_secs: Int,
  min_claim_window_secs: Int,
  max_claim_window_secs: Int,
  dispute_timeout_secs: Int,
  max_pause_secs: Int,
  /// Entries per commit transaction (a multiple of the 20-entry claim shard).
  max_commit_batch: Int,
}

// ## Pauses

pub type PauseKind {
  /// The guardian or the governance: can extend, overrides the pauser.
  GuardianPause
  /// The pauser hot key: rate-limited, bounded freeze budget per escrow.
  PauserPause
}

/// One global pause, kept by the registry with the global paused time accumulated before it.
pub type GlobalSegment {
  start: Int,
  until: Int,
  kind: PauseKind,
  guardian_before: Int,
  pauser_before: Int,
}

/// Cumulative global paused time by kind, in milliseconds.
pub type Totals {
  guardian: Int,
  pauser: Int,
}

/// The latest instance-level pause of an escrow.
pub type LocalPause {
  start: Int,
  until: Int,
  kind: PauseKind,
}

/// Paused-time accounting of one escrow (the CosmWasm `ClockLedger`, in milliseconds).
pub type ClockLedger {
  local: Option<LocalPause>,
  /// Paused time is accounted up to this time (never before `ends_at`).
  checkpoint: Int,
  /// Global paused totals at `checkpoint`, once observed.
  global_at_checkpoint: Option<Totals>,
  /// Milliseconds since `ends_at` during which a guardian (or governance) pause was active.
  guardian_ms: Int,
  /// Milliseconds since `ends_at` during which only pauser pauses were active.
  pauser_ms: Int,
  /// Highest escrow-clock reading stored by a transaction: the clock never goes back.
  floor: Int,
}

// ## Registry

/// One version of the campaign escrow: the token policy and the two spending scripts. The state
/// script is parameterised by the other two, so its hash identifies the whole version.
pub type EscrowScripts {
  policy: PolicyId,
  state: ScriptHash,
  shard: ScriptHash,
}

/// Datum of the registry UTxO (the one holding the registry NFT): the equivalent of the
/// CosmWasm factory's configuration and global pause ledger. Escrows read it as a reference
/// input, so roles are live: a rotation applies to every campaign at once.
pub type RegistryDatum {
  governance: MultiSig,
  guardian: MultiSig,
  operator: VerificationKeyHash,
  pauser: VerificationKeyHash,
  /// Ed25519 public key (32 bytes) that signs campaign tickets.
  ticket_key: VerificationKey,
  /// Receives protocol fees (frozen into each escrow at finalize).
  treasury: Address,
  /// The campaign escrow for new campaigns (tickets name its state script).
  escrow: EscrowScripts,
  max_fee_bps: Int,
  limits: Limits,
  /// The latest global pauses, newest first (at most 16).
  global_pauses: List<GlobalSegment>,
}

pub type RegistryAction {
  /// Governance: any change but the global pause history. A new governance must sign too.
  UpdateConfig
  /// Pauser (rate-limited) or guardian/governance.
  GlobalPause { until: Int }
  /// Guardian or governance, while the latest global pause is active.
  GlobalUnpause
}

// ## Campaign ticket

/// What Dyma's API signs for one campaign funding attempt: the exact rules the owner's pool
/// will follow. Signed with Ed25519 over `blake2b_256(serialise_data(ticket))`.
pub type Ticket {
  version: Int,
  registry: PolicyId,
  /// The escrow version: its state script (`campaign_state`).
  escrow_script: ScriptHash,
  campaign_id: ByteArray,
  attempt: Int,
  /// An input of the funding transaction: makes the ticket single-use and names the campaign
  /// key (`blake2b_224(serialise_data(seed))`).
  seed: OutputReference,
  owner: Owner,
  asset: Asset,
  min_funding: Int,
  starts_at: Int,
  ends_at: Int,
  fee_bps: Int,
  min_payout: Int,
  max_share_bps: Int,
  challenge_secs: Int,
  commit_window_secs: Int,
  claim_window_secs: Int,
  /// The Top N bound of the allocation (claim shards are paid from the owner's deposit).
  max_recipients: Int,
  /// Lovelace kept in the campaign's state UTxO.
  state_deposit: Int,
  /// Lovelace per claim shard (20 entries).
  shard_deposit: Int,
  expires_at: Int,
}

// ## Campaign escrow

/// Immutable parameters of one campaign funding attempt (fixed at creation).
pub type Campaign {
  campaign_id: ByteArray,
  attempt: Int,
  /// 28-byte campaign key; the state token is "S" ++ key, claim shard tokens "L" ++ key.
  key: ByteArray,
  asset: Asset,
  starts_at: Int,
  ends_at: Int,
  fee_bps: Int,
  min_payout: Int,
  max_share_bps: Int,
  challenge_secs: Int,
  commit_window_secs: Int,
  claim_window_secs: Int,
  max_recipients: Int,
  state_deposit: Int,
  shard_deposit: Int,
  min_funding: Int,
  limits: Limits,
  created_at: Int,
}

pub type PendingOwner {
  owner: Owner,
  expiry: Option<Int>,
}

/// Snapshot taken at finalize.
pub type Finalized {
  at: Int,
  challenge_ends_at: Int,
  claim_deadline: Int,
  gross: Int,
  max_fee: Int,
  distributable: Int,
  cap: Int,
  treasury: Address,
  /// SHA-256 of the canonical allocation text (32 bytes).
  allocation_hash: ByteArray,
  allocation_uri: ByteArray,
}

pub type Dispute {
  raised_at: Int,
  reason: ByteArray,
  expires_at: Int,
  resolved_at: Option<Int>,
}

/// Progress of the payout once the challenge window is over: committed batches are revealed in
/// order and turned into claim shards.
pub type Distribution {
  /// Hash-chain head of the batches still to reveal (empty once everything is revealed).
  head: ByteArray,
  revealed: Int,
  shards_created: Int,
  shards_open: Int,
  /// Amount moved into claim shards, and how many entries it pays.
  allocated: Int,
  allocated_count: Int,
  skipped_count: Int,
  skipped_total: Int,
  /// What closed shards gave back to the owner.
  unclaimed_count: Int,
  unclaimed_total: Int,
}

/// Datum of a campaign's state UTxO (the one holding its state token).
pub type EscrowState {
  campaign: Campaign,
  owner: Owner,
  pending_owner: Option<PendingOwner>,
  version: Int,
  entry_count: Int,
  total_points: Int,
  /// Hash chain over the committed batches (empty before the first commit).
  chain_head: ByteArray,
  /// First key of the latest committed batch: batches are committed from the end of the sorted
  /// allocation to its start (empty before the first commit).
  lowest_committed: ByteArray,
  commit_deadline: Int,
  recommit_extensions: Int,
  funded_total: Int,
  finalized: Option<Finalized>,
  dispute: Option<Dispute>,
  distribution: Option<Distribution>,
  clock: ClockLedger,
}

/// One committed allocation entry: the earner's payment key and its weight.
pub type Entry {
  key: VerificationKeyHash,
  points: Int,
}

/// One payable entry of a claim shard.
pub type ShardEntry {
  key: VerificationKeyHash,
  amount: Int,
}

/// Datum of a claim shard UTxO (the one holding a shard token of its campaign).
pub type Shard {
  campaign: ByteArray,
  index: Int,
  entries: List<ShardEntry>,
}

pub type EscrowDatum {
  StateDatum(EscrowState)
  ShardDatum(Shard)
}

/// Marks a payment the escrow requires (refund to the owner, fee to the treasury) with the input
/// it comes from, so one output can never satisfy two inputs.
pub type PayoutTag {
  from: OutputReference,
  role: Int,
}

pub type EscrowMint {
  /// Funds a new campaign from a ticket signed by Dyma.
  Create { ticket: Ticket, signature: ByteArray }
  /// Mints or burns tokens of campaigns whose state UTxO is spent in the same transaction; the
  /// state's own validation decides.
  Delegate
}

pub type EscrowAction {
  // Funding
  TopUp
  Cancel
  ReclaimExpired
  // Allocation (operator)
  Commit { version: Int, entries: List<Entry> }
  Reset { version: Int }
  Finalize {
    version: Int,
    expected_count: Int,
    expected_total_points: Int,
    allocation_hash: ByteArray,
    allocation_uri: ByteArray,
  }
  // Challenge
  RaiseDispute { reason: ByteArray }
  Reject { reason: ByteArray }
  Resolve { keep_allocation: Bool }
  // Payout
  Reveal { entries: List<Entry>, next: ByteArray }
  CloseShards
  Complete
  // Pauses and ownership
  Pause { until: Int }
  Unpause
  TransferOwnership { new_owner: Owner, expiry: Option<Int> }
  AcceptOwnership
  CancelOwnershipTransfer
  Sync
  // Claim shards
  Claim { index: Int }
  ShardClose
  // Anything else sent to the escrow address
  Rescue
}

pub type Phase {
  Upcoming
  Active
  Ended
  Committing
  Challenge
  Disputed
  Distributing
  Expired
}
