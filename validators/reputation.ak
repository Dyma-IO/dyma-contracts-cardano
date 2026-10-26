//// Dyma Reputation badges (CIP-68), with their configuration. One script, parameterised by a
//// seed output: its hash is the badges' policy id and the address holding the configuration and
//// every badge reference. See lib/dyma/reputation.ak.

use aiken/collection/dict
use aiken/collection/list
use aiken/collection/pairs
use aiken/primitive/bytearray
use cardano/address.{Script}
use cardano/assets.{PolicyId}
use cardano/transaction.{
  InlineDatum, Input, Mint, Output, OutputReference, Transaction,
}
use dyma/auth.{multisig_signed, signed_by}
use dyma/badge.{
  Burn, Cip68Datum, Claim, Init, ReputationConfig, ReputationMint,
  ReputationSpend, Retire, UpdateConfig, attestation_version, badge_datum,
  badge_id, config_nft_name, find_tier, label_reference, max_issue_skew_ms,
  reference_name, user_name, valid_config, valid_signature,
}
use dyma/constants.{max_tx_window_ms}
use dyma/holdings.{holds_exactly}
use dyma/time.{bounds}

validator reputation(seed: OutputReference) {
  mint(redeemer: ReputationMint, policy_id: PolicyId, self: Transaction) {
    let minted = dict.to_pairs(assets.tokens(self.mint, policy_id))
    when redeemer is {
      Init -> {
        expect
          list.any(self.inputs, fn(input) { input.output_reference == seed })
        expect [Pair(name, 1)] = minted
        expect name == config_nft_name
        expect [output] = holding_outputs(self, policy_id, config_nft_name)
        expect output.address.payment_credential == Script(policy_id)
        expect InlineDatum(data) = output.datum
        expect config: ReputationConfig = data
        and {
          valid_config(config),
          holds_exactly(
            output.value,
            assets.lovelace_of(output.value),
            [(policy_id, config_nft_name, 1)],
          ),
        }
      }

      Claim { attestation, signature } -> {
        let config = find_config(self, policy_id)
        expect Some((lower, upper)) = bounds(
          self.validity_range,
          max_tx_window_ms,
        )
        expect Some(tier) = find_tier(config, attestation.tier)
        let id = badge_id(attestation.seed)
        let reference = reference_name(id)
        let user = user_name(id)
        expect [output] = holding_outputs(self, policy_id, reference)
        and {
          !config.paused,
          attestation.version == attestation_version,
          attestation.policy == policy_id,
          bytearray.length(attestation.account) == 32,
          bytearray.length(attestation.owner) == 28,
          attestation.nonce >= 1,
          valid_signature(attestation, signature, config.attester),
          // Single use: the attestation's seed is spent here.
          list.any(
            self.inputs,
            fn(input) { input.output_reference == attestation.seed },
          ),
          signed_by(self, attestation.owner),
          upper < attestation.expires_at,
          attestation.issued_at < attestation.expires_at,
          attestation.issued_at <= lower + max_issue_skew_ms,
          attestation.score >= tier.min_score,
          // The new pair; anything else of this policy can only burn (retired badges).
          list.all(
            minted,
            fn(Pair(name, quantity)) {
              if name == reference || name == user {
                quantity == 1
              } else {
                quantity < 0 && name != config_nft_name
              }
            },
          ),
          list.has(pairs.keys(minted), reference),
          list.has(pairs.keys(minted), user),
          output.address.payment_credential == Script(policy_id),
          holds_exactly(
            output.value,
            assets.lovelace_of(output.value),
            [(policy_id, reference, 1)],
          ),
          output.datum == InlineDatum(badge_datum(config, tier, attestation)),
        }
      }

      Burn ->
        list.all(
          minted,
          fn(Pair(name, quantity)) { quantity < 0 && name != config_nft_name },
        )
    }
  }

  spend(
    datum: Option<Data>,
    redeemer: ReputationSpend,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(own) = transaction.find_input(self.inputs, own_ref)
    expect Script(policy_id) = own.output.address.payment_credential
    let tokens = dict.to_pairs(assets.tokens(own.output.value, policy_id))
    when redeemer is {
      UpdateConfig -> {
        expect [Pair(name, 1)] = tokens
        expect name == config_nft_name
        expect Some(raw) = datum
        expect current: ReputationConfig = raw
        expect [output] = holding_outputs(self, policy_id, config_nft_name)
        expect InlineDatum(data) = output.datum
        expect next: ReputationConfig = data
        and {
          multisig_signed(self, current.governance),
          // A new governance proves it can sign before it takes over.
          next.governance == current.governance || multisig_signed(
            self,
            next.governance,
          ),
          valid_config(next),
          output.address == own.output.address,
          holds_exactly(
            output.value,
            assets.lovelace_of(output.value),
            [(policy_id, config_nft_name, 1)],
          ),
        }
      }

      Retire -> {
        let config = find_config(self, policy_id)
        let reference_token = when tokens is {
          [Pair(name, 1)] ->
            if bytearray.take(name, 4) == label_reference {
              Some(name)
            } else {
              None
            }
          _ -> None
        }
        when reference_token is {
          // A badge reference: superseded by a newer claim of its account, or revoked.
          Some(name) -> {
            expect Some(raw) = datum
            expect badge: Cip68Datum = raw
            let superseded = when
              pairs.get_first(self.redeemers, Mint(policy_id))
            is {
              Some(mint_redeemer) -> {
                expect action: ReputationMint = mint_redeemer
                when action is {
                  Claim { attestation, .. } -> and {
                      attestation.account == badge.extra.account,
                      attestation.nonce > badge.extra.nonce,
                    }
                  _ -> False
                }
              }
              None -> False
            }
            and {
              superseded || multisig_signed(self, config.governance),
              assets.quantity_of(self.mint, policy_id, name) == -1,
            }
          }
          // Anything else sent here by mistake: governance takes it back.
          None -> multisig_signed(self, config.governance)
        }
      }
    }
  }

  else(_) {
    fail
  }
}

fn holding_outputs(
  self: Transaction,
  policy_id: PolicyId,
  name: ByteArray,
) -> List<Output> {
  list.filter(
    self.outputs,
    fn(output) { assets.quantity_of(output.value, policy_id, name) == 1 },
  )
}

/// The configuration, read as a reference input (the one holding the configuration NFT).
fn find_config(self: Transaction, policy_id: PolicyId) -> ReputationConfig {
  expect Some(input) = list.find(
    self.reference_inputs,
    fn(input: Input) {
      assets.quantity_of(input.output.value, policy_id, config_nft_name) == 1
    },
  )
  expect InlineDatum(data) = input.output.datum
  expect config: ReputationConfig = data
  config
}
