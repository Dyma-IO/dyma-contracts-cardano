//// Holds the claim shards (shard token "L" ++ key, up to 20 payable entries and their deposit):
//// earners claim their entry, and shards close with their campaign's state. Parameterised by the
//// registry's policy id and the campaign token policy. Anything else sent to its address leaves
//// only with the registry governance's `Rescue`.

use aiken/collection/dict
use aiken/primitive/bytearray
use cardano/assets.{PolicyId}
use cardano/transaction.{OutputReference, Transaction}
use dyma/auth.{multisig_signed}
use dyma/constants.{shard_token_prefix}
use dyma/escrow.{shard_transition}
use dyma/registry_rules.{find_registry}
use dyma/types.{EscrowAction, EscrowDatum, Rescue, ShardDatum}

validator campaign_shard(registry_policy: PolicyId, token_policy: PolicyId) {
  spend(
    datum: Option<Data>,
    action: EscrowAction,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(own_input) = transaction.find_input(self.inputs, own_ref)
    let own = own_input.output
    when dict.to_pairs(assets.tokens(own.value, token_policy)) is {
      [Pair(name, 1)] -> {
        expect bytearray.take(name, 1) == shard_token_prefix
        expect Some(raw) = datum
        expect parsed: EscrowDatum = raw
        expect ShardDatum(shard) = parsed
        expect shard.campaign == bytearray.drop(name, 1)
        shard_transition(
          shard,
          action,
          own,
          token_policy,
          registry_policy,
          self,
        )
      }
      // Not a claim shard: something sent to this address by mistake.
      _ -> {
        expect Rescue = action
        multisig_signed(self, find_registry(self, registry_policy).governance)
      }
    }
  }

  else(_) {
    fail
  }
}
