//// Pauses, ownership transfers and clock checkpoints of campaign state UTxOs, run as a zero-ADA
//// withdrawal from this script's reward account: `campaign_state` forwards those transitions
//// here, and every campaign state the transaction spends with one of them is validated
//// (lib/dyma/escrow.ak `admin_transition`). The reward account is registered once at deployment
//// and can never be deregistered.

use aiken/crypto.{ScriptHash}
use cardano/address.{Credential}
use cardano/assets.{PolicyId}
use cardano/certificate.{Certificate, RegisterCredential}
use cardano/transaction.{Transaction}
use dyma/escrow.{admin_transition, forwarded, is_admin}

validator campaign_admin(
  registry_policy: PolicyId,
  token_policy: PolicyId,
  shard_script: ScriptHash,
) {
  withdraw(_redeemer: Data, _account: Credential, self: Transaction) {
    forwarded(
      self,
      registry_policy,
      token_policy,
      shard_script,
      is_admin,
      admin_transition,
    )
  }

  /// Registering the reward account (once); never deregistering or delegating it.
  publish(_redeemer: Data, certificate: Certificate, _self: Transaction) {
    when certificate is {
      RegisterCredential { .. } -> True
      _ -> False
    }
  }

  else(_) {
    fail
  }
}
