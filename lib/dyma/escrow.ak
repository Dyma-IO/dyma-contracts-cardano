//// The campaign escrow's transitions, shared by its three scripts (each fits in a transaction):
////
//// - `campaign_policy` mints and burns the campaign tokens and creates campaigns from tickets;
//// - `campaign_state` holds each campaign's state UTxO (the state token "S" ++ key, the pool and
////   the owner's ADA deposit) and runs every state transition;
//// - `campaign_shard` holds the claim shards (a shard token "L" ++ key, up to 20 payable entries
////   and their deposit) and runs claims.
////
//// The same rules as the CosmWasm `dyma-campaign-escrow` 0.2.0 (claim mode): see docs/SPEC.md
//// and docs/ESCROW_RULES.md.

use aiken/collection/dict
use aiken/collection/list
use aiken/collection/pairs
use aiken/crypto.{ScriptHash, VerificationKeyHash}
use aiken/primitive/bytearray
use cardano/address.{Address, Script, VerificationKey}
use cardano/assets.{AssetName, Assets, PolicyId}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Spend, Transaction,
}
use dyma/allocation.{check_batch, link, payouts}
use dyma/auth.{
  credential_authorised, multisig_signed, owner_authorised, signed_by,
  valid_key_hash,
}
use dyma/clock.{Reading, after, reached, read}
use dyma/constants.{
  hard_max_frozen_secs, max_pause_tx_window_ms, max_recommit_extensions,
  max_treasury_output_lovelace, max_tx_window_ms, ms_per_sec,
  pauser_budget_pauses, shard_size, state_token_prefix,
}
use dyma/holdings.{
  holds_exactly, is_ada, pool_of, pool_tokens, quantity, shard_token,
  state_token, state_value_ok,
}
use dyma/math.{fee_charged, finalize_snapshot}
use dyma/phase.{derive}
use dyma/registry_rules.{find_registry, privileged_keys}
use dyma/text.{valid_reason, valid_uri}
use dyma/time.{bounds}
use dyma/types.{
  AcceptOwnership, Active, Cancel, CancelOwnershipTransfer, Challenge, Claim,
  CloseShards, Commit, Committing, Complete, Disputed, Distributing,
  Distribution, Ended, Entry, EscrowAction, EscrowDatum, EscrowState, Expired,
  Finalize, Finalized, GuardianPause, LocalPause, Pause, PauserPause, PayoutTag,
  PendingOwner, Phase, RaiseDispute, ReclaimExpired, RegistryDatum, Reject,
  Reset, Resolve, Reveal, Shard, ShardClose, ShardDatum, ShardEntry, StateDatum,
  Sync, TopUp, TransferOwnership, Unpause, Upcoming,
}

/// Payout tags: the role of a payment the escrow requires.
const owner_role: Int = 0

const treasury_role: Int = 1

// ## State transitions

/// One state UTxO being spent.
pub type Ctx {
  tx: Transaction,
  own_ref: OutputReference,
  /// The state UTxO.
  own: Output,
  /// Policy of the campaign tokens (`campaign_policy`).
  policy: PolicyId,
  /// Where claim shards live (`campaign_shard`).
  shard_script: ScriptHash,
  config: RegistryDatum,
  state: EscrowState,
}

pub fn state_transition(ctx: Ctx, action: EscrowAction) -> Bool {
  let state = ctx.state
  let campaign = state.campaign
  when action is {
    TopUp -> {
      let (_lower, _upper, lo, hi) = clock_over(ctx, max_tx_window_ms)
      expect steady(state, lo, hi, [Upcoming, Active])
      expect not_paused(lo, hi)
      let output = continuing(ctx)
      let before = pool_of(state, ctx.own.value)
      let after_top_up = pool_of(state, output.value)
      let added = after_top_up - before
      and {
        added > 0,
        state_value_ok(output.value, ctx.policy, state, after_top_up),
        carries(
          output,
          EscrowState {
            ..state,
            funded_total: state.funded_total + added,
            clock: lo.ledger,
          },
        ),
        mints(ctx, 0, 0),
      }
    }

    Cancel -> {
      expect state.finalized == None
      let by_guardian = multisig_signed(ctx.tx, ctx.config.guardian)
      let by_owner = if by_guardian {
        False
      } else {
        expect Some((_lower, upper)) = bounds(
          ctx.tx.validity_range,
          max_tx_window_ms,
        )
        owner_authorised(ctx.tx, state.owner) && upper < campaign.starts_at
      }
      ( by_guardian || by_owner ) && refund_everything(ctx)
    }

    ReclaimExpired -> {
      let (_lower, _upper, lo, _hi) = clock_over(ctx, max_tx_window_ms)
      // Expired at the range's start, hence over the whole range (the clock never goes back).
      derive(state, lo.now, lo.clock) == Expired && refund_everything(ctx)
    }

    Commit { version, entries } -> {
      let (_lower, _upper, lo, hi) = clock_over(ctx, max_tx_window_ms)
      expect signed_by(ctx.tx, ctx.config.operator)
      expect steady(state, lo, hi, [Ended, Committing])
      expect not_paused(lo, hi)
      expect version == state.version
      let count = list.length(entries)
      expect count >= 1 && count <= campaign.limits.max_commit_batch
      // Batches are whole claim shards, except the first committed (the allocation's end).
      expect state.lowest_committed == "" || count % shard_size == 0
      expect state.entry_count + count <= campaign.max_recipients
      let forbidden = list.concat(
        owner_keys(state),
        privileged_keys(ctx.config),
      )
      expect Some(batch) = check_batch(entries, forbidden)
      // Committed from the end of the sorted allocation: every key below the previous batch.
      expect
        state.lowest_committed == "" || bytearray.compare(
          batch.last,
          state.lowest_committed,
        ) == Less
      let output = continuing(ctx)
      and {
        output.value == ctx.own.value,
        carries(
          output,
          EscrowState {
            ..state,
            entry_count: state.entry_count + count,
            total_points: state.total_points + batch.points,
            chain_head: link(entries, state.chain_head),
            lowest_committed: batch.first,
            clock: lo.ledger,
          },
        ),
        mints(ctx, 0, 0),
      }
    }

    Reset { version } -> {
      let (_lower, _upper, lo, hi) = clock_over(ctx, max_tx_window_ms)
      expect signed_by(ctx.tx, ctx.config.operator)
      expect steady(state, lo, hi, [Ended, Committing])
      expect not_paused(lo, hi)
      expect version == state.version
      let output = continuing(ctx)
      and {
        output.value == ctx.own.value,
        carries(
          output,
          EscrowState {
            ..state,
            version: state.version + 1,
            entry_count: 0,
            total_points: 0,
            chain_head: "",
            lowest_committed: "",
            clock: lo.ledger,
          },
        ),
        mints(ctx, 0, 0),
      }
    }

    Finalize {
      version,
      expected_count,
      expected_total_points,
      allocation_hash,
      allocation_uri,
    } -> {
      let (lower, _upper, lo, hi) = clock_over(ctx, max_tx_window_ms)
      expect signed_by(ctx.tx, ctx.config.operator)
      expect steady(state, lo, hi, [Ended, Committing])
      expect not_paused(lo, hi)
      expect version == state.version
      expect expected_count == state.entry_count
      expect expected_total_points == state.total_points
      expect bytearray.length(allocation_hash) == 32
      expect valid_uri(allocation_uri)
      // No fee reserve on an empty allocation (nothing is distributed).
      let fee_bps = if state.entry_count == 0 {
        0
      } else {
        campaign.fee_bps
      }
      let snapshot = finalize_snapshot(
        pool_of(state, ctx.own.value),
        fee_bps,
        campaign.max_share_bps,
      )
      let challenge_ends_at = after(hi, campaign.challenge_secs)
      let output = continuing(ctx)
      and {
        output.value == ctx.own.value,
        carries(
          output,
          EscrowState {
            ..state,
            finalized: Some(
              Finalized {
                at: lower,
                challenge_ends_at,
                claim_deadline: challenge_ends_at + campaign.claim_window_secs * ms_per_sec,
                gross: snapshot.gross,
                max_fee: snapshot.fee,
                distributable: snapshot.distributable,
                cap: snapshot.cap,
                treasury: ctx.config.treasury,
                allocation_hash,
                allocation_uri,
              },
            ),
            clock: lo.ledger,
          },
        ),
        mints(ctx, 0, 0),
      }
    }

    RaiseDispute { reason } -> {
      let (lower, _upper, lo, hi) = clock_over(ctx, max_tx_window_ms)
      expect owner_authorised(ctx.tx, state.owner)
      // Once per version: an open, upheld or lapsed dispute all count. Never blocked by a pause.
      expect state.dispute == None
      expect steady(state, lo, hi, [Challenge])
      expect valid_reason(reason)
      expect Some(finalized) = state.finalized
      let expires_at = after(hi, campaign.limits.dispute_timeout_secs)
      let opens_at = max(finalized.challenge_ends_at, expires_at)
      let output = continuing(ctx)
      and {
        output.value == ctx.own.value,
        carries(
          output,
          EscrowState {
            ..state,
            finalized: Some(
              Finalized {
                ..finalized,
                claim_deadline: opens_at + campaign.claim_window_secs * ms_per_sec,
              },
            ),
            dispute: Some(
              types.Dispute {
                raised_at: lower,
                reason,
                expires_at,
                resolved_at: None,
              },
            ),
            clock: lo.ledger,
          },
        ),
        mints(ctx, 0, 0),
      }
    }

    Reject { reason } -> {
      let (_lower, _upper, lo, hi) = clock_over(ctx, max_tx_window_ms)
      expect multisig_signed(ctx.tx, ctx.config.guardian)
      // During the challenge window or an open dispute, never once claim shards exist.
      expect steady(state, lo, hi, [Challenge, Disputed])
      expect valid_reason(reason)
      let output = continuing(ctx)
      and {
        output.value == ctx.own.value,
        carries(
          output,
          EscrowState { ..reject_allocation(state, hi.clock), clock: lo.ledger },
        ),
        mints(ctx, 0, 0),
      }
    }

    Resolve { keep_allocation } -> {
      let (lower, _upper, lo, hi) = clock_over(ctx, max_tx_window_ms)
      expect multisig_signed(ctx.tx, ctx.config.guardian)
      expect steady(state, lo, hi, [Disputed])
      let output = continuing(ctx)
      let expected = if keep_allocation {
        expect Some(finalized) = state.finalized
        expect Some(dispute) = state.dispute
        // Distribution starts at the later of the window's end and now (escrow clock).
        let opens_at = max(finalized.challenge_ends_at, hi.clock)
        EscrowState {
          ..state,
          finalized: Some(
            Finalized {
              ..finalized,
              claim_deadline: opens_at + campaign.claim_window_secs * ms_per_sec,
            },
          ),
          dispute: Some(types.Dispute { ..dispute, resolved_at: Some(lower) }),
          clock: lo.ledger,
        }
      } else {
        EscrowState { ..reject_allocation(state, hi.clock), clock: lo.ledger }
      }
      and {
        output.value == ctx.own.value,
        carries(output, expected),
        mints(ctx, 0, 0),
      }
    }

    _ -> False
  }
}

/// Payouts: `campaign_state` forwards them to `campaign_payout` (a zero-ADA withdrawal).
pub fn is_payout(action: EscrowAction) -> Bool {
  when action is {
    Reveal { .. } | CloseShards | Complete -> True
    _ -> False
  }
}

/// Pauses, ownership and clock checkpoints: forwarded to `campaign_admin`.
pub fn is_admin(action: EscrowAction) -> Bool {
  when action is {
    Pause { .. } |
    Unpause |
    TransferOwnership { .. } |
    AcceptOwnership |
    CancelOwnershipTransfer |
    Sync -> True
    _ -> False
  }
}

/// Reveals, shard closes and completion (validated by `campaign_payout`).
pub fn payout_transition(ctx: Ctx, action: EscrowAction) -> Bool {
  when action is {
    Reveal { entries, next: next_head } -> reveal(ctx, entries, next_head)

    CloseShards -> close_shards(ctx)

    Complete -> complete(ctx)
    _ -> False
  }
}

/// Pauses, ownership and clock checkpoints (validated by `campaign_admin`).
pub fn admin_transition(ctx: Ctx, action: EscrowAction) -> Bool {
  let state = ctx.state
  let campaign = state.campaign
  when action is {
    Pause { until } -> pause(ctx, until)

    Unpause -> {
      let (lower, upper) = expect_bounds(ctx, max_pause_tx_window_ms)
      expect multisig_signed(ctx.tx, ctx.config.guardian)
      expect Some(local) = state.clock.local
      // Active over the whole range: it ends at the range's start.
      expect upper < local.until
      let lo = read_at(ctx, lower)
      expect lo.global_known
      let output = continuing(ctx)
      and {
        output.value == ctx.own.value,
        carries(
          output,
          EscrowState {
            ..state,
            clock: types.ClockLedger {
              ..lo.ledger,
              local: Some(LocalPause { ..local, until: lower }),
            },
          },
        ),
        mints(ctx, 0, 0),
      }
    }

    TransferOwnership { new_owner, expiry } -> {
      let (_lower, upper, lo, _hi) = clock_over(ctx, max_tx_window_ms)
      expect owner_authorised(ctx.tx, state.owner)
      // Ownership is frozen once the campaign starts.
      expect upper < campaign.starts_at
      expect
        when expiry is {
          Some(expiry) -> expiry > upper
          None -> True
        }
      expect
        when new_owner.credential is {
          VerificationKey(hash) -> valid_key_hash(hash)
          Script(hash) -> valid_key_hash(hash)
        }
      let output = continuing(ctx)
      and {
        output.value == ctx.own.value,
        carries(
          output,
          EscrowState {
            ..state,
            pending_owner: Some(PendingOwner { owner: new_owner, expiry }),
            clock: lo.ledger,
          },
        ),
        mints(ctx, 0, 0),
      }
    }

    AcceptOwnership -> {
      let (_lower, upper, lo, _hi) = clock_over(ctx, max_tx_window_ms)
      expect Some(pending) = state.pending_owner
      expect credential_authorised(ctx.tx, pending.owner.credential)
      expect upper < campaign.starts_at
      expect
        when pending.expiry is {
          Some(expiry) -> upper < expiry
          None -> True
        }
      let output = continuing(ctx)
      and {
        output.value == ctx.own.value,
        carries(
          output,
          EscrowState {
            ..state,
            owner: pending.owner,
            pending_owner: None,
            clock: lo.ledger,
          },
        ),
        mints(ctx, 0, 0),
      }
    }

    CancelOwnershipTransfer -> {
      expect owner_authorised(ctx.tx, state.owner)
      expect Some(_) = state.pending_owner
      let output = continuing(ctx)
      and {
        output.value == ctx.own.value,
        carries(output, EscrowState { ..state, pending_owner: None }),
        mints(ctx, 0, 0),
      }
    }

    // The operator checkpoints the clock (e.g. after global pauses, before the registry's
    // history forgets them).
    Sync -> {
      let (_lower, _upper, lo, _hi) = clock_over(ctx, max_tx_window_ms)
      expect signed_by(ctx.tx, ctx.config.operator)
      let output = continuing(ctx)
      and {
        output.value == ctx.own.value,
        carries(output, EscrowState { ..state, clock: lo.ledger }),
        mints(ctx, 0, 0),
      }
    }
    _ -> False
  }
}

/// The forwarding script's check: every campaign state the transaction spends with one of its
/// transitions is validated (at least one), each with its own context.
pub fn forwarded(
  tx: Transaction,
  registry_policy: PolicyId,
  token_policy: PolicyId,
  shard_script: ScriptHash,
  handles: fn(EscrowAction) -> Bool,
  validate: fn(Ctx, EscrowAction) -> Bool,
) -> Bool {
  let config = find_registry(tx, registry_policy)
  let validated = list.foldl(
    tx.inputs,
    0,
    fn(input, count) {
      when dict.to_pairs(assets.tokens(input.output.value, token_policy)) is {
        [Pair(name, 1)] ->
          if bytearray.take(name, 1) == state_token_prefix {
            expect Some(redeemer) = pairs.get_first(
              tx.redeemers,
              Spend(input.output_reference),
            )
            expect action: EscrowAction = redeemer
            if handles(action) {
              expect InlineDatum(raw) = input.output.datum
              expect parsed: EscrowDatum = raw
              expect StateDatum(state) = parsed
              expect state.campaign.key == bytearray.drop(name, 1)
              expect
                validate(
                  Ctx {
                    tx,
                    own_ref: input.output_reference,
                    own: input.output,
                    policy: token_policy,
                    shard_script,
                    config,
                    state,
                  },
                  action,
                )
              count + 1
            } else {
              count
            }
          } else {
            count
          }
        _ -> count
      }
    },
  )
  validated >= 1
}

/// Discards the finalized (or committed) allocation: version + 1, counters reset, and the commit
/// deadline moved to at least `clock + min_recommit_secs`, at most twice per escrow.
fn reject_allocation(state: EscrowState, clock: Int) -> EscrowState {
  let min_deadline = clock + state.campaign.limits.min_recommit_secs * ms_per_sec
  let (commit_deadline, recommit_extensions) = if state.commit_deadline < min_deadline && state.recommit_extensions < max_recommit_extensions {
    (min_deadline, state.recommit_extensions + 1)
  } else {
    (state.commit_deadline, state.recommit_extensions)
  }
  EscrowState {
    ..state,
    version: state.version + 1,
    entry_count: 0,
    total_points: 0,
    chain_head: "",
    lowest_committed: "",
    finalized: None,
    dispute: None,
    distribution: None,
    commit_deadline,
    recommit_extensions,
  }
}

/// Reveals the next committed batch (anyone, after the challenge window, before the claim
/// deadline): checks it against the hash chain and turns its payable entries into claim shards.
fn reveal(ctx: Ctx, entries: List<Entry>, next_head: ByteArray) -> Bool {
  let state = ctx.state
  let campaign = state.campaign
  let (_lower, _upper, lo, hi) = clock_over(ctx, max_tx_window_ms)
  expect steady(state, lo, hi, [Distributing])
  expect not_paused(lo, hi)
  expect Some(finalized) = state.finalized
  expect hi.clock < finalized.claim_deadline
  let progress = when state.distribution is {
    Some(d) -> d
    None ->
      Distribution {
        head: state.chain_head,
        revealed: 0,
        shards_created: 0,
        shards_open: 0,
        allocated: 0,
        allocated_count: 0,
        skipped_count: 0,
        skipped_total: 0,
        unclaimed_count: 0,
        unclaimed_total: 0,
      }
  }
  expect progress.head != ""
  expect link(entries, next_head) == progress.head
  let paid = payouts(
    entries,
    finalized.distributable,
    state.total_points,
    finalized.cap,
    campaign.min_payout,
  )
  let created = list.length(paid.shards)
  let expected = EscrowState {
    ..state,
    distribution: Some(
      Distribution {
        ..progress,
        head: next_head,
        revealed: progress.revealed + list.length(entries),
        shards_created: progress.shards_created + created,
        shards_open: progress.shards_open + created,
        allocated: progress.allocated + paid.paid_total,
        allocated_count: progress.allocated_count + paid.paid_count,
        skipped_count: progress.skipped_count + paid.skipped_count,
        skipped_total: progress.skipped_total + paid.skipped_total,
      },
    ),
    clock: lo.ledger,
  }
  let output = continuing(ctx)
  let shard_outputs = holding(
    ctx.tx.outputs,
    ctx.policy,
    shard_token(campaign.key),
  )
  and {
    carries(output, expected),
    state_value_ok(
      output.value,
      ctx.policy,
      expected,
      pool_of(state, ctx.own.value) - paid.paid_total,
    ),
    list.length(shard_outputs) == created,
    shards_match(shard_outputs, paid.shards, progress.shards_created, ctx),
    mints(ctx, 0, created),
  }
}

fn shards_match(
  outputs: List<Output>,
  shards: List<List<ShardEntry>>,
  index: Int,
  ctx: Ctx,
) -> Bool {
  when (outputs, shards) is {
    ([], []) -> True
    ([output, ..outputs], [entries, ..shards]) -> {
      let campaign = ctx.state.campaign
      let total = list.foldl(entries, 0, fn(e, acc) { acc + e.amount })
      let lovelace = assets.lovelace_of(output.value)
      let token = shard_token(campaign.key)
      and {
        output.address == shard_address(ctx),
        output.datum == InlineDatum(
          ShardDatum(Shard { campaign: campaign.key, index, entries }),
        ),
        // The deposit, plus whatever ADA the revealer adds if Cardano now asks for more.
        if is_ada(campaign.asset) {
          and {
            lovelace >= campaign.shard_deposit + total,
            holds_exactly(output.value, lovelace, [(ctx.policy, token, 1)]),
          }
        } else {
          and {
            lovelace >= campaign.shard_deposit,
            holds_exactly(
              output.value,
              lovelace,
              [(ctx.policy, token, 1), ..pool_tokens(campaign.asset, total)],
            ),
          }
        },
        shards_match(outputs, shards, index + 1, ctx),
      }
    }
    _ -> False
  }
}

/// Closes claim shards (anyone): empty ones at any time, the others once the claim deadline is
/// reached. What they still hold (unclaimed entries, deposits) goes to the owner.
fn close_shards(ctx: Ctx) -> Bool {
  let state = ctx.state
  let key = state.campaign.key
  let (_lower, _upper, lo, hi) = clock_over(ctx, max_tx_window_ms)
  expect steady(state, lo, hi, [Distributing])
  expect not_paused(lo, hi)
  expect Some(finalized) = state.finalized
  expect Some(progress) = state.distribution
  let deadline_reached = reached(lo, finalized.claim_deadline)
  let inputs = holding_inputs(ctx.tx.inputs, ctx.policy, shard_token(key))
  let closed = list.length(inputs)
  expect closed >= 1
  let (count, total, returned) = list.foldl(
    inputs,
    (0, 0, assets.zero),
    fn(input, (count, total, returned)) {
      expect InlineDatum(data) = input.output.datum
      expect parsed: EscrowDatum = data
      expect ShardDatum(shard) = parsed
      expect shard.campaign == key
      expect deadline_reached || shard.entries == []
      (
        count + list.length(shard.entries),
        total + list.foldl(shard.entries, 0, fn(e, acc) { acc + e.amount }),
        assets.merge(
          returned,
          assets.add(input.output.value, ctx.policy, shard_token(key), -1),
        ),
      )
    },
  )
  let output = continuing(ctx)
  and {
    output.value == ctx.own.value,
    carries(
      output,
      EscrowState {
        ..state,
        distribution: Some(
          Distribution {
            ..progress,
            shards_open: progress.shards_open - closed,
            unclaimed_count: progress.unclaimed_count + count,
            unclaimed_total: progress.unclaimed_total + total,
          },
        ),
        clock: lo.ledger,
      },
    ),
    paid_to(ctx, state.owner.address, owner_role, returned),
    mints(ctx, 0, -closed),
  }
}

/// Completes the escrow (anyone) once every claim shard is closed and either everything was
/// revealed or the claim deadline is reached: the fee on what earners received goes to the
/// treasury, the rest of the pool and the deposit to the owner. The state token is burned.
fn complete(ctx: Ctx) -> Bool {
  let state = ctx.state
  let campaign = state.campaign
  let (_lower, _upper, lo, hi) = clock_over(ctx, max_tx_window_ms)
  expect steady(state, lo, hi, [Distributing])
  expect not_paused(lo, hi)
  expect Some(finalized) = state.finalized
  let (open, head, allocated, unclaimed) = when state.distribution is {
    Some(d) -> (d.shards_open, d.head, d.allocated, d.unclaimed_total)
    None -> (0, state.chain_head, 0, 0)
  }
  expect open == 0
  expect head == "" || reached(lo, finalized.claim_deadline)
  let pool = pool_of(state, ctx.own.value)
  let fee = fee_charged(
    allocated - unclaimed,
    campaign.fee_bps,
    finalized.max_fee,
    pool,
  )
  let lovelace = assets.lovelace_of(ctx.own.value)
  let owner_share = if fee == 0 {
    // Everything but the state token.
    assets.add(ctx.own.value, ctx.policy, state_token(campaign.key), -1)
  } else {
    expect Some(treasury_output) = tagged_output(
      ctx,
      finalized.treasury,
      treasury_role,
    )
    let treasury_lovelace = assets.lovelace_of(treasury_output.value)
    if is_ada(campaign.asset) {
      expect treasury_lovelace >= fee
      expect treasury_lovelace <= max(fee, max_treasury_output_lovelace)
      assets.from_lovelace(lovelace - treasury_lovelace)
    } else {
      expect quantity(treasury_output.value, campaign.asset) >= fee
      expect treasury_lovelace <= max_treasury_output_lovelace
      assets.from_lovelace(lovelace - treasury_lovelace)
        |> assets.add(campaign.asset.policy, campaign.asset.name, pool - fee)
    }
  }
  and {
    paid_to(ctx, state.owner.address, owner_role, owner_share),
    mints(ctx, -1, 0),
  }
}

/// An instance pause by the pauser (rate-limited, freeze budget) or the guardian (any time,
/// extends, takes over a pauser pause), lasting at most `max_pause_secs` from now. It stops the
/// escrow clock and blocks top-ups, commits, finalize, reveals, claims and closes.
fn pause(ctx: Ctx, until: Int) -> Bool {
  let state = ctx.state
  let campaign = state.campaign
  let (lower, upper) = expect_bounds(ctx, max_pause_tx_window_ms)
  let kind = if multisig_signed(ctx.tx, ctx.config.guardian) {
    GuardianPause
  } else if signed_by(ctx.tx, ctx.config.pauser) {
    PauserPause
  } else {
    fail @"not a pauser"
  }
  // Paused time must be accounted exactly up to now before the instance pause changes.
  let lo = read_at(ctx, lower)
  expect lo.global_known
  let max_ms = campaign.limits.max_pause_secs * ms_per_sec
  expect until > upper && until <= lower + max_ms
  expect lo.frozen < hard_max_frozen_secs * ms_per_sec
  let until = when kind is {
    PauserPause -> {
      let local_end = when state.clock.local is {
        Some(local) -> Some(local.until)
        None -> None
      }
      let global_end = when ctx.config.global_pauses is {
        [latest, ..] -> Some(latest.until)
        [] -> None
      }
      let last_end = when (local_end, global_end) is {
        (Some(a), Some(b)) -> Some(max(a, b))
        (Some(a), None) -> Some(a)
        (None, Some(b)) -> Some(b)
        (None, None) -> None
      }
      expect
        when last_end is {
          Some(end) -> lower >= end + max_ms
          None -> True
        }
      // The freeze budget only counts once the campaign has ended.
      expect lower < campaign.ends_at || lo.pauser_left > 0
      until
    }
    GuardianPause ->
      when state.clock.local is {
        Some(local) ->
          if local.until > lower {
            max(local.until, until)
          } else {
            until
          }
        None -> until
      }
  }
  let output = continuing(ctx)
  and {
    output.value == ctx.own.value,
    carries(
      output,
      EscrowState {
        ..state,
        clock: types.ClockLedger {
          ..lo.ledger,
          local: Some(LocalPause { start: lower, until, kind }),
        },
      },
    ),
    mints(ctx, 0, 0),
  }
}

// ## Claim shards

pub fn shard_transition(
  shard: Shard,
  action: EscrowAction,
  own: Output,
  policy: PolicyId,
  registry_policy: PolicyId,
  tx: Transaction,
) -> Bool {
  when action is {
    // An earner claims its own entry, signing with the committed payment key.
    Claim { index } -> {
      let config = find_registry(tx, registry_policy)
      expect [state_input] = holding_inputs(
        tx.reference_inputs,
        policy,
        state_token(shard.campaign),
      )
      expect InlineDatum(data) = state_input.output.datum
      expect parsed: EscrowDatum = data
      expect StateDatum(state) = parsed
      expect Some((lower, upper)) = bounds(tx.validity_range, max_tx_window_ms)
      let budget = pauser_budget_pauses * state.campaign.limits.max_pause_secs
      let lo = read(
        state.clock,
        state.campaign.ends_at,
        budget,
        lower,
        config.global_pauses,
      )
      let hi = read(
        state.clock,
        state.campaign.ends_at,
        budget,
        upper,
        config.global_pauses,
      )
      expect steady(state, lo, hi, [Distributing])
      expect not_paused(lo, hi)
      expect Some(finalized) = state.finalized
      expect hi.clock < finalized.claim_deadline
      expect Some(entry) = list.at(shard.entries, index)
      expect signed_by(tx, entry.key)
      let asset = state.campaign.asset
      let remaining = list.concat(
        list.take(shard.entries, index),
        list.drop(shard.entries, index + 1),
      )
      let continuing_datum = InlineDatum(
        ShardDatum(Shard { ..shard, entries: remaining }),
      )
      expect [next] = list.filter(
        holding(tx.outputs, policy, shard_token(shard.campaign)),
        fn(output) { output.datum == continuing_datum },
      )
      and {
        // The earner's own payment key receives at least its amount.
        list.any(
          tx.outputs,
          fn(output) {
            output.address.payment_credential == VerificationKey(entry.key) && quantity(
              output.value,
              asset,
            ) >= entry.amount
          },
        ),
        next.address == own.address,
        next.value == assets.add(
          own.value,
          asset.policy,
          asset.name,
          -entry.amount,
        ),
        assets.tokens(tx.mint, policy) |> dict.is_empty,
      }
    }

    // Closed with the state, whose `CloseShards` validation does the accounting.
    ShardClose -> {
      expect [state_input] = holding_inputs(
        tx.inputs,
        policy,
        state_token(shard.campaign),
      )
      expect Some(redeemer) = pairs.get_first(
        tx.redeemers,
        Spend(state_input.output_reference),
      )
      expect state_action: EscrowAction = redeemer
      state_action == CloseShards
    }

    _ -> False
  }
}

// ## Helpers

fn max(a: Int, b: Int) -> Int {
  if a > b {
    a
  } else {
    b
  }
}

/// Claim shards live at the shard script, with the same delegation as the state UTxO.
fn shard_address(ctx: Ctx) -> Address {
  Address {
    payment_credential: Script(ctx.shard_script),
    stake_credential: ctx.own.address.stake_credential,
  }
}

fn expect_bounds(ctx: Ctx, width: Int) -> (Int, Int) {
  expect Some(range) = bounds(ctx.tx.validity_range, width)
  range
}

fn read_at(ctx: Ctx, now: Int) -> Reading {
  let campaign = ctx.state.campaign
  read(
    ctx.state.clock,
    campaign.ends_at,
    pauser_budget_pauses * campaign.limits.max_pause_secs,
    now,
    ctx.config.global_pauses,
  )
}

/// The validity range and the escrow clock at both of its ends.
fn clock_over(ctx: Ctx, width: Int) -> (Int, Int, Reading, Reading) {
  let (lower, upper) = expect_bounds(ctx, width)
  (lower, upper, read_at(ctx, lower), read_at(ctx, upper))
}

/// The phase is one of `allowed` over the whole validity range.
fn steady(
  state: EscrowState,
  lo: Reading,
  hi: Reading,
  allowed: List<Phase>,
) -> Bool {
  and {
    list.has(allowed, derive(state, lo.now, lo.clock)),
    list.has(allowed, derive(state, hi.now, hi.clock)),
  }
}

fn not_paused(lo: Reading, hi: Reading) -> Bool {
  !lo.paused && !hi.paused
}

/// The continuing state UTxO: the one output holding the campaign's state token, at the same
/// address.
fn continuing(ctx: Ctx) -> Output {
  expect [output] = holding(
    ctx.tx.outputs,
    ctx.policy,
    state_token(ctx.state.campaign.key),
  )
  expect output.address == ctx.own.address
  output
}

/// The output's datum is exactly this state (compared as data: never parsed).
fn carries(output: Output, state: EscrowState) -> Bool {
  output.datum == InlineDatum(StateDatum(state))
}

pub fn holding(
  outputs: List<Output>,
  policy: PolicyId,
  name: AssetName,
) -> List<Output> {
  list.filter(
    outputs,
    fn(output) { assets.quantity_of(output.value, policy, name) == 1 },
  )
}

fn holding_inputs(
  inputs: List<Input>,
  policy: PolicyId,
  name: AssetName,
) -> List<Input> {
  list.filter(
    inputs,
    fn(input) { assets.quantity_of(input.output.value, policy, name) == 1 },
  )
}

/// This campaign's tokens minted (+) or burned (−) by the transaction.
fn mints(ctx: Ctx, state_delta: Int, shard_delta: Int) -> Bool {
  let key = ctx.state.campaign.key
  and {
    assets.quantity_of(ctx.tx.mint, ctx.policy, state_token(key)) == state_delta,
    assets.quantity_of(ctx.tx.mint, ctx.policy, shard_token(key)) == shard_delta,
  }
}

/// The owner's payment-key hash, refused as a recipient.
fn owner_keys(state: EscrowState) -> List<VerificationKeyHash> {
  when state.owner.credential is {
    VerificationKey(key) -> [key]
    Script(_) -> []
  }
}

fn tagged_output(ctx: Ctx, address: Address, role: Int) -> Option<Output> {
  let tag = InlineDatum(PayoutTag { from: ctx.own_ref, role })
  list.find(
    ctx.tx.outputs,
    fn(output) { output.address == address && output.datum == tag },
  )
}

/// An output to `address`, tagged with this input and `role`, holds at least `value`.
fn paid_to(ctx: Ctx, address: Address, role: Int, value: Assets) -> Bool {
  when tagged_output(ctx, address, role) is {
    Some(output) -> covers(output.value, value)
    None -> False
  }
}

/// `value` holds at least every quantity of `required`.
fn covers(value: Assets, required: Assets) -> Bool {
  assets.flatten(required)
    |> list.all(
        fn((policy, name, amount)) {
          assets.quantity_of(value, policy, name) >= amount
        },
      )
}

/// Cancel and expiry: everything the state UTxO holds goes to the owner; the state token is
/// burned.
fn refund_everything(ctx: Ctx) -> Bool {
  let key = ctx.state.campaign.key
  and {
    paid_to(
      ctx,
      ctx.state.owner.address,
      owner_role,
      assets.add(ctx.own.value, ctx.policy, state_token(key), -1),
    ),
    mints(ctx, -1, 0),
  }
}
