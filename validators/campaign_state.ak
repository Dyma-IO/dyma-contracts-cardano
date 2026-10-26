//// Holds each campaign's state UTxO (state token "S" ++ key, the pool and the owner's deposit)
//// and runs funding, allocation and challenge transitions (lib/dyma/escrow.ak). Payouts are
//// validated by `campaign_payout`, pauses, ownership and clock checkpoints by `campaign_admin`:
//// the chosen one must run in the same transaction (a zero-ADA withdrawal from its script).
//// Parameterised by the registry's policy id, the campaign token policy and the shard, payout and
//// admin scripts, so its hash names the whole escrow version. Anything else sent to its address leaves only with the registry
//// governance's `Rescue`.

use aiken/collection/dict
use aiken/collection/pairs
use aiken/crypto.{ScriptHash}
use aiken/primitive/bytearray
use cardano/address.{Script}
use cardano/assets.{PolicyId}
use cardano/transaction.{OutputReference, Transaction}
use dyma/auth.{multisig_signed}
use dyma/constants.{state_token_prefix}
use dyma/escrow.{Ctx, is_admin, is_payout, state_transition}
use dyma/registry_rules.{find_registry}
use dyma/types.{EscrowAction, EscrowDatum, Rescue, StateDatum}

validator campaign_state(
  registry_policy: PolicyId,
  token_policy: PolicyId,
  shard_script: ScriptHash,
  payout_script: ScriptHash,
  admin_script: ScriptHash,
) {
  spend(
    datum: Option<Data>,
    action: EscrowAction,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(own_input) = transaction.find_input(self.inputs, own_ref)
    let own = own_input.output
    when dict.to_pairs(assets.tokens(own.value, token_policy)) is {
      [Pair(name, 1)] ->
        if is_payout(action) {
          // `campaign_payout` validates this input (it reads the redeemer from the transaction).
          pairs.has_key(self.withdrawals, Script(payout_script))
        } else if is_admin(action) {
          pairs.has_key(self.withdrawals, Script(admin_script))
        } else {
          expect bytearray.take(name, 1) == state_token_prefix
          expect Some(raw) = datum
          expect parsed: EscrowDatum = raw
          expect StateDatum(state) = parsed
          expect state.campaign.key == bytearray.drop(name, 1)
          state_transition(
            Ctx {
              tx: self,
              own_ref,
              own,
              policy: token_policy,
              shard_script,
              config: find_registry(self, registry_policy),
              state,
            },
            action,
          )
        }
      // Not a campaign: something sent to this address by mistake.
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
