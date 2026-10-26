//// Dyma Jobs escrow, with its configuration. One script, parameterised by a seed output: its hash
//// is the job token policy and the address holding the configuration and every job UTxO. See
//// lib/dyma/jobs.ak and docs/JOBS.md.

use aiken/collection/dict
use aiken/collection/list
use aiken/primitive/bytearray
use cardano/address.{Script, VerificationKey}
use cardano/assets.{PolicyId}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use dyma/auth.{multisig_signed, owner_authorised, signed_by}
use dyma/constants.{max_tx_window_ms}
use dyma/holdings.{holds_exactly}
use dyma/jobs.{
  Approved, AssignWorker, Burn, Create, Init, JobApproval, JobMint, JobSpend,
  JobState, JobsConfig, Reclaim, ReleasePay, Rescue, TopUp, UpdateConfig,
  WithdrawFunds, carries, config_nft_name, holds, initial_state, job_token,
  job_token_prefix, pool_of, split, valid_approval, valid_config, valid_ticket,
  valid_worker,
}
use dyma/time.{bounds}

validator job_escrow(seed: OutputReference) {
  mint(redeemer: JobMint, policy_id: PolicyId, self: Transaction) {
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
        expect config: JobsConfig = data
        and {
          valid_config(config),
          holds_exactly(
            output.value,
            assets.lovelace_of(output.value),
            [(policy_id, config_nft_name, 1)],
          ),
        }
      }

      Create { ticket, signature } -> {
        let config = find_config(self, policy_id)
        expect Some((lower, upper)) = bounds(
          self.validity_range,
          max_tx_window_ms,
        )
        let state = initial_state(ticket)
        expect [Pair(name, 1)] = minted
        expect name == job_token(state.key)
        expect [output, ..] = self.outputs
        let pool = pool_of(state, output.value)
        and {
          !config.paused,
          valid_ticket(ticket, signature, config, policy_id, lower, upper),
          list.any(
            self.inputs,
            fn(input) { input.output_reference == ticket.seed },
          ),
          owner_authorised(self, ticket.owner),
          output.address.payment_credential == Script(policy_id),
          output.datum == InlineDatum(state),
          pool >= ticket.min_funding,
          holds(output.value, policy_id, state, pool),
        }
      }

      // Job tokens only leave their UTxO to be burned; the spend of that UTxO decides when.
      Burn ->
        list.all(
          minted,
          fn(Pair(name, quantity)) { quantity < 0 && name != config_nft_name },
        )
    }
  }

  spend(
    datum: Option<Data>,
    redeemer: JobSpend,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(own_input) = transaction.find_input(self.inputs, own_ref)
    let own = own_input.output
    expect Script(policy_id) = own.address.payment_credential
    let tokens = dict.to_pairs(assets.tokens(own.value, policy_id))
    when redeemer is {
      UpdateConfig -> {
        expect [Pair(name, 1)] = tokens
        expect name == config_nft_name
        expect Some(raw) = datum
        expect current: JobsConfig = raw
        expect [output] = holding_outputs(self, policy_id, config_nft_name)
        expect InlineDatum(data) = output.datum
        expect next: JobsConfig = data
        and {
          multisig_signed(self, current.governance),
          // A new governance proves it can sign before it takes over.
          next.governance == current.governance || multisig_signed(
            self,
            next.governance,
          ),
          valid_config(next),
          output.address == own.address,
          holds_exactly(
            output.value,
            assets.lovelace_of(output.value),
            [(policy_id, config_nft_name, 1)],
          ),
        }
      }

      // Neither a job nor the configuration: something sent here by mistake.
      Rescue -> {
        expect [] = tokens
        multisig_signed(self, find_config(self, policy_id).governance)
      }

      job_action -> {
        expect [Pair(name, 1)] = tokens
        expect bytearray.take(name, 1) == job_token_prefix
        expect Some(raw) = datum
        expect state: JobState = raw
        expect name == job_token(state.key)
        // One job per transaction: outputs are checked by position.
        expect [_] = list.filter(
          self.inputs,
          fn(input) {
            input.output.address.payment_credential == Script(policy_id)
          },
        )
        let pool = pool_of(state, own.value)
        when job_action is {
          TopUp { expires_at } -> {
            let next = JobState { ..state, expires_at }
            expect [output, ..] = self.outputs
            let after = pool_of(next, output.value)
            and {
              owner_authorised(self, state.owner),
              expires_at >= state.expires_at,
              after >= pool,
              continues(output, own, next, after, policy_id),
            }
          }

          Approved { approval, signature } -> {
            let config = find_config(self, policy_id)
            expect Some((lower, upper)) = bounds(
              self.validity_range,
              max_tx_window_ms,
            )
            expect !config.paused
            expect
              valid_approval(
                approval,
                signature,
                config,
                policy_id,
                state,
                lower,
                upper,
              )
            approved(self, own, state, pool, config, approval, policy_id, name)
          }

          Reclaim -> {
            expect Some((lower, _)) = bounds(
              self.validity_range,
              max_tx_window_ms,
            )
            expect [to_owner, ..] = self.outputs
            and {
              lower > state.expires_at,
              owner_authorised(self, state.owner),
              to_owner.address == state.owner.address,
              carries(to_owner.value, state.asset, pool, state.deposit),
              burned(self, policy_id, name),
            }
          }

          _ -> False
        }
      }
    }
  }

  else(_) {
    fail
  }
}

/// An action Dyma approved for this job's current nonce.
fn approved(
  self: Transaction,
  own: Output,
  state: JobState,
  pool: Int,
  config: JobsConfig,
  approval: JobApproval,
  policy_id: PolicyId,
  name: ByteArray,
) -> Bool {
  let next = JobState { ..state, nonce: state.nonce + 1 }
  when approval.action is {
    AssignWorker { worker } -> {
      expect [output, ..] = self.outputs
      and {
        owner_authorised(self, state.owner),
        valid_worker(worker, state.owner, config.treasury),
        output.address == own.address,
        output.datum == InlineDatum(JobState { ..next, worker }),
        output.value == own.value,
      }
    }

    ReleasePay { gross, close } -> {
      expect Some(worker) = state.worker
      let (to_worker, fee, taken) = split(state, gross)
      let left = pool - taken
      expect [paid, ..rest] = self.outputs
      let after_fee = if fee > 0 {
        expect [to_treasury, ..after] = rest
        expect to_treasury.address == config.treasury
        expect carries(to_treasury.value, state.asset, fee, 0)
        after
      } else {
        rest
      }
      expect [last, ..] = after_fee
      and {
        gross > 0,
        to_worker > 0,
        left >= 0,
        signed_by(self, worker),
        paid.address.payment_credential == VerificationKey(worker),
        carries(paid.value, state.asset, to_worker, 0),
        if close {
          and {
            left == 0,
            burned(self, policy_id, name),
            last.address == state.owner.address,
            carries(last.value, state.asset, 0, state.deposit),
          }
        } else {
          continues(
            last,
            own,
            JobState {
              ..next,
              released: state.released + to_worker,
              fees_paid: state.fees_paid + fee,
            },
            left,
            policy_id,
          )
        },
      }
    }

    WithdrawFunds { amount, close } -> {
      let left = pool - amount
      expect [to_owner, ..rest] = self.outputs
      and {
        owner_authorised(self, state.owner),
        amount >= 0,
        left >= 0,
        to_owner.address == state.owner.address,
        if close {
          and {
            left == 0,
            burned(self, policy_id, name),
            carries(to_owner.value, state.asset, amount, state.deposit),
          }
        } else {
          expect [output, ..] = rest
          and {
            amount > 0,
            carries(to_owner.value, state.asset, amount, 0),
            continues(output, own, next, left, policy_id),
          }
        },
      }
    }
  }
}

/// The job UTxO goes on at the same address with `next` and exactly `pool`.
fn continues(
  output: Output,
  own: Output,
  next: JobState,
  pool: Int,
  policy_id: PolicyId,
) -> Bool {
  and {
    output.address == own.address,
    output.datum == InlineDatum(next),
    holds(output.value, policy_id, next, pool),
  }
}

fn burned(self: Transaction, policy_id: PolicyId, name: ByteArray) -> Bool {
  assets.quantity_of(self.mint, policy_id, name) == -1
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
fn find_config(self: Transaction, policy_id: PolicyId) -> JobsConfig {
  expect Some(input) = list.find(
    self.reference_inputs,
    fn(input: Input) {
      assets.quantity_of(input.output.value, policy_id, config_nft_name) == 1
    },
  )
  expect InlineDatum(data) = input.output.datum
  expect config: JobsConfig = data
  config
}
