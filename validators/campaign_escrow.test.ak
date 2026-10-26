//// Campaign escrow scenarios: one USDM campaign walked through every transition, each with the
//// success path and the main ways it must fail.

use aiken/collection/list
use aiken/primitive/bytearray
use campaign_admin
use campaign_payout
use campaign_policy
use campaign_shard
use campaign_state
use cardano/address
use cardano/assets.{Assets}
use cardano/transaction.{InlineDatum, Output, Transaction}
use dyma/allocation.{link, payouts}
use dyma/clock
use dyma/constants.{pauser_budget_pauses}
use dyma/escrow
use dyma/holdings.{deposit_left, shard_token, state_token}
use dyma/testkit.{
  admin_script, burn_state, created, created_at, earner, ends_at, escrow_address,
  escrow_policy, full_deposit, guardian, key, minting, operator, owner,
  owner_key, pauser, paying, payout_script, registry_datum, registry_policy,
  shard_mint, shard_script, shard_value, signed, spending, starts_at,
  state_input, state_output, state_ref, state_value, tagged, ticket,
  ticket_signature, to_key, treasury, tx_at, usdm_policy, wallet_input,
  with_registry,
}
use dyma/types.{
  AcceptOwnership, Cancel, CancelOwnershipTransfer, Claim, ClockLedger,
  CloseShards, Commit, Complete, Create, Delegate, Dispute, Distribution, Entry,
  EscrowAction, EscrowState, Finalize, Finalized, GlobalSegment, GuardianPause,
  LocalPause, Pause, PauserPause, PendingOwner, RaiseDispute, ReclaimExpired,
  RegistryDatum, Reject, Rescue, Reset, Resolve, Reveal, Shard, ShardClose,
  ShardDatum, ShardEntry, StateDatum, Sync, TopUp, TransferOwnership, Unpause,
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

// ## Scenario

/// 10 000 USDM.
const funded: Int = 10_000_000_000

const hour: Int = 3_600_000

const day: Int = 86_400_000

fn fresh() -> EscrowState {
  created(funded)
}

fn fresh_value() -> Assets {
  state_value(funded, full_deposit())
}

fn entries(from: Int, to: Int) -> List<Entry> {
  list.map(list.range(from, to), fn(n) { Entry { key: earner(n), points: n } })
}

/// The allocation: earners 1..30, weighted 1..30, committed as 21..30 then 1..20.
fn batch_end() -> List<Entry> {
  entries(21, 30)
}

fn batch_start() -> List<Entry> {
  entries(1, 20)
}

fn head() -> ByteArray {
  link(batch_start(), link(batch_end(), ""))
}

/// The ledger a transaction landing at `at` stores.
fn ledger_at(
  state: EscrowState,
  at: Int,
  history: List<GlobalSegment>,
) -> ClockLedger {
  clock.read(
    state.clock,
    state.campaign.ends_at,
    pauser_budget_pauses * state.campaign.limits.max_pause_secs,
    at,
    history,
  ).ledger
}

fn advanced(state: EscrowState, at: Int) -> EscrowState {
  EscrowState { ..state, clock: ledger_at(state, at, []) }
}

fn committed() -> EscrowState {
  EscrowState {
    ..fresh(),
    entry_count: 30,
    total_points: 465,
    chain_head: head(),
    lowest_committed: earner(1),
  }
}

const finalized_at: Int = ends_at + 2 * hour

const challenge_ends_at: Int = finalized_at + 600_000 - 1 + day

const claim_deadline: Int = challenge_ends_at + 30 * day

fn finalized() -> EscrowState {
  EscrowState {
    ..committed(),
    finalized: Some(
      Finalized {
        at: finalized_at,
        challenge_ends_at,
        claim_deadline,
        gross: funded,
        max_fee: 100_000_000,
        distributable: 9_900_000_000,
        cap: 9_900_000_000,
        treasury: treasury(),
        allocation_hash: #"0000000000000000000000000000000000000000000000000000000000000001",
        allocation_uri: "https://api.dyma.example/allocations/1.csv",
      },
    ),
  }
}

/// Earners 1..20 revealed into one shard.
fn first_payouts() {
  payouts(batch_start(), 9_900_000_000, 465, 9_900_000_000, 1_000_000)
}

fn revealed() -> EscrowState {
  let paid = first_payouts()
  EscrowState {
    ..finalized(),
    distribution: Some(
      Distribution {
        head: link(batch_end(), ""),
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
}

fn revealed_value() -> Assets {
  state_value(funded - first_payouts().paid_total, full_deposit() - 5_000_000)
}

fn first_shard() -> Shard {
  expect [entries] = first_payouts().shards
  Shard { campaign: key(), index: 0, entries }
}

fn spend(state: EscrowState, action: EscrowAction, tx: Transaction) -> Bool {
  run_state(state, action, state_ref(), tx)
}

/// A transaction spending the state UTxO at `at`, continuing it as `next`.
fn transition(
  state: EscrowState,
  value: Assets,
  at: Int,
  next: EscrowState,
  next_value: Assets,
  signers: List<ByteArray>,
) -> Transaction {
  tx_at(at)
    |> spending([state_input(state, value)])
    |> paying([state_output(next, next_value)])
    |> signed(signers)
}

// ## Creation

fn seed_input() -> transaction.Input {
  transaction.Input {
    output_reference: ticket().seed,
    output: Output {
      address: address.from_verification_key(owner_key()),
      value: assets.from_lovelace(50_000_000)
        |> assets.add(usdm_policy, "USDM", funded),
      datum: transaction.NoDatum,
      reference_script: None,
    },
  }
}

fn create_tx(state_out: Output) -> Transaction {
  tx_at(created_at)
    |> spending([seed_input()])
    |> paying([state_out])
    |> signed([owner_key()])
    |> minting(assets.from_asset(escrow_policy, state_token(key()), 1))
}

fn create(tx: Transaction, signature: ByteArray) -> Bool {
  campaign_policy.campaign_policy.mint(
    registry_policy,
    Create { ticket: ticket(), signature },
    escrow_policy,
    tx,
  )
}

test create_funds_the_campaign() {
  create(create_tx(state_output(fresh(), fresh_value())), ticket_signature)
}

test create_refuses_a_forged_ticket() fail {
  create(
    create_tx(state_output(fresh(), fresh_value())),
    bytearray.concat(#"00", bytearray.drop(ticket_signature, 1)),
  )
}

test create_refuses_less_than_the_minimum_funding() fail {
  let state = created(999_000_000)
  create(
    create_tx(state_output(state, state_value(999_000_000, full_deposit()))),
    ticket_signature,
  )
}

test create_refuses_a_short_deposit() fail {
  create(
    create_tx(state_output(fresh(), state_value(funded, full_deposit() - 1))),
    ticket_signature,
  )
}

test create_refuses_a_ticket_without_its_seed() fail {
  let tx = create_tx(state_output(fresh(), fresh_value()))
    |> spending([wallet_input(owner_key(), 20_000_000)])
  create(tx, ticket_signature)
}

test create_refuses_while_globally_paused() fail {
  let paused = RegistryDatum {
    ..registry_datum(),
    global_pauses: [
      GlobalSegment {
        start: created_at - hour,
        until: created_at + hour,
        kind: GuardianPause,
        guardian_before: 0,
        pauser_before: 0,
      },
    ],
  }
  create(
    create_tx(state_output(fresh(), fresh_value())) |> with_registry(paused),
    ticket_signature,
  )
}

test create_needs_the_owner() fail {
  create(
    create_tx(state_output(fresh(), fresh_value())) |> signed([]),
    ticket_signature,
  )
}

test delegate_never_mints_a_state_token() fail {
  campaign_policy.campaign_policy.mint(
    registry_policy,
    Delegate,
    escrow_policy,
    tx_at(created_at)
      |> minting(assets.from_asset(escrow_policy, state_token(key()), 1)),
  )
}

test delegate_needs_the_campaign_state_spent() fail {
  campaign_policy.campaign_policy.mint(
    registry_policy,
    Delegate,
    escrow_policy,
    tx_at(ends_at + 3 * day) |> minting(shard_mint(1)),
  )
}

// ## Funding

test top_up_before_the_end() {
  let at = starts_at + hour
  let next = EscrowState {
    ..advanced(fresh(), at),
    funded_total: funded + 500_000_000,
  }
  spend(
    fresh(),
    TopUp,
    transition(
      fresh(),
      fresh_value(),
      at,
      next,
      state_value(funded + 500_000_000, full_deposit()),
      [],
    ),
  )
}

test top_up_after_the_end_fails() fail {
  let at = ends_at - 60_000
  let next = EscrowState { ..advanced(fresh(), at), funded_total: funded + 1 }
  spend(
    fresh(),
    TopUp,
    transition(
      fresh(),
      fresh_value(),
      at,
      next,
      state_value(funded + 1, full_deposit()),
      [],
    ),
  )
}

test top_up_cannot_take_the_deposit() fail {
  let at = starts_at + hour
  let next = EscrowState { ..advanced(fresh(), at), funded_total: funded + 1 }
  spend(
    fresh(),
    TopUp,
    transition(
      fresh(),
      fresh_value(),
      at,
      next,
      state_value(funded + 1, full_deposit() - 1_000_000),
      [],
    ),
  )
}

fn refund_tx(at: Int, refund: Assets, signers: List<ByteArray>) -> Transaction {
  tx_at(at)
    |> spending([state_input(fresh(), fresh_value())])
    |> paying([tagged(owner().address, 0, refund)])
    |> signed(signers)
    |> minting(burn_state())
}

fn everything() -> Assets {
  assets.from_lovelace(full_deposit())
    |> assets.add(usdm_policy, "USDM", funded)
}

test owner_cancels_before_the_start() {
  spend(
    fresh(),
    Cancel,
    refund_tx(starts_at - 2 * hour, everything(), [owner_key()]),
  )
}

test owner_cannot_cancel_once_started() fail {
  spend(
    fresh(),
    Cancel,
    refund_tx(starts_at + hour, everything(), [owner_key()]),
  )
}

test guardian_cancels_any_time_before_finalize() {
  spend(
    committed(),
    Cancel,
    tx_at(ends_at + 3 * day)
      |> spending([state_input(committed(), fresh_value())])
      |> paying([tagged(owner().address, 0, everything())])
      |> signed([guardian(1), guardian(3)])
      |> minting(burn_state()),
  )
}

test guardian_cannot_cancel_after_finalize() fail {
  spend(
    finalized(),
    Cancel,
    tx_at(finalized_at + hour)
      |> spending([state_input(finalized(), fresh_value())])
      |> paying([tagged(owner().address, 0, everything())])
      |> signed([guardian(1), guardian(3)])
      |> minting(burn_state()),
  )
}

test cancel_pays_the_owner_everything() fail {
  spend(
    fresh(),
    Cancel,
    refund_tx(
      starts_at - 2 * hour,
      assets.from_lovelace(full_deposit())
        |> assets.add(usdm_policy, "USDM", funded - 1),
      [owner_key()],
    ),
  )
}

test cancel_refund_must_be_tagged() fail {
  spend(
    fresh(),
    Cancel,
    refund_tx(starts_at - 2 * hour, everything(), [owner_key()])
      |> paying([to_key(owner_key(), everything())]),
  )
}

test anyone_reclaims_an_expired_campaign() {
  // Never committed: expired at the commit deadline (ends + 14 days).
  spend(
    fresh(),
    ReclaimExpired,
    refund_tx(ends_at + 15 * day, everything(), []),
  )
}

test reclaim_before_expiry_fails() fail {
  spend(
    fresh(),
    ReclaimExpired,
    refund_tx(ends_at + 13 * day, everything(), []),
  )
}

// ## Commits

fn commit_tx(
  state: EscrowState,
  at: Int,
  _batch: List<Entry>,
  next: EscrowState,
) {
  transition(state, fresh_value(), at, next, fresh_value(), [operator()])
}

fn after_first_batch(at: Int) -> EscrowState {
  EscrowState {
    ..advanced(fresh(), at),
    entry_count: 10,
    total_points: 255,
    chain_head: link(batch_end(), ""),
    lowest_committed: earner(21),
  }
}

test operator_commits_the_last_batch_first() {
  let at = ends_at + hour
  spend(
    fresh(),
    Commit { version: 0, entries: batch_end() },
    commit_tx(fresh(), at, batch_end(), after_first_batch(at)),
  )
}

test then_commits_whole_shards_below_it() {
  let at = ends_at + hour
  let state = after_first_batch(at)
  let next = EscrowState {
    ..advanced(state, at + hour),
    entry_count: 30,
    total_points: 465,
    chain_head: head(),
    lowest_committed: earner(1),
  }
  spend(
    state,
    Commit { version: 0, entries: batch_start() },
    commit_tx(state, at + hour, batch_start(), next),
  )
}

test later_batches_must_be_whole_shards() fail {
  let at = ends_at + hour
  let state = after_first_batch(at)
  let batch = entries(1, 19)
  let next = EscrowState {
    ..advanced(state, at + hour),
    entry_count: 29,
    total_points: 445,
    chain_head: link(batch, state.chain_head),
    lowest_committed: earner(1),
  }
  spend(
    state,
    Commit { version: 0, entries: batch },
    commit_tx(state, at + hour, batch, next),
  )
}

test batches_must_stay_below_the_previous_one() fail {
  let at = ends_at + hour
  let state = after_first_batch(at)
  let batch = entries(11, 30)
  let next = EscrowState {
    ..advanced(state, at + hour),
    entry_count: 30,
    total_points: 255 + 410,
    chain_head: link(batch, state.chain_head),
    lowest_committed: earner(11),
  }
  spend(
    state,
    Commit { version: 0, entries: batch },
    commit_tx(state, at + hour, batch, next),
  )
}

test only_the_operator_commits() fail {
  let at = ends_at + hour
  spend(
    fresh(),
    Commit { version: 0, entries: batch_end() },
    commit_tx(fresh(), at, batch_end(), after_first_batch(at))
      |> signed([pauser()]),
  )
}

test commits_wait_for_the_campaign_end() fail {
  let at = ends_at - day
  spend(
    fresh(),
    Commit { version: 0, entries: batch_end() },
    commit_tx(fresh(), at, batch_end(), after_first_batch(at)),
  )
}

test commits_refuse_privileged_keys() fail {
  let at = ends_at + hour
  let batch = [Entry { key: operator(), points: 1 }]
  let next = EscrowState {
    ..advanced(fresh(), at),
    entry_count: 1,
    total_points: 1,
    chain_head: link(batch, ""),
    lowest_committed: operator(),
  }
  spend(
    fresh(),
    Commit { version: 0, entries: batch },
    commit_tx(fresh(), at, batch, next),
  )
}

test commits_refuse_the_owner() fail {
  let at = ends_at + hour
  let batch = [Entry { key: owner_key(), points: 1 }]
  let next = EscrowState {
    ..advanced(fresh(), at),
    entry_count: 1,
    total_points: 1,
    chain_head: link(batch, ""),
    lowest_committed: owner_key(),
  }
  spend(
    fresh(),
    Commit { version: 0, entries: batch },
    commit_tx(fresh(), at, batch, next),
  )
}

test commits_check_the_version() fail {
  let at = ends_at + hour
  spend(
    fresh(),
    Commit { version: 1, entries: batch_end() },
    commit_tx(fresh(), at, batch_end(), after_first_batch(at)),
  )
}

test commits_stay_within_max_recipients() fail {
  let at = ends_at + hour
  let state = EscrowState { ..after_first_batch(at), entry_count: 95 }
  let next = EscrowState {
    ..advanced(state, at + hour),
    entry_count: 115,
    total_points: 255 + 210,
    chain_head: head(),
    lowest_committed: earner(1),
  }
  spend(
    state,
    Commit { version: 0, entries: batch_start() },
    commit_tx(state, at + hour, batch_start(), next),
  )
}

test commits_after_the_deadline_fail() fail {
  let at = ends_at + 14 * day + hour
  spend(
    fresh(),
    Commit { version: 0, entries: batch_end() },
    commit_tx(fresh(), at, batch_end(), after_first_batch(at)),
  )
}

test operator_resets_the_commits() {
  let at = ends_at + 2 * hour
  let next = EscrowState {
    ..advanced(committed(), at),
    version: 1,
    entry_count: 0,
    total_points: 0,
    chain_head: "",
    lowest_committed: "",
  }
  spend(
    committed(),
    Reset { version: 0 },
    transition(
      committed(),
      fresh_value(),
      at,
      next,
      fresh_value(),
      [operator()],
    ),
  )
}

// ## Finalize and challenge

fn finalize_action(count: Int) -> EscrowAction {
  Finalize {
    version: 0,
    expected_count: count,
    expected_total_points: 465,
    allocation_hash: #"0000000000000000000000000000000000000000000000000000000000000001",
    allocation_uri: "https://api.dyma.example/allocations/1.csv",
  }
}

test operator_finalizes_and_opens_the_challenge_window() {
  let next = advanced(finalized(), finalized_at)
  spend(
    committed(),
    finalize_action(30),
    transition(
      committed(),
      fresh_value(),
      finalized_at,
      next,
      fresh_value(),
      [operator()],
    ),
  )
}

test finalize_checks_the_expected_counts() fail {
  let next = advanced(finalized(), finalized_at)
  spend(
    committed(),
    finalize_action(29),
    transition(
      committed(),
      fresh_value(),
      finalized_at,
      next,
      fresh_value(),
      [operator()],
    ),
  )
}

test finalize_cannot_change_the_fee_snapshot() fail {
  let honest = finalized()
  expect Some(f) = honest.finalized
  let next = EscrowState {
    ..advanced(honest, finalized_at),
    finalized: Some(Finalized { ..f, max_fee: 0, distributable: funded }),
  }
  spend(
    committed(),
    finalize_action(30),
    transition(
      committed(),
      fresh_value(),
      finalized_at,
      next,
      fresh_value(),
      [operator()],
    ),
  )
}

fn disputed_at(at: Int, reason: ByteArray) -> EscrowState {
  let state = finalized()
  expect Some(f) = state.finalized
  let expires_at = at + 600_000 - 1 + 3 * day
  EscrowState {
    ..advanced(state, at),
    finalized: Some(Finalized { ..f, claim_deadline: expires_at + 30 * day }),
    dispute: Some(
      Dispute { raised_at: at, reason, expires_at, resolved_at: None },
    ),
  }
}

test owner_disputes_during_the_challenge() {
  let at = finalized_at + 3 * hour
  let reason = "These wallets look farmed"
  spend(
    finalized(),
    RaiseDispute { reason },
    transition(
      finalized(),
      fresh_value(),
      at,
      disputed_at(at, reason),
      fresh_value(),
      [owner_key()],
    ),
  )
}

test disputes_close_with_the_challenge_window() fail {
  let at = challenge_ends_at + hour
  let reason = "Too late"
  spend(
    finalized(),
    RaiseDispute { reason },
    transition(
      finalized(),
      fresh_value(),
      at,
      disputed_at(at, reason),
      fresh_value(),
      [owner_key()],
    ),
  )
}

test only_one_dispute_per_version() fail {
  let at = finalized_at + 3 * hour
  let state = disputed_at(at, "First")
  spend(
    state,
    RaiseDispute { reason: "Second" },
    transition(
      state,
      fresh_value(),
      at + hour,
      disputed_at(at + hour, "Second"),
      fresh_value(),
      [owner_key()],
    ),
  )
}

fn rejected(state: EscrowState, at: Int, extensions: Int) -> EscrowState {
  // The commit deadline (ends + 14 days) is later than now + 3 days: unchanged.
  EscrowState {
    ..advanced(state, at),
    version: 1,
    entry_count: 0,
    total_points: 0,
    chain_head: "",
    lowest_committed: "",
    finalized: None,
    dispute: None,
    distribution: None,
    recommit_extensions: extensions,
  }
}

test guardian_rejects_during_the_challenge() {
  let at = finalized_at + hour
  spend(
    finalized(),
    Reject { reason: "Rogue allocation" },
    transition(
      finalized(),
      fresh_value(),
      at,
      rejected(finalized(), at, 0),
      fresh_value(),
      [guardian(2), guardian(3)],
    ),
  )
}

test rejection_moves_a_close_commit_deadline() {
  // Finalized late: 13 days after the end, the commit deadline is one day away.
  let late = ends_at + 13 * day
  let base = finalized()
  expect Some(f) = base.finalized
  let state = EscrowState {
    ..base,
    finalized: Some(
      Finalized { ..f, at: late, challenge_ends_at: late + 2 * day },
    ),
  }
  let at = late + hour
  let next = EscrowState {
    ..rejected(state, at, 1),
    commit_deadline: at + 600_000 - 1 + 3 * day,
  }
  spend(
    state,
    Reject { reason: "Rogue allocation" },
    transition(
      state,
      fresh_value(),
      at,
      next,
      fresh_value(),
      [guardian(1), guardian(2)],
    ),
  )
}

test one_guardian_cannot_reject() fail {
  let at = finalized_at + hour
  spend(
    finalized(),
    Reject { reason: "Rogue allocation" },
    transition(
      finalized(),
      fresh_value(),
      at,
      rejected(finalized(), at, 0),
      fresh_value(),
      [guardian(2)],
    ),
  )
}

test no_rejection_once_shards_exist() fail {
  let at = challenge_ends_at + 2 * hour
  spend(
    revealed(),
    Reject { reason: "Too late" },
    transition(
      revealed(),
      revealed_value(),
      at,
      rejected(revealed(), at, 0),
      revealed_value(),
      [guardian(1), guardian(2)],
    ),
  )
}

test guardian_keeps_a_disputed_allocation() {
  let raised = finalized_at + 3 * hour
  let state = disputed_at(raised, "Farmed")
  let at = raised + hour
  expect Some(f) = state.finalized
  expect Some(d) = state.dispute
  let next = EscrowState {
    ..advanced(state, at),
    // Distribution starts at the end of the challenge window (later than now).
    finalized: Some(
      Finalized { ..f, claim_deadline: f.challenge_ends_at + 30 * day },
    ),
    dispute: Some(Dispute { ..d, resolved_at: Some(at) }),
  }
  spend(
    state,
    Resolve { keep_allocation: True },
    transition(
      state,
      fresh_value(),
      at,
      next,
      fresh_value(),
      [guardian(1), guardian(3)],
    ),
  )
}

test guardian_rejects_a_disputed_allocation() {
  let raised = finalized_at + 3 * hour
  let state = disputed_at(raised, "Farmed")
  let at = raised + hour
  spend(
    state,
    Resolve { keep_allocation: False },
    transition(
      state,
      fresh_value(),
      at,
      rejected(state, at, 0),
      fresh_value(),
      [guardian(1), guardian(3)],
    ),
  )
}

// ## Reveal, claims and completion

fn reveal_tx(at: Int, shard_outputs: List<Output>) -> Transaction {
  tx_at(at)
    |> spending([state_input(finalized(), fresh_value())])
    |> paying(
        [
          state_output(advanced(revealed(), at), revealed_value()),
          ..shard_outputs
        ],
      )
    |> minting(shard_mint(1))
}

fn first_shard_output(lovelace: Int, amount: Int, shard: Shard) -> Output {
  Output {
    address: testkit.shard_address(),
    value: shard_value(lovelace, amount),
    datum: InlineDatum(ShardDatum(shard)),
    reference_script: None,
  }
}

const reveal_at: Int = challenge_ends_at + hour

test anyone_reveals_the_first_batch_into_a_shard() {
  let paid = first_payouts()
  spend(
    finalized(),
    Reveal { entries: batch_start(), next: link(batch_end(), "") },
    reveal_tx(
      reveal_at,
      [first_shard_output(5_000_000, paid.paid_total, first_shard())],
    ),
  )
}

test reveals_check_the_hash_chain() fail {
  let paid = first_payouts()
  spend(
    finalized(),
    Reveal { entries: batch_start(), next: link(entries(21, 29), "") },
    reveal_tx(
      reveal_at,
      [first_shard_output(5_000_000, paid.paid_total, first_shard())],
    ),
  )
}

test reveals_wait_for_the_challenge_window() fail {
  let paid = first_payouts()
  spend(
    finalized(),
    Reveal { entries: batch_start(), next: link(batch_end(), "") },
    reveal_tx(
      challenge_ends_at - hour,
      [first_shard_output(5_000_000, paid.paid_total, first_shard())],
    ),
  )
}

test shards_must_carry_the_exact_amounts() fail {
  let paid = first_payouts()
  let shard = first_shard()
  expect [first, ..rest] = shard.entries
  let tampered = Shard {
    ..shard,
    entries: [ShardEntry { ..first, amount: first.amount + 1 }, ..rest],
  }
  spend(
    finalized(),
    Reveal { entries: batch_start(), next: link(batch_end(), "") },
    reveal_tx(
      reveal_at,
      [first_shard_output(5_000_000, paid.paid_total + 1, tampered)],
    ),
  )
}

test shards_keep_their_deposit() fail {
  let paid = first_payouts()
  spend(
    finalized(),
    Reveal { entries: batch_start(), next: link(batch_end(), "") },
    reveal_tx(
      reveal_at,
      [first_shard_output(4_999_999, paid.paid_total, first_shard())],
    ),
  )
}

fn claim(
  shard: Shard,
  index: Int,
  tx: Transaction,
  shard_lovelace: Int,
  shard_amount: Int,
) -> Bool {
  let datum: Data = ShardDatum(shard)
  let shard_input = transaction.Input {
    output_reference: testkit.out_ref(#"5a", 0),
    output: first_shard_output(shard_lovelace, shard_amount, shard),
  }
  campaign_shard.campaign_shard.spend(
    registry_policy,
    escrow_policy,
    Some(datum),
    Claim { index },
    shard_input.output_reference,
    Transaction {
      ..tx,
      inputs: [shard_input, ..tx.inputs],
      reference_inputs: [
        state_input(revealed(), revealed_value()),
        ..tx.reference_inputs
      ],
    },
  )
}

fn claim_tx(at: Int, payee: ByteArray, amount: Int, rest: Shard, left: Int) {
  tx_at(at)
    |> paying(
        [
          to_key(
            payee,
            assets.from_lovelace(1_500_000)
              |> assets.add(usdm_policy, "USDM", amount),
          ),
          first_shard_output(5_000_000, left, rest),
        ],
      )
    |> signed([payee])
}

test earner_claims_its_entry() {
  let shard = first_shard()
  let paid = first_payouts()
  expect Some(entry) = list.at(shard.entries, 4)
  let rest = Shard { ..shard, entries: list.delete(shard.entries, entry) }
  claim(
    shard,
    4,
    claim_tx(
      reveal_at + day,
      entry.key,
      entry.amount,
      rest,
      paid.paid_total - entry.amount,
    ),
    5_000_000,
    paid.paid_total,
  )
}

test claims_need_the_earner_signature() fail {
  let shard = first_shard()
  let paid = first_payouts()
  expect Some(entry) = list.at(shard.entries, 4)
  let rest = Shard { ..shard, entries: list.delete(shard.entries, entry) }
  claim(
    shard,
    4,
    claim_tx(
      reveal_at + day,
      entry.key,
      entry.amount,
      rest,
      paid.paid_total - entry.amount,
    )
      |> signed([earner(99)]),
    5_000_000,
    paid.paid_total,
  )
}

test claims_pay_the_earner_its_whole_amount() fail {
  let shard = first_shard()
  let paid = first_payouts()
  expect Some(entry) = list.at(shard.entries, 4)
  let rest = Shard { ..shard, entries: list.delete(shard.entries, entry) }
  claim(
    shard,
    4,
    claim_tx(
      reveal_at + day,
      entry.key,
      entry.amount - 1,
      rest,
      paid.paid_total - entry.amount,
    ),
    5_000_000,
    paid.paid_total,
  )
}

test claims_close_at_the_deadline() fail {
  let shard = first_shard()
  let paid = first_payouts()
  expect Some(entry) = list.at(shard.entries, 4)
  let rest = Shard { ..shard, entries: list.delete(shard.entries, entry) }
  claim(
    shard,
    4,
    claim_tx(
      claim_deadline + hour,
      entry.key,
      entry.amount,
      rest,
      paid.paid_total - entry.amount,
    ),
    5_000_000,
    paid.paid_total,
  )
}

test claims_stop_while_paused() fail {
  let shard = first_shard()
  let paid = first_payouts()
  expect Some(entry) = list.at(shard.entries, 4)
  let rest = Shard { ..shard, entries: list.delete(shard.entries, entry) }
  let paused = RegistryDatum {
    ..registry_datum(),
    global_pauses: [
      GlobalSegment {
        start: reveal_at + day - hour,
        until: reveal_at + day + hour,
        kind: PauserPause,
        guardian_before: 0,
        pauser_before: 0,
      },
    ],
  }
  claim(
    shard,
    4,
    claim_tx(
      reveal_at + day,
      entry.key,
      entry.amount,
      rest,
      paid.paid_total - entry.amount,
    )
      |> with_registry(paused),
    5_000_000,
    paid.paid_total,
  )
}

test claims_cannot_rewrite_the_shard() fail {
  let shard = first_shard()
  let paid = first_payouts()
  expect Some(entry) = list.at(shard.entries, 4)
  // Drops another entry instead of the claimed one.
  expect Some(other) = list.at(shard.entries, 5)
  let rest = Shard { ..shard, entries: list.delete(shard.entries, other) }
  claim(
    shard,
    4,
    claim_tx(
      reveal_at + day,
      entry.key,
      entry.amount,
      rest,
      paid.paid_total - entry.amount,
    ),
    5_000_000,
    paid.paid_total,
  )
}

fn close_shards_tx(
  at: Int,
  shard: Shard,
  shard_value: Assets,
  next: EscrowState,
) {
  let shard_input = transaction.Input {
    output_reference: testkit.out_ref(#"5a", 0),
    output: Output {
      address: testkit.shard_address(),
      value: shard_value,
      datum: InlineDatum(ShardDatum(shard)),
      reference_script: None,
    },
  }
  let returned = assets.add(shard_value, escrow_policy, shard_token(key()), -1)
  tx_at(at)
    |> spending([state_input(revealed(), revealed_value()), shard_input])
    |> paying(
        [
          state_output(next, revealed_value()),
          tagged(owner().address, 0, returned),
        ],
      )
    |> minting(shard_mint(-1))
}

fn after_close(state: EscrowState, at: Int, count: Int, total: Int) {
  expect Some(d) = state.distribution
  EscrowState {
    ..advanced(state, at),
    distribution: Some(
      Distribution {
        ..d,
        shards_open: d.shards_open - 1,
        unclaimed_count: d.unclaimed_count + count,
        unclaimed_total: d.unclaimed_total + total,
      },
    ),
  }
}

test empty_shards_close_any_time() {
  let shard = Shard { ..first_shard(), entries: [] }
  let at = reveal_at + 2 * day
  spend(
    revealed(),
    CloseShards,
    close_shards_tx(
      at,
      shard,
      shard_value(5_000_000, 0),
      after_close(revealed(), at, 0, 0),
    ),
  )
}

test full_shards_wait_for_the_claim_deadline() fail {
  let shard = first_shard()
  let paid = first_payouts()
  let at = reveal_at + 2 * day
  spend(
    revealed(),
    CloseShards,
    close_shards_tx(
      at,
      shard,
      shard_value(5_000_000, paid.paid_total),
      after_close(revealed(), at, 20, paid.paid_total),
    ),
  )
}

test unclaimed_entries_return_after_the_deadline() {
  let shard = first_shard()
  let paid = first_payouts()
  let at = claim_deadline + hour
  spend(
    revealed(),
    CloseShards,
    close_shards_tx(
      at,
      shard,
      shard_value(5_000_000, paid.paid_total),
      after_close(revealed(), at, 20, paid.paid_total),
    ),
  )
}

test shard_close_follows_the_state() {
  let shard = Shard { ..first_shard(), entries: [] }
  let at = reveal_at + 2 * day
  let redeemer: Data = CloseShards
  let base = close_shards_tx(
    at,
    shard,
    shard_value(5_000_000, 0),
    after_close(revealed(), at, 0, 0),
  )
  let tx = Transaction {
    ..base,
    redeemers: [Pair(transaction.Spend(state_ref()), redeemer)],
  }
  let datum: Data = ShardDatum(shard)
  campaign_shard.campaign_shard.spend(
    registry_policy,
    escrow_policy,
    Some(datum),
    ShardClose,
    testkit.out_ref(#"5a", 0),
    tx,
  )
}

test shard_close_needs_the_state_closing_shards() fail {
  let shard = Shard { ..first_shard(), entries: [] }
  let at = reveal_at + 2 * day
  let redeemer: Data = TopUp
  let base = close_shards_tx(
    at,
    shard,
    shard_value(5_000_000, 0),
    after_close(revealed(), at, 0, 0),
  )
  let tx = Transaction {
    ..base,
    redeemers: [Pair(transaction.Spend(state_ref()), redeemer)],
  }
  let datum: Data = ShardDatum(shard)
  campaign_shard.campaign_shard.spend(
    registry_policy,
    escrow_policy,
    Some(datum),
    ShardClose,
    testkit.out_ref(#"5a", 0),
    tx,
  )
}

/// Everything revealed and every shard closed: 15 of the 30 entries claimed.
fn settled() -> (EscrowState, Assets, Int) {
  let state = revealed()
  expect Some(d) = state.distribution
  let claimed = 5_000_000_000
  let next = EscrowState {
    ..state,
    distribution: Some(
      Distribution {
        ..d,
        head: "",
        revealed: 30,
        shards_created: 2,
        shards_open: 0,
        allocated: 9_899_999_990,
        allocated_count: 30,
        unclaimed_count: 15,
        unclaimed_total: 9_899_999_990 - claimed,
      },
    ),
  }
  // The pool keeps the dust and the fee reserve; one shard's deposit is gone with it.
  (
    next,
    state_value(funded - 9_899_999_990, full_deposit() - 10_000_000),
    claimed,
  )
}

test complete_pays_the_fee_on_claims_and_the_rest_to_the_owner() {
  let (state, value, claimed) = settled()
  let pool = funded - 9_899_999_990
  let fee = claimed / 100
  spend(
    state,
    Complete,
    tx_at(reveal_at + 5 * day)
      |> spending([state_input(state, value)])
      |> paying(
          [
            tagged(
              treasury(),
              1,
              assets.from_lovelace(1_500_000)
                |> assets.add(usdm_policy, "USDM", fee),
            ),
            tagged(
              owner().address,
              0,
              assets.from_lovelace(deposit_left(state) - 1_500_000)
                |> assets.add(usdm_policy, "USDM", pool - fee),
            ),
          ],
        )
      |> minting(burn_state()),
  )
}

test complete_cannot_overpay_the_treasury() fail {
  let (state, value, claimed) = settled()
  let pool = funded - 9_899_999_990
  let fee = claimed / 100
  spend(
    state,
    Complete,
    tx_at(reveal_at + 5 * day)
      |> spending([state_input(state, value)])
      |> paying(
          [
            tagged(
              treasury(),
              1,
              assets.from_lovelace(1_500_000)
                |> assets.add(usdm_policy, "USDM", fee + 1),
            ),
            tagged(
              owner().address,
              0,
              assets.from_lovelace(deposit_left(state) - 1_500_000)
                |> assets.add(usdm_policy, "USDM", pool - fee - 1),
            ),
          ],
        )
      |> minting(burn_state()),
  )
}

test complete_waits_for_open_shards() fail {
  let state = revealed()
  spend(
    state,
    Complete,
    tx_at(claim_deadline + hour)
      |> spending([state_input(state, revealed_value())])
      |> paying([tagged(owner().address, 0, revealed_value())])
      |> minting(burn_state()),
  )
}

test an_empty_allocation_completes_without_fee() {
  let base = finalized()
  expect Some(f) = base.finalized
  let state = EscrowState {
    ..base,
    entry_count: 0,
    total_points: 0,
    chain_head: "",
    lowest_committed: "",
    finalized: Some(Finalized { ..f, max_fee: 0, distributable: funded }),
  }
  spend(
    state,
    Complete,
    tx_at(reveal_at)
      |> spending([state_input(state, fresh_value())])
      |> paying([tagged(owner().address, 0, everything())])
      |> minting(burn_state()),
  )
}

// ## Pauses, ownership, sync, rescue

fn pause_tx(
  state: EscrowState,
  at: Int,
  local: LocalPause,
  signers: List<ByteArray>,
) {
  let next = EscrowState {
    ..state,
    clock: ClockLedger { ..ledger_at(state, at, []), local: Some(local) },
  }
  transition(state, revealed_value(), at, next, revealed_value(), signers)
}

test pauser_pauses_for_at_most_a_day() {
  let at = reveal_at + day
  let until = at + 12 * hour
  spend(
    revealed(),
    Pause { until },
    pause_tx(
      revealed(),
      at,
      LocalPause { start: at, until, kind: PauserPause },
      [pauser()],
    ),
  )
}

test pauses_cannot_exceed_max_pause() fail {
  let at = reveal_at + day
  let until = at + day + 1
  spend(
    revealed(),
    Pause { until },
    pause_tx(
      revealed(),
      at,
      LocalPause { start: at, until, kind: PauserPause },
      [pauser()],
    ),
  )
}

test the_pauser_waits_after_a_pause() fail {
  let at = reveal_at + day
  let base = revealed()
  let state = EscrowState {
    ..base,
    clock: ClockLedger {
      ..base.clock,
      local: Some(
        LocalPause { start: at - 2 * hour, until: at - hour, kind: PauserPause },
      ),
    },
  }
  let until = at + hour
  spend(
    state,
    Pause { until },
    pause_tx(
      state,
      at,
      LocalPause { start: at, until, kind: PauserPause },
      [pauser()],
    ),
  )
}

test the_guardian_extends_a_pause() {
  let at = reveal_at + day
  let base = revealed()
  let state = EscrowState {
    ..base,
    clock: ClockLedger {
      ..base.clock,
      local: Some(
        LocalPause {
          start: at - hour,
          until: at + 20 * hour,
          kind: PauserPause,
        },
      ),
    },
  }
  let until = at + 10 * hour
  // Never shortens: the active pause runs until at + 20 h.
  spend(
    state,
    Pause { until },
    pause_tx(
      state,
      at,
      LocalPause { start: at, until: at + 20 * hour, kind: GuardianPause },
      [guardian(1), guardian(2)],
    ),
  )
}

test the_guardian_lifts_a_pause() {
  let at = reveal_at + day
  let base = revealed()
  let local = LocalPause {
    start: at - hour,
    until: at + 20 * hour,
    kind: PauserPause,
  }
  let state = EscrowState {
    ..base,
    clock: ClockLedger { ..base.clock, local: Some(local) },
  }
  let next = EscrowState {
    ..state,
    clock: ClockLedger {
      ..ledger_at(state, at, []),
      local: Some(LocalPause { ..local, until: at }),
    },
  }
  spend(
    state,
    Unpause,
    transition(
      state,
      revealed_value(),
      at,
      next,
      revealed_value(),
      [guardian(1), guardian(3)],
    ),
  )
}

test owner_transfers_ownership_before_the_start() {
  let at = starts_at - 2 * hour
  let new_owner = testkit.script_owner(
    #"99999999999999999999999999999999999999999999999999999999",
  )
  let next = EscrowState {
    ..advanced(fresh(), at),
    pending_owner: Some(PendingOwner { owner: new_owner, expiry: None }),
  }
  spend(
    fresh(),
    TransferOwnership { new_owner, expiry: None },
    transition(fresh(), fresh_value(), at, next, fresh_value(), [owner_key()]),
  )
}

test the_new_owner_accepts_with_its_script() {
  let at = starts_at - 2 * hour
  let script = #"99999999999999999999999999999999999999999999999999999999"
  let new_owner = testkit.script_owner(script)
  let state = EscrowState {
    ..fresh(),
    pending_owner: Some(PendingOwner { owner: new_owner, expiry: None }),
  }
  let next = EscrowState {
    ..advanced(state, at),
    owner: new_owner,
    pending_owner: None,
  }
  let base = transition(state, fresh_value(), at, next, fresh_value(), [])
  let script_input = transaction.Input {
    output_reference: testkit.out_ref(#"0c", 0),
    output: Output {
      address: address.from_script(script),
      value: assets.from_lovelace(2_000_000),
      datum: transaction.NoDatum,
      reference_script: None,
    },
  }
  let tx = Transaction { ..base, inputs: [script_input, ..base.inputs] }
  spend(state, AcceptOwnership, tx)
}

test ownership_freezes_at_the_start() fail {
  let at = starts_at + hour
  let new_owner = testkit.script_owner(
    #"99999999999999999999999999999999999999999999999999999999",
  )
  let next = EscrowState {
    ..advanced(fresh(), at),
    pending_owner: Some(PendingOwner { owner: new_owner, expiry: None }),
  }
  spend(
    fresh(),
    TransferOwnership { new_owner, expiry: None },
    transition(fresh(), fresh_value(), at, next, fresh_value(), [owner_key()]),
  )
}

test owner_cancels_a_transfer() {
  let state = EscrowState {
    ..fresh(),
    pending_owner: Some(PendingOwner { owner: owner(), expiry: None }),
  }
  spend(
    state,
    CancelOwnershipTransfer,
    transition(
      state,
      fresh_value(),
      starts_at + day,
      EscrowState { ..state, pending_owner: None },
      fresh_value(),
      [owner_key()],
    ),
  )
}

test operator_syncs_the_clock() {
  let at = reveal_at + 2 * day
  spend(
    revealed(),
    Sync,
    transition(
      revealed(),
      revealed_value(),
      at,
      advanced(revealed(), at),
      revealed_value(),
      [operator()],
    ),
  )
}

test governance_rescues_a_stray_utxo() {
  let stray = transaction.Input {
    output_reference: testkit.out_ref(#"de", 1),
    output: Output {
      address: escrow_address(),
      value: assets.from_lovelace(7_000_000),
      datum: transaction.NoDatum,
      reference_script: None,
    },
  }
  campaign_state.campaign_state.spend(
    registry_policy,
    escrow_policy,
    shard_script,
    payout_script,
    admin_script,
    None,
    Rescue,
    stray.output_reference,
    tx_at(starts_at)
      |> spending([stray])
      |> signed([testkit.governor(1), testkit.governor(2)]),
  )
}

test nobody_else_rescues() fail {
  let stray = transaction.Input {
    output_reference: testkit.out_ref(#"de", 1),
    output: Output {
      address: escrow_address(),
      value: assets.from_lovelace(7_000_000),
      datum: transaction.NoDatum,
      reference_script: None,
    },
  }
  campaign_state.campaign_state.spend(
    registry_policy,
    escrow_policy,
    shard_script,
    payout_script,
    admin_script,
    None,
    Rescue,
    stray.output_reference,
    tx_at(starts_at) |> spending([stray]) |> signed([testkit.governor(1)]),
  )
}

test state_cannot_be_rescued() fail {
  spend(
    fresh(),
    Rescue,
    tx_at(starts_at)
      |> spending([state_input(fresh(), fresh_value())])
      |> signed([testkit.governor(1), testkit.governor(2)]),
  )
}

test no_free_minting_on_a_transition() fail {
  let at = reveal_at + 2 * day
  spend(
    revealed(),
    Sync,
    transition(
      revealed(),
      revealed_value(),
      at,
      advanced(revealed(), at),
      revealed_value(),
      [operator()],
    )
      |> minting(shard_mint(1)),
  )
}
