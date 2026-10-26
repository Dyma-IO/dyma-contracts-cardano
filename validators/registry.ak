//// The registry: one UTxO per network, marked by the registry NFT, holding the trust
//// configuration every campaign escrow reads (roles, ticket key, treasury, limits, fee ceiling,
//// current escrow script) and the global pause ledger. The equivalent of the CosmWasm
//// `dyma-escrow-factory`, without the campaign index (each campaign is its own UTxO).
////
//// Parameterised by a seed output reference: the NFT can be minted once, when the seed is spent.
//// The script hash is the NFT's policy id and the registry address's payment credential.

use aiken/collection/dict
use aiken/collection/list
use aiken/collection/pairs
use cardano/address.{Script}
use cardano/assets.{PolicyId}
use cardano/transaction.{
  InlineDatum, Output, OutputReference, Spend, Transaction,
}
use dyma/auth.{multisig_signed, signed_by}
use dyma/clock.{global_totals_at}
use dyma/constants.{
  hard_max_pause_secs, max_global_history, max_pause_tx_window_ms, ms_per_sec,
  registry_nft_name,
}
use dyma/holdings.{holds_exactly}
use dyma/registry_rules.{valid_registry}
use dyma/time.{bounds}
use dyma/types.{
  GlobalPause, GlobalSegment, GlobalUnpause, GuardianPause, PauseKind,
  PauserPause, RegistryAction, RegistryDatum, UpdateConfig,
}

validator registry(seed: OutputReference) {
  /// One-shot: the seed is spent, exactly one NFT is minted and it goes to the registry address
  /// with a valid configuration.
  mint(_redeemer: Data, policy_id: PolicyId, self: Transaction) {
    expect list.any(self.inputs, fn(input) { input.output_reference == seed })
    expect [Pair(name, 1)] = dict.to_pairs(assets.tokens(self.mint, policy_id))
    expect name == registry_nft_name
    expect [output] = registry_outputs(self, policy_id)
    expect output.address.payment_credential == Script(policy_id)
    expect InlineDatum(data) = output.datum
    expect datum: RegistryDatum = data
    and {
      valid_registry(datum),
      // Global pauses only come from `GlobalPause` transactions.
      datum.global_pauses == [],
      holds_exactly(
        output.value,
        assets.lovelace_of(output.value),
        [(policy_id, registry_nft_name, 1)],
      ),
    }
  }

  spend(
    datum: Option<Data>,
    action: RegistryAction,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(own_input) = transaction.find_input(self.inputs, own_ref)
    expect Script(own_hash) = own_input.output.address.payment_credential
    if assets.quantity_of(own_input.output.value, own_hash, registry_nft_name) == 1 {
      expect Some(raw) = datum
      expect current: RegistryDatum = raw
      expect [output] = registry_outputs(self, own_hash)
      expect output.address == own_input.output.address
      expect InlineDatum(data) = output.datum
      expect next: RegistryDatum = data
      expect
        holds_exactly(
          output.value,
          assets.lovelace_of(output.value),
          [(own_hash, registry_nft_name, 1)],
        )
      when action is {
        UpdateConfig -> and {
            multisig_signed(self, current.governance),
            // A new governance proves it can sign before it takes over.
            next.governance == current.governance || multisig_signed(
              self,
              next.governance,
            ),
            next.global_pauses == current.global_pauses,
            valid_registry(next),
          }
        GlobalPause { until } -> {
          expect Some((lower, upper)) = bounds(
            self.validity_range,
            max_pause_tx_window_ms,
          )
          let kind = pause_kind(self, current)
          expect Some(history) = pause(current, kind, until, lower, upper)
          next == RegistryDatum { ..current, global_pauses: history }
        }
        GlobalUnpause -> {
          expect Some((lower, upper)) = bounds(
            self.validity_range,
            max_pause_tx_window_ms,
          )
          expect
            multisig_signed(self, current.guardian) || multisig_signed(
              self,
              current.governance,
            )
          expect [latest, ..older] = current.global_pauses
          // Active over the whole range: it ends at the range's start.
          expect upper < latest.until
          next == RegistryDatum {
            ..current,
            global_pauses: [GlobalSegment { ..latest, until: lower }, ..older],
          }
        }
      }
    } else {
      // A UTxO sent to the registry address by mistake: governance sweeps it while updating
      // the registry in the same transaction.
      expect Some(registry_input) = list.find(
        self.inputs,
        fn(input) {
          assets.quantity_of(input.output.value, own_hash, registry_nft_name) == 1
        },
      )
      expect Some(redeemer) = pairs.get_first(
        self.redeemers,
        Spend(registry_input.output_reference),
      )
      expect UpdateConfig: RegistryAction = redeemer
      True
    }
  }

  else(_) {
    fail
  }
}

fn registry_outputs(tx: Transaction, policy: PolicyId) -> List<Output> {
  list.filter(
    tx.outputs,
    fn(output) {
      assets.quantity_of(output.value, policy, registry_nft_name) == 1
    },
  )
}

/// The guardian or the governance pause as guardians; otherwise the pauser key.
fn pause_kind(tx: Transaction, config: RegistryDatum) -> PauseKind {
  if or {
    multisig_signed(tx, config.guardian),
    multisig_signed(tx, config.governance),
  } {
    GuardianPause
  } else if signed_by(tx, config.pauser) {
    PauserPause
  } else {
    fail @"not a pauser"
  }
}

/// The global pause ledger after a pause (the CosmWasm factory's `pause`). A pause lasts at
/// most `max_pause_secs` from now and never shortens an active one. The pauser can only start a
/// pause `max_pause_secs` after the latest one ended (so never while one is active, nor right
/// after a guardian lifted one); a guardian pause over an active pauser pause takes it over.
pub fn pause(
  config: RegistryDatum,
  kind: PauseKind,
  until: Int,
  lower: Int,
  upper: Int,
) -> Option<List<GlobalSegment>> {
  let max_ms = if config.limits.max_pause_secs < hard_max_pause_secs {
    config.limits.max_pause_secs * ms_per_sec
  } else {
    hard_max_pause_secs * ms_per_sec
  }
  let history = config.global_pauses
  let new_segment = fn(
    history: List<GlobalSegment>,
    start: Int,
    until: Int,
    kind: PauseKind,
  ) {
    expect Some(before) = global_totals_at(history, start)
    list.take(
      [
        GlobalSegment {
          start,
          until,
          kind,
          guardian_before: before.guardian,
          pauser_before: before.pauser,
        },
        ..history
      ],
      max_global_history,
    )
  }
  if until <= upper || until > lower + max_ms {
    None
  } else {
    when (kind, history) is {
      (PauserPause, []) -> Some(new_segment([], lower, until, PauserPause))
      (PauserPause, [latest, ..]) ->
        if lower >= latest.until + max_ms {
          Some(new_segment(history, lower, until, PauserPause))
        } else {
          None
        }
      (GuardianPause, []) -> Some(new_segment([], lower, until, GuardianPause))
      (GuardianPause, [latest, ..older]) ->
        if latest.until <= lower {
          // Nothing active: a new guardian pause.
          Some(new_segment(history, lower, until, GuardianPause))
        } else {
          let until = if latest.until > until {
            latest.until
          } else {
            until
          }
          when latest.kind is {
            // Extends the active guardian pause.
            GuardianPause -> Some([GlobalSegment { ..latest, until }, ..older])
            // Takes over the active pauser pause: its pauser part ends now.
            PauserPause ->
              if latest.start < lower {
                let closed = [GlobalSegment { ..latest, until: lower }, ..older]
                Some(new_segment(closed, lower, until, GuardianPause))
              } else {
                Some(new_segment(older, lower, until, GuardianPause))
              }
          }
        }
    }
  }
}
