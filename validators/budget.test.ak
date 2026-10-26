//// Execution budget of the largest transactions. Every transaction is a module constant
//// (evaluated at compile time), so a test's units are the validator's alone. Mainnet limits
//// per transaction: 16 500 000 memory units and 10 000 000 000 CPU steps (scripts/test-report.py
//// prints the share). Run `scripts/test-report.py -m budget` after any change to the validators.

use aiken/collection/list
use campaign_admin
use campaign_payout
use campaign_policy
use campaign_shard
use campaign_state
use cardano/address
use cardano/assets
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use dyma/allocation.{link, payouts}
use dyma/clock
use dyma/constants.{pauser_budget_pauses}
use dyma/escrow
use dyma/holdings.{deposit_total, shard_token, state_token}
use dyma/testkit.{
  admin_script, burn_state, earner, ends_at, escrow_policy, minting, operator,
  owner, paying, payout_script, registry_datum, registry_policy, shard_mint,
  shard_script, signed, spending, starts_at, state_input, state_output,
  state_ref, tagged, ticket, treasury, tx_at, usdm_policy,
}
use dyma/ticket.{initial_state}
use dyma/types.{
  Claim, ClockLedger, CloseShards, Commit, Complete, Delegate, Distribution,
  Entry, EscrowAction, EscrowState, Finalized, Reveal, Shard, ShardClose,
  ShardDatum, ShardEntry, StateDatum, Ticket,
}

const day: Int = 86_400_000

/// A 200-recipient USDM campaign (10 claim shards of deposit).
const big_ticket: Ticket = Ticket { ..ticket(), max_recipients: 200 }

const funded: Int = 50_000_000_000

const base: EscrowState =
  initial_state(big_ticket, registry_datum(), starts_at - 3_600_000, funded)

const deposit: Int = deposit_total(base.campaign)

const batch_a: List<Entry> =
  list.map(list.range(1, 100), fn(n) { Entry { key: earner(n), points: n } })

const batch_b: List<Entry> =
  list.map(list.range(101, 200), fn(n) { Entry { key: earner(n), points: n } })

const total_points: Int = 20_100

fn usdm_value(lovelace: Int, amount: Int) {
  assets.from_lovelace(lovelace)
    |> assets.add(escrow_policy, state_token(base.campaign.key), 1)
    |> assets.add(usdm_policy, "USDM", amount)
}

fn ledger_at(state: EscrowState, at: Int) -> ClockLedger {
  clock.read(
    state.clock,
    state.campaign.ends_at,
    pauser_budget_pauses * state.campaign.limits.max_pause_secs,
    at,
    [],
  ).ledger
}

/// What the chain runs for a state input: `campaign_state`, plus the script it forwards the
/// transition to (`campaign_payout` or `campaign_admin`, a zero-ADA withdrawal that reads the
/// redeemer from the transaction).
fn run_state(
  state: EscrowState,
  action: EscrowAction,
  own_ref: transaction.OutputReference,
  tx: Transaction,
) -> Bool {
  let datum: Data = StateDatum(state)
  let forwarded_to = if escrow.is_payout(action) {
    Some(payout_script)
  } else if escrow.is_admin(action) {
    Some(admin_script)
  } else {
    None
  }
  let redeemer: Data = action
  let tx = when forwarded_to is {
    Some(script) ->
      Transaction {
        ..tx,
        withdrawals: [Pair(address.Script(script), 0)],
        redeemers: [Pair(transaction.Spend(own_ref), redeemer), ..tx.redeemers],
      }
    None -> tx
  }
  let void: Data = Void
  and {
    campaign_state.campaign_state.spend(
      registry_policy,
      escrow_policy,
      shard_script,
      payout_script,
      admin_script,
      Some(datum),
      action,
      own_ref,
      tx,
    ),
    when forwarded_to is {
      Some(script) ->
        if script == payout_script {
          campaign_payout.campaign_payout.withdraw(
            registry_policy,
            escrow_policy,
            shard_script,
            void,
            address.Script(script),
            tx,
          )
        } else {
          campaign_admin.campaign_admin.withdraw(
            registry_policy,
            escrow_policy,
            shard_script,
            void,
            address.Script(script),
            tx,
          )
        }
      None -> True
    },
  }
}

// ## Commit 100 entries

const commit_at: Int = ends_at + 3_600_000

const after_b: EscrowState =
  EscrowState {
    ..base,
    entry_count: 100,
    total_points: 15_050,
    chain_head: link(batch_b, ""),
    lowest_committed: earner(101),
    clock: ledger_at(base, commit_at - 3_600_000),
  }

const commit_tx: Transaction =
  tx_at(commit_at)
    |> spending([state_input(after_b, usdm_value(deposit, funded))])
    |> paying(
        [
          state_output(
            EscrowState {
              ..after_b,
              entry_count: 200,
              total_points,
              chain_head: link(batch_a, link(batch_b, "")),
              lowest_committed: earner(1),
              clock: ledger_at(after_b, commit_at),
            },
            usdm_value(deposit, funded),
          ),
        ],
      )
    |> signed([operator()])

test budget_commit_100_entries() {
  run_state(
    after_b,
    Commit { version: 0, entries: batch_a },
    state_ref(),
    commit_tx,
  )
}

// ## Reveal 100 entries into 5 shards

const finalized_at: Int = commit_at + 3_600_000

const challenge_end: Int = finalized_at + day

const finalized: EscrowState =
  EscrowState {
    ..base,
    entry_count: 200,
    total_points,
    chain_head: link(batch_a, link(batch_b, "")),
    lowest_committed: earner(1),
    finalized: Some(
      Finalized {
        at: finalized_at,
        challenge_ends_at: challenge_end,
        claim_deadline: challenge_end + 30 * day,
        gross: funded,
        max_fee: 500_000_000,
        distributable: 49_500_000_000,
        cap: 49_500_000_000,
        treasury: treasury(),
        allocation_hash: #"0000000000000000000000000000000000000000000000000000000000000001",
        allocation_uri: "https://api.dyma.example/allocations/1.csv",
      },
    ),
  }

const reveal_at: Int = challenge_end + 3_600_000

const paid_a =
  payouts(batch_a, 49_500_000_000, total_points, 49_500_000_000, 1_000_000)

const revealed: EscrowState =
  EscrowState {
    ..finalized,
    distribution: Some(
      Distribution {
        head: link(batch_b, ""),
        revealed: 100,
        shards_created: 5,
        shards_open: 5,
        allocated: paid_a.paid_total,
        allocated_count: 100,
        skipped_count: 0,
        skipped_total: 0,
        unclaimed_count: 0,
        unclaimed_total: 0,
      },
    ),
  }

fn shard_output(index: Int, entries: List<ShardEntry>) -> Output {
  Output {
    address: testkit.shard_address(),
    value: assets.from_lovelace(5_000_000)
      |> assets.add(escrow_policy, shard_token(base.campaign.key), 1)
      |> assets.add(
          usdm_policy,
          "USDM",
          list.foldl(entries, 0, fn(e, acc) { acc + e.amount }),
        ),
    datum: InlineDatum(
      ShardDatum(Shard { campaign: base.campaign.key, index, entries }),
    ),
    reference_script: None,
  }
}

const shard_outputs: List<Output> =
  list.indexed_map(
    paid_a.shards,
    fn(index, entries) { shard_output(index, entries) },
  )

const reveal_tx: Transaction =
  tx_at(reveal_at)
    |> spending([state_input(finalized, usdm_value(deposit, funded))])
    |> paying(
        [
          state_output(
            EscrowState { ..revealed, clock: ledger_at(finalized, reveal_at) },
            usdm_value(deposit - 25_000_000, funded - paid_a.paid_total),
          ),
          ..shard_outputs
        ],
      )
    |> minting(shard_mint(5))

test budget_reveal_100_entries_into_5_shards() {
  run_state(
    finalized,
    Reveal { entries: batch_a, next: link(batch_b, "") },
    state_ref(),
    reveal_tx,
  )
}

// ## Close 5 full shards after the claim deadline

const close_at: Int = challenge_end + 31 * day

fn shard_input(index: Int, output: Output) -> Input {
  Input { output_reference: testkit.out_ref(#"5a", index), output }
}

const shard_inputs: List<Input> =
  list.indexed_map(
    shard_outputs,
    fn(index, output) { shard_input(index, output) },
  )

const revealed_value =
  usdm_value(deposit - 25_000_000, funded - paid_a.paid_total)

const close_tx: Transaction =
  tx_at(close_at)
    |> spending([state_input(revealed, revealed_value), ..shard_inputs])
    |> paying(
        [
          state_output(
            EscrowState {
              ..revealed,
              distribution: Some(
                Distribution {
                  head: link(batch_b, ""),
                  revealed: 100,
                  shards_created: 5,
                  shards_open: 0,
                  allocated: paid_a.paid_total,
                  allocated_count: 100,
                  skipped_count: 0,
                  skipped_total: 0,
                  unclaimed_count: 100,
                  unclaimed_total: paid_a.paid_total,
                },
              ),
              clock: ledger_at(revealed, close_at),
            },
            revealed_value,
          ),
          tagged(
            owner().address,
            0,
            assets.from_lovelace(25_000_000)
              |> assets.add(usdm_policy, "USDM", paid_a.paid_total),
          ),
        ],
      )
    |> minting(shard_mint(-5))

test budget_close_5_shards() {
  run_state(revealed, CloseShards, state_ref(), close_tx)
}

// ## Complete with a fee

const settled: EscrowState =
  EscrowState {
    ..revealed,
    distribution: Some(
      Distribution {
        head: "",
        revealed: 200,
        shards_created: 10,
        shards_open: 0,
        allocated: 49_000_000_000,
        allocated_count: 200,
        skipped_count: 0,
        skipped_total: 0,
        unclaimed_count: 50,
        unclaimed_total: 9_000_000_000,
      },
    ),
  }

const settled_value = usdm_value(3_000_000, 1_000_000_000)

const complete_tx: Transaction =
  tx_at(close_at)
    |> spending([state_input(settled, settled_value)])
    |> paying(
        [
          tagged(
            treasury(),
            1,
            assets.from_lovelace(1_500_000)
              |> assets.add(usdm_policy, "USDM", 400_000_000),
          ),
          tagged(
            owner().address,
            0,
            assets.from_lovelace(1_500_000)
              |> assets.add(usdm_policy, "USDM", 600_000_000),
          ),
        ],
      )
    |> minting(burn_state())

test budget_complete_with_fee() {
  run_state(settled, Complete, state_ref(), complete_tx)
}

// ## The other scripts of those transactions

const close_tx_with_redeemer: Transaction = {
    let redeemer: Data = CloseShards
    Transaction {
      ..close_tx,
      redeemers: [Pair(transaction.Spend(state_ref()), redeemer)],
    }
  }

test budget_each_shard_close() {
  expect [first, ..] = shard_inputs
  expect InlineDatum(datum) = first.output.datum
  campaign_shard.campaign_shard.spend(
    registry_policy,
    escrow_policy,
    Some(datum),
    ShardClose,
    first.output_reference,
    close_tx_with_redeemer,
  )
}

test budget_delegate_mint_of_5_shards() {
  campaign_policy.campaign_policy.mint(
    registry_policy,
    Delegate,
    escrow_policy,
    reveal_tx,
  )
}

// ## A claim from a full shard

const claim_shard: Output = {
    expect [first, ..] = shard_outputs
    first
  }

const claim_entries: List<ShardEntry> = {
    expect InlineDatum(data) = claim_shard.datum
    expect ShardDatum(shard): types.EscrowDatum = data
    shard.entries
  }

const claimed: ShardEntry = {
    expect Some(entry) = list.at(claim_entries, 10)
    entry
  }

const claim_tx: Transaction =
  Transaction {
    ..tx_at(reveal_at + day),
    inputs: [
      Input { output_reference: testkit.out_ref(#"5a", 0), output: claim_shard },
    ],
    reference_inputs: [
      state_input(revealed, revealed_value),
      testkit.registry_input(registry_datum()),
    ],
    outputs: [
      testkit.to_key(
        claimed.key,
        assets.from_lovelace(1_500_000)
          |> assets.add(usdm_policy, "USDM", claimed.amount),
      ),
      Output {
        ..claim_shard,
        value: assets.add(
          claim_shard.value,
          usdm_policy,
          "USDM",
          -claimed.amount,
        ),
        datum: InlineDatum(
          ShardDatum(
            Shard {
              campaign: base.campaign.key,
              index: 0,
              entries: list.delete(claim_entries, claimed),
            },
          ),
        ),
      },
    ],
    extra_signatories: [claimed.key],
  }

test budget_claim_from_a_full_shard() {
  expect InlineDatum(datum) = claim_shard.datum
  campaign_shard.campaign_shard.spend(
    registry_policy,
    escrow_policy,
    Some(datum),
    Claim { index: 10 },
    testkit.out_ref(#"5a", 0),
    claim_tx,
  )
}
