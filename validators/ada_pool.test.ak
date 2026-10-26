//// ADA campaigns, where the pool and the owner's deposit share the lovelace, and two campaigns
//// spent by one transaction (double satisfaction).

use aiken/collection/list
use campaign_admin
use campaign_payout
use campaign_shard
use campaign_state
use cardano/address
use cardano/assets.{Assets}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use dyma/allocation.{link, payouts}
use dyma/clock
use dyma/constants.{pauser_budget_pauses}
use dyma/escrow
use dyma/holdings.{deposit_left, deposit_total, shard_token, state_token}
use dyma/testkit.{
  ada, admin_script, earner, ends_at, escrow_address, escrow_policy, minting,
  out_ref, owner, owner_key, paying, payout_script, registry_datum,
  registry_policy, shard_mint, shard_script, signed, spending, starts_at, tagged,
  ticket, to_key, treasury, tx_at,
}
use dyma/ticket.{campaign_key, initial_state}
use dyma/types.{
  Cancel, Claim, Complete, Distribution, Entry, EscrowAction, EscrowState,
  Finalized, Reveal, Shard, ShardDatum, ShardEntry, StateDatum, Ticket,
}

const day: Int = 86_400_000

const hour: Int = 3_600_000

/// 50 000 ADA, minimum payout 2 ADA, 40 recipients (2 shards).
const ada_ticket: Ticket =
  Ticket {
    ..ticket(),
    asset: ada(),
    min_funding: 1_000_000_000,
    min_payout: 2_000_000,
    max_recipients: 40,
  }

const funded: Int = 50_000_000_000

const base: EscrowState =
  initial_state(ada_ticket, registry_datum(), starts_at - hour, funded)

const key: ByteArray = base.campaign.key

const deposit: Int = deposit_total(base.campaign)

fn value(lovelace: Int) -> Assets {
  assets.from_lovelace(lovelace)
    |> assets.add(escrow_policy, state_token(key), 1)
}

fn input(state: EscrowState, lovelace: Int) -> Input {
  Input {
    output_reference: testkit.state_ref(),
    output: Output {
      address: escrow_address(),
      value: value(lovelace),
      datum: InlineDatum(StateDatum(state)),
      reference_script: None,
    },
  }
}

fn spend(state: EscrowState, action: EscrowAction, tx: Transaction) -> Bool {
  run_state(state, action, testkit.state_ref(), tx)
}

fn ledger(state: EscrowState, at: Int) {
  clock.read(
    state.clock,
    state.campaign.ends_at,
    pauser_budget_pauses * state.campaign.limits.max_pause_secs,
    at,
    [],
  ).ledger
}

const allocation: List<Entry> =
  list.map(list.range(1, 20), fn(n) { Entry { key: earner(n), points: n } })

const finalized_at: Int = ends_at + 2 * hour

const finalized: EscrowState =
  EscrowState {
    ..base,
    entry_count: 20,
    total_points: 210,
    chain_head: link(allocation, ""),
    lowest_committed: earner(1),
    finalized: Some(
      Finalized {
        at: finalized_at,
        challenge_ends_at: finalized_at + day,
        claim_deadline: finalized_at + 31 * day,
        gross: funded,
        max_fee: 500_000_000,
        distributable: 49_500_000_000,
        cap: 49_500_000_000,
        treasury: treasury(),
        allocation_hash: #"0000000000000000000000000000000000000000000000000000000000000002",
        allocation_uri: "ipfs://allocation",
      },
    ),
  }

const paid = payouts(allocation, 49_500_000_000, 210, 49_500_000_000, 2_000_000)

const shard_entries: List<ShardEntry> = {
    expect [entries] = paid.shards
    entries
  }

const reveal_at: Int = finalized_at + day + hour

const revealed: EscrowState =
  EscrowState {
    ..finalized,
    distribution: Some(
      Distribution {
        head: "",
        revealed: 20,
        shards_created: 1,
        shards_open: 1,
        allocated: paid.paid_total,
        allocated_count: 20,
        skipped_count: 0,
        skipped_total: 0,
        unclaimed_count: 0,
        unclaimed_total: 0,
      },
    ),
  }

fn shard_output(lovelace: Int, entries: List<ShardEntry>) -> Output {
  Output {
    address: testkit.shard_address(),
    value: assets.from_lovelace(lovelace)
      |> assets.add(escrow_policy, shard_token(key), 1),
    datum: InlineDatum(ShardDatum(Shard { campaign: key, index: 0, entries })),
    reference_script: None,
  }
}

test ada_reveal_moves_lovelace_and_one_deposit_into_the_shard() {
  let tx = tx_at(reveal_at)
    |> spending([input(finalized, deposit + funded)])
    |> paying(
        [
          Output {
            ..input(
              EscrowState { ..revealed, clock: ledger(finalized, reveal_at) },
              0,
            ).output,
            value: value(deposit + funded - paid.paid_total - 5_000_000),
          },
          shard_output(5_000_000 + paid.paid_total, shard_entries),
        ],
      )
    |> minting(shard_mint(1))
  spend(finalized, Reveal { entries: allocation, next: "" }, tx)
}

test ada_reveal_cannot_shortchange_the_shard() fail {
  let tx = tx_at(reveal_at)
    |> spending([input(finalized, deposit + funded)])
    |> paying(
        [
          Output {
            ..input(
              EscrowState { ..revealed, clock: ledger(finalized, reveal_at) },
              0,
            ).output,
            value: value(deposit + funded - paid.paid_total - 5_000_000),
          },
          shard_output(5_000_000 + paid.paid_total - 1, shard_entries),
        ],
      )
    |> minting(shard_mint(1))
  spend(finalized, Reveal { entries: allocation, next: "" }, tx)
}

test ada_claim_pays_lovelace() {
  expect Some(entry) = list.at(shard_entries, 0)
  let shard = shard_output(5_000_000 + paid.paid_total, shard_entries)
  let shard_input = Input { output_reference: out_ref(#"5a", 0), output: shard }
  let datum: Data = ShardDatum(
    Shard { campaign: key, index: 0, entries: shard_entries },
  )
  let tx = Transaction {
    ..tx_at(reveal_at + day),
    inputs: [shard_input],
    reference_inputs: [
      input(revealed, deposit + funded - paid.paid_total - 5_000_000),
      testkit.registry_input(registry_datum()),
    ],
    outputs: [
      to_key(entry.key, assets.from_lovelace(entry.amount)),
      shard_output(
        5_000_000 + paid.paid_total - entry.amount,
        list.drop(shard_entries, 1),
      ),
    ],
    extra_signatories: [entry.key],
  }
  campaign_shard.campaign_shard.spend(
    registry_policy,
    escrow_policy,
    Some(datum),
    Claim { index: 0 },
    out_ref(#"5a", 0),
    tx,
  )
}

/// Everything revealed, claimed for 30 000 ADA, the shard closed.
const settled: EscrowState =
  EscrowState {
    ..revealed,
    distribution: Some(
      Distribution {
        head: "",
        revealed: 20,
        shards_created: 1,
        shards_open: 0,
        allocated: paid.paid_total,
        allocated_count: 20,
        skipped_count: 0,
        skipped_total: 0,
        unclaimed_count: 5,
        unclaimed_total: paid.paid_total - 30_000_000_000,
      },
    ),
  }

const settled_lovelace: Int = deposit_left(settled) + funded - paid.paid_total

test ada_complete_pays_the_fee_in_lovelace() {
  let fee = 300_000_000
  spend(
    settled,
    Complete,
    tx_at(finalized_at + 32 * day)
      |> spending([input(settled, settled_lovelace)])
      |> paying(
          [
            tagged(treasury(), 1, assets.from_lovelace(fee)),
            tagged(
              owner().address,
              0,
              assets.from_lovelace(settled_lovelace - fee),
            ),
          ],
        )
      |> minting(assets.from_asset(escrow_policy, state_token(key), -1)),
  )
}

test ada_complete_cannot_skim_the_owner() fail {
  let fee = 300_000_000
  spend(
    settled,
    Complete,
    tx_at(finalized_at + 32 * day)
      |> spending([input(settled, settled_lovelace)])
      |> paying(
          [
            tagged(treasury(), 1, assets.from_lovelace(fee)),
            tagged(
              owner().address,
              0,
              assets.from_lovelace(settled_lovelace - fee - 1_000_000),
            ),
          ],
        )
      |> minting(assets.from_asset(escrow_policy, state_token(key), -1)),
  )
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

// ## Two campaigns in one transaction

const other_ticket: Ticket =
  Ticket { ..ada_ticket, seed: out_ref(#"5eed", 9), campaign_id: "other" }

const other: EscrowState =
  initial_state(other_ticket, registry_datum(), starts_at - hour, funded)

test one_refund_cannot_serve_two_campaigns() fail {
  // Both cancelled by their (same) owner; a single tagged refund is offered.
  let first = input(base, deposit + funded)
  let second = Input {
    output_reference: out_ref(#"0717", 0),
    output: Output {
      address: escrow_address(),
      value: assets.from_lovelace(deposit + funded)
        |> assets.add(
            escrow_policy,
            state_token(campaign_key(other_ticket.seed)),
            1,
          ),
      datum: InlineDatum(StateDatum(other)),
      reference_script: None,
    },
  }
  let tx = tx_at(starts_at - 2 * hour)
    |> spending([first, second])
    |> paying(
        [tagged(owner().address, 0, assets.from_lovelace(deposit + funded))],
      )
    |> signed([owner_key()])
    |> minting(
        assets.from_asset(escrow_policy, state_token(key), -1)
          |> assets.add(
              escrow_policy,
              state_token(campaign_key(other_ticket.seed)),
              -1,
            ),
      )
  run_state(other, Cancel, second.output_reference, tx)
}

test each_campaign_gets_its_own_refund() {
  let first = input(base, deposit + funded)
  let tx = tx_at(starts_at - 2 * hour)
    |> spending([first])
    |> paying(
        [tagged(owner().address, 0, assets.from_lovelace(deposit + funded))],
      )
    |> signed([owner_key()])
    |> minting(assets.from_asset(escrow_policy, state_token(key), -1))
  spend(base, Cancel, tx)
}
