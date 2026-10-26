//// What a campaign's UTxOs hold. The state UTxO keeps the pool (ADA or one native token) and
//// the owner's refundable ADA deposit: `state_deposit` for itself plus `shard_deposit` for every
//// claim shard it may still create (one per 20 entries of `max_recipients`).

use aiken/collection/list
use aiken/primitive/bytearray
use cardano/assets.{AssetName, Assets, PolicyId}
use dyma/constants.{shard_size, shard_token_prefix, state_token_prefix}
use dyma/types.{Asset, Campaign, EscrowState}

pub fn is_ada(asset: Asset) -> Bool {
  asset.policy == assets.ada_policy_id && asset.name == assets.ada_asset_name
}

pub fn quantity(value: Assets, asset: Asset) -> Int {
  assets.quantity_of(value, asset.policy, asset.name)
}

pub fn state_token(key: ByteArray) -> AssetName {
  bytearray.concat(state_token_prefix, key)
}

pub fn shard_token(key: ByteArray) -> AssetName {
  bytearray.concat(shard_token_prefix, key)
}

/// Claim shards the deposit was sized for.
pub fn max_shards(campaign: Campaign) -> Int {
  ( campaign.max_recipients + shard_size - 1 ) / shard_size
}

/// The whole deposit, paid at creation.
pub fn deposit_total(campaign: Campaign) -> Int {
  campaign.state_deposit + campaign.shard_deposit * max_shards(campaign)
}

pub fn shards_created(state: EscrowState) -> Int {
  when state.distribution is {
    Some(d) -> d.shards_created
    None -> 0
  }
}

/// Deposit still held by the state UTxO.
pub fn deposit_left(state: EscrowState) -> Int {
  let campaign = state.campaign
  campaign.state_deposit + campaign.shard_deposit * (
    max_shards(campaign) - shards_created(state)
  )
}

/// The pool held by a state UTxO's value.
pub fn pool_of(state: EscrowState, value: Assets) -> Int {
  if is_ada(state.campaign.asset) {
    assets.lovelace_of(value) - deposit_left(state)
  } else {
    quantity(value, state.campaign.asset)
  }
}

/// The value holds exactly `lovelace` and these tokens (zero quantities left out), nothing else.
pub fn holds_exactly(
  value: Assets,
  lovelace: Int,
  tokens: List<(PolicyId, AssetName, Int)>,
) -> Bool {
  let expected = list.foldl(
    tokens,
    assets.from_lovelace(lovelace),
    fn((policy, name, amount), acc) { assets.add(acc, policy, name, amount) },
  )
  value == expected
}

/// The tokens of the pool asset in a value of `amount` (none for ADA).
pub fn pool_tokens(
  asset: Asset,
  amount: Int,
) -> List<(PolicyId, AssetName, Int)> {
  if is_ada(asset) || amount == 0 {
    []
  } else {
    [(asset.policy, asset.name, amount)]
  }
}

/// The value a state UTxO must hold for a pool and the deposit still kept.
pub fn state_value_ok(
  value: Assets,
  own_policy: PolicyId,
  state: EscrowState,
  pool: Int,
) -> Bool {
  let asset = state.campaign.asset
  let deposit = deposit_left(state)
  let lovelace = if is_ada(asset) {
    deposit + pool
  } else {
    deposit
  }
  holds_exactly(
    value,
    lovelace,
    [
      (own_policy, state_token(state.campaign.key), 1),
      ..pool_tokens(asset, pool)
    ],
  )
}

test exact_holdings() {
  let policy = #"aa00000000000000000000000000000000000000000000000000000000"
  let value = assets.from_lovelace(5_000_000)
    |> assets.add(policy, "S", 1)
    |> assets.add(#"bb", "USDM", 10)
  and {
    holds_exactly(value, 5_000_000, [(policy, "S", 1), (#"bb", "USDM", 10)]),
    !holds_exactly(value, 5_000_000, [(policy, "S", 1)]),
    !holds_exactly(value, 4_999_999, [(policy, "S", 1), (#"bb", "USDM", 10)]),
  }
}
