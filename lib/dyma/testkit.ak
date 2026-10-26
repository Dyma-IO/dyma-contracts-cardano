//// Test fixtures: a registry, a campaign and transaction builders. Only tests use this module.

use aiken/interval.{Finite, Interval, IntervalBound}
use aiken/primitive/bytearray
use cardano/address.{Address, Script, VerificationKey}
use cardano/assets.{Assets}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction,
}
use dyma/constants.{day_secs, ms_per_sec, registry_nft_name}
use dyma/holdings.{deposit_total, shard_token, state_token}
use dyma/ticket.{campaign_key, initial_state}
use dyma/types.{
  Asset, EscrowScripts, EscrowState, Limits, MultiSig, Owner, PayoutTag,
  RegistryDatum, StateDatum, Ticket,
}

// ## Identities

fn repeat(byte: Int, length: Int) -> ByteArray {
  bytearray.replicate(length, byte)
}

pub const registry_policy: ByteArray =
  #"11111111111111111111111111111111111111111111111111111111"

pub const escrow_policy: ByteArray =
  #"22222222222222222222222222222222222222222222222222222222"

/// The campaign state script (`campaign_state`).
pub const state_script: ByteArray =
  #"44444444444444444444444444444444444444444444444444444444"

/// The claim shard script (`campaign_shard`).
pub const shard_script: ByteArray =
  #"55555555555555555555555555555555555555555555555555555555"

/// The payout script (`campaign_payout`, run as a zero-ADA withdrawal).
pub const payout_script: ByteArray =
  #"66666666666666666666666666666666666666666666666666666666"

/// The admin script (`campaign_admin`, run as a zero-ADA withdrawal).
pub const admin_script: ByteArray =
  #"77777777777777777777777777777777777777777777777777777777"

pub const usdm_policy: ByteArray =
  #"33333333333333333333333333333333333333333333333333333333"

pub fn usdm() -> Asset {
  Asset { policy: usdm_policy, name: "USDM" }
}

pub fn ada() -> Asset {
  Asset { policy: "", name: "" }
}

pub fn operator() -> ByteArray {
  repeat(0xa1, 28)
}

pub fn pauser() -> ByteArray {
  repeat(0xa2, 28)
}

pub fn guardian(n: Int) -> ByteArray {
  repeat(0xb0 + n, 28)
}

pub fn governor(n: Int) -> ByteArray {
  repeat(0xc0 + n, 28)
}

pub fn owner_key() -> ByteArray {
  repeat(0xd1, 28)
}

/// Earner `n` (1..65535): keys ascend with `n`.
pub fn earner(n: Int) -> ByteArray {
  bytearray.concat(repeat(0xe0, 26), bytearray.from_int_big_endian(n, 2))
}

pub fn treasury() -> Address {
  address.from_verification_key(repeat(0xf1, 28))
}

pub fn owner() -> Owner {
  Owner {
    credential: VerificationKey(owner_key()),
    address: address.from_verification_key(owner_key()),
  }
}

/// Ed25519 test key (seed 0x01 × 32), public part. scripts/sign-test-ticket.mjs signs with it.
pub const ticket_public_key: ByteArray =
  #"8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c"

// ## Registry

pub fn limits() -> Limits {
  Limits {
    min_challenge_secs: 3_600,
    max_challenge_secs: 7 * day_secs,
    min_commit_window_secs: 5 * day_secs,
    max_commit_window_secs: 90 * day_secs,
    min_recommit_secs: 3 * day_secs,
    min_claim_window_secs: 30 * day_secs,
    max_claim_window_secs: 365 * day_secs,
    dispute_timeout_secs: 3 * day_secs,
    max_pause_secs: day_secs,
    max_commit_batch: 100,
  }
}

pub fn registry_datum() -> RegistryDatum {
  RegistryDatum {
    governance: MultiSig {
      required: 2,
      keys: [governor(1), governor(2), governor(3)],
    },
    guardian: MultiSig {
      required: 2,
      keys: [guardian(1), guardian(2), guardian(3)],
    },
    operator: operator(),
    pauser: pauser(),
    ticket_key: ticket_public_key,
    treasury: treasury(),
    escrow: EscrowScripts {
      policy: escrow_policy,
      state: state_script,
      shard: shard_script,
    },
    max_fee_bps: 1_000,
    limits: limits(),
    global_pauses: [],
  }
}

pub fn registry_address() -> Address {
  address.from_script(registry_policy)
}

pub fn registry_value() -> Assets {
  assets.from_lovelace(5_000_000)
    |> assets.add(registry_policy, registry_nft_name, 1)
}

pub fn registry_input(datum: RegistryDatum) -> Input {
  Input {
    output_reference: out_ref(#"aa", 0),
    output: Output {
      address: registry_address(),
      value: registry_value(),
      datum: InlineDatum(datum),
      reference_script: None,
    },
  }
}

// ## Campaign

/// 2027-01-15T08:00:00Z.
pub const starts_at: Int = 1_800_000_000_000

pub const ends_at: Int = starts_at + 7 * day_secs * ms_per_sec

pub fn out_ref(tx: ByteArray, index: Int) -> OutputReference {
  OutputReference {
    transaction_id: bytearray.concat(tx, repeat(0, 32 - bytearray.length(tx))),
    output_index: index,
  }
}

pub fn seed() -> OutputReference {
  out_ref(#"5eed", 3)
}

/// A USDM campaign: 1% fee, 1 USDM minimum payout, up to 100 recipients (5 claim shards).
pub fn ticket() -> Ticket {
  Ticket {
    version: 1,
    registry: registry_policy,
    escrow_script: state_script,
    campaign_id: "6f1c2a9e-1b2c-4d5e-8f90-123456789abc",
    attempt: 1,
    seed: seed(),
    owner: owner(),
    asset: usdm(),
    min_funding: 1_000_000_000,
    starts_at,
    ends_at,
    fee_bps: 100,
    min_payout: 1_000_000,
    max_share_bps: 10_000,
    challenge_secs: day_secs,
    commit_window_secs: 14 * day_secs,
    claim_window_secs: 30 * day_secs,
    max_recipients: 100,
    state_deposit: 3_000_000,
    shard_deposit: 5_000_000,
    expires_at: starts_at,
  }
}

/// Signature of `ticket()` by the test ticket key (scripts/sign-test-ticket.mjs).
pub const ticket_signature: ByteArray =
  #"22c36625ab0f0b7642aa99511996c0d07ddb4cb0cc65255b0dda7f29e1f84da83c3e1dd80b115e72412d45f0a81e2bdac3932a3c0289d06b2b061bf584ba8706"

/// Created one hour before the campaign starts.
pub const created_at: Int = starts_at - 3_600_000

pub fn key() -> ByteArray {
  campaign_key(seed())
}

/// The campaign right after its creation with `funded` USDM (6 decimals).
pub fn created(funded: Int) -> EscrowState {
  initial_state(ticket(), registry_datum(), created_at, funded)
}

/// Where campaign state UTxOs live.
pub fn escrow_address() -> Address {
  address.from_script(state_script)
}

/// Where claim shards live.
pub fn shard_address() -> Address {
  address.from_script(shard_script)
}

/// The value of a state UTxO of the USDM campaign: the pool and the deposit still kept.
pub fn state_value(pool: Int, deposit: Int) -> Assets {
  assets.from_lovelace(deposit)
    |> assets.add(escrow_policy, state_token(key()), 1)
    |> assets.add(usdm_policy, "USDM", pool)
}

pub fn full_deposit() -> Int {
  deposit_total(created(0).campaign)
}

pub fn state_ref() -> OutputReference {
  out_ref(#"57a7e0", 0)
}

pub fn state_input(state: EscrowState, value: Assets) -> Input {
  Input {
    output_reference: state_ref(),
    output: Output {
      address: escrow_address(),
      value,
      datum: InlineDatum(StateDatum(state)),
      reference_script: None,
    },
  }
}

pub fn state_output(state: EscrowState, value: Assets) -> Output {
  Output {
    address: escrow_address(),
    value,
    datum: InlineDatum(StateDatum(state)),
    reference_script: None,
  }
}

pub fn shard_value(lovelace: Int, usdm_amount: Int) -> Assets {
  assets.from_lovelace(lovelace)
    |> assets.add(escrow_policy, shard_token(key()), 1)
    |> assets.add(usdm_policy, "USDM", usdm_amount)
}

pub fn wallet_input(owner: ByteArray, lovelace: Int) -> Input {
  Input {
    output_reference: out_ref(#"0bb0", 1),
    output: Output {
      address: address.from_verification_key(owner),
      value: assets.from_lovelace(lovelace),
      datum: NoDatum,
      reference_script: None,
    },
  }
}

/// An output to `address` tagged as a payment from the state UTxO.
pub fn tagged(address: Address, role: Int, value: Assets) -> Output {
  Output {
    address,
    value,
    datum: InlineDatum(PayoutTag { from: state_ref(), role }),
    reference_script: None,
  }
}

pub fn to_key(key: ByteArray, value: Assets) -> Output {
  Output {
    address: address.from_verification_key(key),
    value,
    datum: NoDatum,
    reference_script: None,
  }
}

// ## Transactions

/// `[lower, upper)` in milliseconds, as Plutus V3 ranges are.
pub fn range(lower: Int, upper: Int) -> Interval {
  Interval {
    lower_bound: IntervalBound { bound_type: Finite(lower), is_inclusive: True },
    upper_bound: IntervalBound {
      bound_type: Finite(upper),
      is_inclusive: False,
    },
  }
}

/// A transaction landing around `at` (a ten-minute range starting there).
pub fn tx_at(at: Int) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    validity_range: range(at, at + 600_000),
    reference_inputs: [registry_input(registry_datum())],
  }
}

pub fn with_registry(tx: Transaction, datum: RegistryDatum) -> Transaction {
  Transaction { ..tx, reference_inputs: [registry_input(datum)] }
}

pub fn spending(tx: Transaction, inputs: List<Input>) -> Transaction {
  Transaction { ..tx, inputs }
}

pub fn paying(tx: Transaction, outputs: List<Output>) -> Transaction {
  Transaction { ..tx, outputs }
}

pub fn signed(tx: Transaction, keys: List<ByteArray>) -> Transaction {
  Transaction { ..tx, extra_signatories: keys }
}

pub fn minting(tx: Transaction, minted: Assets) -> Transaction {
  Transaction { ..tx, mint: minted }
}

pub fn no_mint() -> Assets {
  assets.zero
}

pub fn burn_state() -> Assets {
  assets.from_asset(escrow_policy, state_token(key()), -1)
}

pub fn shard_mint(quantity: Int) -> Assets {
  assets.from_asset(escrow_policy, shard_token(key()), quantity)
}

pub fn script_owner(hash: ByteArray) -> Owner {
  Owner { credential: Script(hash), address: address.from_script(hash) }
}
