//// Reputation badge scenarios: the configuration NFT, claims, upgrades that retire the older
//// badge, governance revocation and configuration changes, and what the scripts refuse.
//// Attestation signatures come from the test key (seed 0x01 × 32, `ticket_public_key`).

use aiken/collection/list
use cardano/address.{Address}
use cardano/assets.{Assets}
use cardano/transaction.{
  InlineDatum, Input, Mint, NoDatum, Output, OutputReference, Spend, Transaction,
}
use dyma/badge.{
  Attestation, Burn, Cip68Datum, Claim, Init, ReputationConfig, ReputationMint,
  Retire, Tier, UpdateConfig, badge_datum, badge_id, config_nft_name,
  reference_name, user_name,
}
use dyma/testkit.{governor, out_ref, owner_key, range, ticket_public_key}
use dyma/types.{MultiSig}
use reputation

const now: Int = 1_800_000_000_000

const policy: ByteArray =
  #"99999999999999999999999999999999999999999999999999999999"

const account: ByteArray =
  #"acacacacacacacacacacacacacacacacacacacacacacacacacacacacacacacac"

fn tiers() -> List<Tier> {
  [
    Tier {
      tier: 1,
      name: "Bronze",
      min_score: 500,
      boost_bps: 10_500,
      image: "ipfs://bronze",
    },
    Tier {
      tier: 2,
      name: "Silver",
      min_score: 2_000,
      boost_bps: 11_000,
      image: "ipfs://silver",
    },
    Tier {
      tier: 3,
      name: "Gold",
      min_score: 10_000,
      boost_bps: 12_500,
      image: "ipfs://gold",
    },
  ]
}

fn config() -> ReputationConfig {
  ReputationConfig {
    governance: MultiSig {
      required: 2,
      keys: [governor(1), governor(2), governor(3)],
    },
    attester: ticket_public_key,
    paused: False,
    collection: "Dyma Reputation",
    description: "Soulbound certificate of a Dyma Reputation tier.",
    tiers: tiers(),
  }
}

fn script_address() -> Address {
  address.from_script(policy)
}

fn config_input(c: ReputationConfig) -> Input {
  Input {
    output_reference: out_ref(#"c0f1", 0),
    output: Output {
      address: script_address(),
      value: assets.from_lovelace(3_000_000)
        |> assets.add(policy, config_nft_name, 1),
      datum: InlineDatum(c),
      reference_script: None,
    },
  }
}

fn wallet(seed: OutputReference) -> Input {
  Input {
    output_reference: seed,
    output: Output {
      address: address.from_verification_key(owner_key()),
      value: assets.from_lovelace(50_000_000),
      datum: NoDatum,
      reference_script: None,
    },
  }
}

fn attestation(
  seed: ByteArray,
  tier: Int,
  score: Int,
  nonce: Int,
) -> Attestation {
  Attestation {
    version: 1,
    policy,
    account,
    owner: owner_key(),
    tier,
    score,
    nonce,
    issued_at: now,
    expires_at: now + 900_000,
    seed: out_ref(seed, 0),
  }
}

/// Signed with the test key (see the file comment).
fn first() -> (Attestation, ByteArray) {
  (
    attestation(#"ba01", 1, 1_000, 1),
    #"3957e3edd2ea32f651deda3b29dec31f887b47e41cd0d96d0003050b37c1818bdada083a3b603fd463b297e351ca08b01408d37081e5b7eba025a7d57d007906",
  )
}

fn upgrade() -> (Attestation, ByteArray) {
  (
    attestation(#"ba02", 2, 5_000, 2),
    #"463f06d03b823a8f324479bfc5dc8d37f32d16ea505d6468da1cdb8aba1d095b9c0dc28c11f55328e6c65acaf0c83ffa1ddb5e422401ec464ae497e99e4f100c",
  )
}

fn tier_of(a: Attestation) -> Tier {
  expect Some(tier) = list.find(tiers(), fn(t) { t.tier == a.tier })
  tier
}

fn badge_output(a: Attestation) -> Output {
  Output {
    address: script_address(),
    value: assets.from_lovelace(2_500_000)
      |> assets.add(policy, reference_name(badge_id(a.seed)), 1),
    datum: InlineDatum(badge_datum(config(), tier_of(a), a)),
    reference_script: None,
  }
}

fn badge_input(a: Attestation) -> Input {
  Input {
    output_reference: out_ref(#"bad9e0", a.nonce),
    output: badge_output(a),
  }
}

fn pair_of(a: Attestation) -> Assets {
  let id = badge_id(a.seed)
  assets.from_asset(policy, reference_name(id), 1)
    |> assets.add(policy, user_name(id), 1)
}

fn claim_tx(
  a: Attestation,
  signature: ByteArray,
  c: ReputationConfig,
) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    inputs: [wallet(a.seed)],
    reference_inputs: [config_input(c)],
    outputs: [badge_output(a)],
    mint: pair_of(a),
    extra_signatories: [a.owner],
    validity_range: range(now, now + 600_000),
    redeemers: [
      Pair(Mint(policy), as_data(Claim { attestation: a, signature })),
    ],
  }
}

fn as_data(redeemer: ReputationMint) -> Data {
  let data: Data = redeemer
  data
}

fn mint(redeemer: ReputationMint, tx: Transaction) -> Bool {
  reputation.reputation.mint(out_ref(#"5eed", 0), redeemer, policy, tx)
}

fn claim(a: Attestation, signature: ByteArray, tx: Transaction) -> Bool {
  mint(Claim { attestation: a, signature }, tx)
}

// ## Configuration

test mints_the_configuration_once() {
  let output = Output {
    ..config_input(config()).output,
    value: assets.from_lovelace(3_000_000)
      |> assets.add(policy, config_nft_name, 1),
  }
  let tx = Transaction {
    ..transaction.placeholder,
    inputs: [wallet(out_ref(#"5eed", 0))],
    outputs: [output],
    mint: assets.from_asset(policy, config_nft_name, 1),
  }
  mint(Init, tx)
}

test the_configuration_needs_its_seed() fail {
  let tx = Transaction {
    ..transaction.placeholder,
    inputs: [wallet(out_ref(#"07e2", 0))],
    outputs: [config_input(config()).output],
    mint: assets.from_asset(policy, config_nft_name, 1),
  }
  mint(Init, tx)
}

test tiers_must_ascend() fail {
  let bad = ReputationConfig { ..config(), tiers: list.reverse(tiers()) }
  let tx = Transaction {
    ..transaction.placeholder,
    inputs: [wallet(out_ref(#"5eed", 0))],
    outputs: [config_input(bad).output],
    mint: assets.from_asset(policy, config_nft_name, 1),
  }
  mint(Init, tx)
}

fn update_tx(next: ReputationConfig, signers: List<ByteArray>) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    inputs: [config_input(config())],
    outputs: [config_input(next).output],
    extra_signatories: signers,
  }
}

test governance_updates_the_configuration() {
  let next = ReputationConfig { ..config(), paused: True }
  reputation.reputation.spend(
    out_ref(#"5eed", 0),
    Some(as_config(config())),
    UpdateConfig,
    config_input(config()).output_reference,
    update_tx(next, [governor(1), governor(2)]),
  )
}

fn as_config(c: ReputationConfig) -> Data {
  let data: Data = c
  data
}

test one_governor_cannot_update() fail {
  reputation.reputation.spend(
    out_ref(#"5eed", 0),
    Some(as_config(config())),
    UpdateConfig,
    config_input(config()).output_reference,
    update_tx(ReputationConfig { ..config(), paused: True }, [governor(1)]),
  )
}

// ## Claims

test claims_a_badge() {
  let (a, signature) = first()
  claim(a, signature, claim_tx(a, signature, config()))
}

test claims_need_dymas_signature() fail {
  let (a, _) = first()
  let (_, other) = upgrade()
  claim(a, other, claim_tx(a, other, config()))
}

test claims_need_the_owner() fail {
  let (a, signature) = first()
  claim(
    a,
    signature,
    Transaction { ..claim_tx(a, signature, config()), extra_signatories: [] },
  )
}

test claims_spend_their_seed() fail {
  let (a, signature) = first()
  claim(
    a,
    signature,
    Transaction {
      ..claim_tx(a, signature, config()),
      inputs: [wallet(out_ref(#"07e2", 1))],
    },
  )
}

test claims_stop_while_paused() fail {
  let (a, signature) = first()
  claim(
    a,
    signature,
    claim_tx(a, signature, ReputationConfig { ..config(), paused: True }),
  )
}

test claims_refuse_an_expired_attestation() fail {
  let a = Attestation {
    ..attestation(#"ba04", 1, 1_000, 4),
    issued_at: now - 3_600_000,
    expires_at: now - 1,
  }
  let signature = #"58b33ad80d06ddb3fac3892851044f6c3052320831f2e75eb54462df0bab2db09fbcce9087adccd8b2c0d05a8b847b0fb580188a2ae821d1492f2f244ce06303"
  claim(a, signature, claim_tx(a, signature, config()))
}

test claims_need_the_tier_score() fail {
  let a = attestation(#"ba03", 1, 50, 3)
  let signature = #"ef2e43a44492a32f34da8ebb02ac95d71f9ea3682fa9937d9c7a0f5ef82d92781a3cab6cc304e7057bf73f96886393c4cdeb5478264fc8e2a6a3773a24d2a405"
  claim(a, signature, claim_tx(a, signature, config()))
}

test claims_write_the_exact_metadata() fail {
  let (a, signature) = first()
  let tx = claim_tx(a, signature, config())
  let forged = Cip68Datum { ..badge_datum(config(), tier_of(a), a), version: 2 }
  claim(
    a,
    signature,
    Transaction {
      ..tx,
      outputs: [Output { ..badge_output(a), datum: InlineDatum(forged) }],
    },
  )
}

test claims_mint_one_pair() fail {
  let (a, signature) = first()
  let tx = claim_tx(a, signature, config())
  claim(
    a,
    signature,
    Transaction {
      ..tx,
      mint: assets.add(tx.mint, policy, user_name(badge_id(a.seed)), 1),
    },
  )
}

test claims_keep_the_reference_at_the_script() fail {
  let (a, signature) = first()
  let tx = claim_tx(a, signature, config())
  let elsewhere = Output {
    ..badge_output(a),
    address: address.from_verification_key(owner_key()),
  }
  claim(a, signature, Transaction { ..tx, outputs: [elsewhere] })
}

// ## Upgrades and revocation

/// A newer claim of the account spends and burns the older reference.
fn upgrade_tx() -> Transaction {
  let (old, _) = first()
  let (a, signature) = upgrade()
  let tx = claim_tx(a, signature, config())
  let old_reference = reference_name(badge_id(old.seed))
  Transaction {
    ..tx,
    inputs: [wallet(a.seed), badge_input(old)],
    mint: assets.add(tx.mint, policy, old_reference, -1),
    redeemers: [
      Pair(Mint(policy), as_data(Claim { attestation: a, signature })),
      Pair(Spend(badge_input(old).output_reference), as_retire()),
    ],
  }
}

fn as_retire() -> Data {
  let data: Data = Retire
  data
}

fn as_badge(a: Attestation) -> Data {
  let data: Data = badge_datum(config(), tier_of(a), a)
  data
}

test an_upgrade_retires_the_older_badge() {
  let (old, _) = first()
  let (a, signature) = upgrade()
  let tx = upgrade_tx()
  and {
    claim(a, signature, tx),
    reputation.reputation.spend(
      out_ref(#"5eed", 0),
      Some(as_badge(old)),
      Retire,
      badge_input(old).output_reference,
      tx,
    ),
  }
}

test only_a_newer_claim_retires_a_badge() fail {
  let (old, _) = first()
  let (a, signature) = upgrade()
  // The badge being retired claims to be newer than the claim.
  let newer = Attestation { ..old, nonce: 9 }
  reputation.reputation.spend(
    out_ref(#"5eed", 0),
    Some(as_badge(newer)),
    Retire,
    badge_input(old).output_reference,
    Transaction {
      ..upgrade_tx(),
      redeemers: [
        Pair(Mint(policy), as_data(Claim { attestation: a, signature })),
      ],
    },
  )
}

test governance_revokes_a_badge() {
  let (old, _) = first()
  let tx = Transaction {
    ..transaction.placeholder,
    inputs: [badge_input(old)],
    reference_inputs: [config_input(config())],
    mint: assets.from_asset(policy, reference_name(badge_id(old.seed)), -1),
    extra_signatories: [governor(1), governor(3)],
  }
  and {
    mint(Burn, tx),
    reputation.reputation.spend(
      out_ref(#"5eed", 0),
      Some(as_badge(old)),
      Retire,
      badge_input(old).output_reference,
      tx,
    ),
  }
}

test a_retired_reference_is_burned() fail {
  let (old, _) = first()
  let tx = Transaction {
    ..transaction.placeholder,
    inputs: [badge_input(old)],
    reference_inputs: [config_input(config())],
    extra_signatories: [governor(1), governor(3)],
  }
  reputation.reputation.spend(
    out_ref(#"5eed", 0),
    Some(as_badge(old)),
    Retire,
    badge_input(old).output_reference,
    tx,
  )
}

test holders_burn_their_user_token() {
  let (a, _) = first()
  mint(
    Burn,
    Transaction {
      ..transaction.placeholder,
      mint: assets.from_asset(policy, user_name(badge_id(a.seed)), -1),
    },
  )
}

test burns_never_mint() fail {
  let (a, _) = first()
  mint(
    Burn,
    Transaction {
      ..transaction.placeholder,
      mint: assets.from_asset(policy, user_name(badge_id(a.seed)), 1),
    },
  )
}

test strays_need_governance() fail {
  let stray = Input {
    output_reference: out_ref(#"5a", 0),
    output: Output {
      address: script_address(),
      value: assets.from_lovelace(5_000_000),
      datum: NoDatum,
      reference_script: None,
    },
  }
  reputation.reputation.spend(
    out_ref(#"5eed", 0),
    None,
    Retire,
    stray.output_reference,
    Transaction {
      ..transaction.placeholder,
      inputs: [stray],
      reference_inputs: [config_input(config())],
      extra_signatories: [governor(1)],
    },
  )
}
