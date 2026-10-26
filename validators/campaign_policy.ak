//// Minting policy of the campaign tokens: creates a campaign from a ticket signed by Dyma
//// (`Create`), and mints or burns tokens only for campaigns whose state UTxO is spent in the same
//// transaction (`Delegate`, the state script checks the quantities). Parameterised by the
//// registry's policy id; the registry names the state script campaigns are created at.

use aiken/collection/dict
use aiken/collection/list
use aiken/primitive/bytearray
use cardano/address.{Script}
use cardano/assets.{PolicyId}
use cardano/transaction.{InlineDatum, Transaction}
use dyma/constants.{max_tx_window_ms, shard_token_prefix, state_token_prefix}
use dyma/escrow.{holding}
use dyma/holdings.{deposit_total, is_ada, quantity, state_token, state_value_ok}
use dyma/registry_rules.{find_registry}
use dyma/ticket.{
  campaign_key, initial_state, used_by_owner, valid_rules, valid_signature,
}
use dyma/time.{bounds}
use dyma/types.{Create, Delegate, EscrowMint, StateDatum}

validator campaign_policy(registry_policy: PolicyId) {
  mint(redeemer: EscrowMint, policy_id: PolicyId, self: Transaction) {
    when redeemer is {
      Create { ticket, signature } -> {
        let config = find_registry(self, registry_policy)
        expect Some((lower, upper)) = bounds(
          self.validity_range,
          max_tx_window_ms,
        )
        // No global pause over the funding (the factory refuses `create_campaign` while paused).
        expect
          when config.global_pauses is {
            [] -> True
            [latest, ..] -> latest.until <= lower
          }
        expect
          valid_rules(ticket, config, registry_policy, policy_id, lower, upper)
        expect valid_signature(ticket, signature, config)
        expect used_by_owner(ticket, self)
        let key = campaign_key(ticket.seed)
        expect [Pair(name, 1)] = dict.to_pairs(
          assets.tokens(self.mint, policy_id),
        )
        expect name == state_token(key)
        expect [output] = holding(self.outputs, policy_id, name)
        expect output.address.payment_credential == Script(config.escrow.state)
        let deposit = deposit_total(
          initial_state(ticket, config, lower, 0).campaign,
        )
        let funded = if is_ada(ticket.asset) {
          assets.lovelace_of(output.value) - deposit
        } else {
          quantity(output.value, ticket.asset)
        }
        let expected = initial_state(ticket, config, lower, funded)
        and {
          funded >= ticket.min_funding,
          output.datum == InlineDatum(StateDatum(expected)),
          state_value_ok(output.value, policy_id, expected, funded),
        }
      }
      // Tokens of campaigns whose state UTxO is spent here: that spend checks the exact amounts.
      Delegate ->
        dict.to_pairs(assets.tokens(self.mint, policy_id))
          |> list.all(
              fn(Pair(name, quantity)) {
                let prefix = bytearray.take(name, 1)
                let key = bytearray.drop(name, 1)
                and {
                  or {
                    prefix == state_token_prefix && quantity < 0,
                    prefix == shard_token_prefix,
                  },
                  list.any(
                    self.inputs,
                    fn(input) {
                      assets.quantity_of(
                        input.output.value,
                        policy_id,
                        state_token(key),
                      ) == 1
                    },
                  ),
                }
              },
            )
    }
  }

  else(_) {
    fail
  }
}
