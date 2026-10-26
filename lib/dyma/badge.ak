//// Dyma Reputation badges on Cardano (CIP-68), the counterpart of the CosmWasm `dyma-reputation`.
////
//// Dyma computes reputation off chain and signs attestations; the script only checks them. A
//// badge is a CIP-68 pair: the reference token (label 100) stays at the script address with the
//// badge's data, the user token (label 222) goes to the owner's wallet. A badge counts only while
//// its user token sits with the owner the reference names ("soulbound by validity": moving the
//// token voids it). Each claim names its badge after an input it spends, so an attestation works
//// once; a newer claim of the same account retires the older reference in the same transaction.

use aiken/cbor
use aiken/collection/list
use aiken/crypto.{
  VerificationKey, VerificationKeyHash, blake2b_224, blake2b_256,
  verify_ed25519_signature,
}
use aiken/primitive/bytearray
use cardano/assets.{PolicyId}
use cardano/transaction.{OutputReference}
use dyma/types.{MultiSig}

/// CIP-67 labels: 100 (reference NFT) and 222 (user NFT).
pub const label_reference: ByteArray = #"000643b0"

pub const label_user: ByteArray = #"000de140"

/// The configuration UTxO's NFT.
pub const config_nft_name: ByteArray = "dyma-reputation"

pub const attestation_version: Int = 1

/// How far in the future an attestation may be issued (clock skew), in milliseconds.
pub const max_issue_skew_ms: Int = 600_000

/// A tier: badges start at the tiers Dyma lists (its first, badge-less tier is not one).
pub type Tier {
  tier: Int,
  name: ByteArray,
  min_score: Int,
  /// Boost in basis points: 10 000 (×1) to 50 000 (×5), never decreasing.
  boost_bps: Int,
  image: ByteArray,
}

/// Datum of the configuration UTxO (the one holding the configuration NFT).
pub type ReputationConfig {
  governance: MultiSig,
  /// Ed25519 public key (32 bytes) that signs attestations.
  attester: VerificationKey,
  paused: Bool,
  /// Collection name shown in wallets ("Dyma Reputation").
  collection: ByteArray,
  description: ByteArray,
  tiers: List<Tier>,
}

/// What Dyma signs for one claim, with Ed25519 over `blake2b_256(serialise_data(attestation))`.
pub type Attestation {
  version: Int,
  /// The badge script: binds the network and the contract.
  policy: PolicyId,
  /// Dyma's opaque account reference (32 bytes).
  account: ByteArray,
  /// The payment key of the wallet the badge belongs to; it signs the claim.
  owner: VerificationKeyHash,
  tier: Int,
  score: Int,
  /// Strictly increasing per account.
  nonce: Int,
  issued_at: Int,
  expires_at: Int,
  /// An input the claim spends: the attestation works once and names the badge.
  seed: OutputReference,
}

/// The badge's own data (CIP-68 `extra`).
pub type BadgeState {
  account: ByteArray,
  owner: VerificationKeyHash,
  tier: Int,
  score: Int,
  boost_bps: Int,
  nonce: Int,
  issued_at: Int,
}

/// CIP-68 reference datum: wallet-facing metadata, version, and the badge's data.
pub type Cip68Datum {
  metadata: Pairs<ByteArray, Data>,
  version: Int,
  extra: BadgeState,
}

pub type ReputationMint {
  /// The one-shot configuration NFT (with the seed).
  Init
  /// A badge: its reference and user tokens (retired badges may burn in the same transaction).
  Claim { attestation: Attestation, signature: ByteArray }
  /// Burning only: holders burn their user tokens; retired references burn with their spend.
  Burn
}

pub type ReputationSpend {
  /// Governance changes the configuration.
  UpdateConfig
  /// A badge reference leaves: a newer claim of the same account, or governance (revocation).
  Retire
}

/// The badge's asset name suffix: the claim's seed input.
pub fn badge_id(seed: OutputReference) -> ByteArray {
  blake2b_224(cbor.serialise(seed))
}

pub fn reference_name(id: ByteArray) -> ByteArray {
  bytearray.concat(label_reference, id)
}

pub fn user_name(id: ByteArray) -> ByteArray {
  bytearray.concat(label_user, id)
}

pub fn valid_signature(
  attestation: Attestation,
  signature: ByteArray,
  attester: VerificationKey,
) -> Bool {
  bytearray.length(signature) == 64 && verify_ed25519_signature(
    attester,
    blake2b_256(cbor.serialise(attestation)),
    signature,
  )
}

fn tiers_ascending(tiers: List<Tier>) -> Bool {
  when tiers is {
    [] -> True
    [_] -> True
    [a, b, ..rest] -> and {
        a.tier < b.tier,
        a.min_score < b.min_score,
        a.boost_bps <= b.boost_bps,
        tiers_ascending([b, ..rest]),
      }
  }
}

fn valid_tier(tier: Tier) -> Bool {
  and {
    tier.tier >= 0,
    tier.tier <= 255,
    bytearray.length(tier.name) >= 1,
    bytearray.length(tier.name) <= 64,
    tier.min_score >= 0,
    tier.boost_bps >= 10_000,
    tier.boost_bps <= 50_000,
    bytearray.length(tier.image) <= 256,
  }
}

/// The CosmWasm contract's configuration rules.
pub fn valid_config(config: ReputationConfig) -> Bool {
  let count = list.length(config.tiers)
  and {
    config.governance.required >= 1,
    config.governance.required <= list.length(config.governance.keys),
    list.all(config.governance.keys, fn(key) { bytearray.length(key) == 28 }),
    list.length(list.unique(config.governance.keys)) == list.length(
      config.governance.keys,
    ),
    bytearray.length(config.attester) == 32,
    bytearray.length(config.collection) >= 1,
    bytearray.length(config.collection) <= 64,
    bytearray.length(config.description) <= 512,
    count >= 1,
    count <= 32,
    list.all(config.tiers, valid_tier),
    tiers_ascending(config.tiers),
  }
}

pub fn find_tier(config: ReputationConfig, tier: Int) -> Option<Tier> {
  list.find(config.tiers, fn(t) { t.tier == tier })
}

/// The reference datum a claim must write: wallet metadata from the tier, and the badge's data.
pub fn badge_datum(
  config: ReputationConfig,
  tier: Tier,
  attestation: Attestation,
) -> Cip68Datum {
  // "<collection> · <tier name>"
  let name = bytearray.concat(
    config.collection,
    bytearray.concat(#"20c2b720", tier.name),
  )
  let as_data = fn(value: Data) { value }
  Cip68Datum {
    metadata: [
      Pair("name", as_data(name)),
      Pair("image", as_data(tier.image)),
      Pair("description", as_data(config.description)),
      Pair("tier", as_data(tier.tier)),
      Pair("tier_name", as_data(tier.name)),
      Pair("score", as_data(attestation.score)),
      Pair("boost_bps", as_data(tier.boost_bps)),
      Pair("account", as_data(attestation.account)),
      Pair("issued_at", as_data(attestation.issued_at)),
    ],
    version: 1,
    extra: BadgeState {
      account: attestation.account,
      owner: attestation.owner,
      tier: tier.tier,
      score: attestation.score,
      boost_bps: tier.boost_bps,
      nonce: attestation.nonce,
      issued_at: attestation.issued_at,
    },
  }
}
