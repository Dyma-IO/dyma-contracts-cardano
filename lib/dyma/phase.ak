//// Phase derivation, ported from the CosmWasm escrow (`phase.rs`): computed from stored facts, a
//// real time `now` and the escrow clock. `starts_at` and `ends_at` compare with real time
//// (active while `starts_at <= now < ends_at`); the later deadlines compare with the escrow
//// clock, which stops while the escrow is paused.
////
//// On Cardano, completion and cancellation consume the state UTxO, so COMPLETED and CANCELLED
//// never appear on chain; "a payout went out" means the first committed batch was revealed into
//// claim shards.

use dyma/types.{
  Active, Challenge, Committing, Disputed, Distributing, Ended, EscrowState,
  Expired, Phase, Upcoming,
}

/// An owner dispute blocks distribution until the guardian resolves it or it lapses.
pub fn dispute_open(state: EscrowState, clock: Int) -> Bool {
  when state.dispute is {
    Some(dispute) -> dispute.resolved_at == None && clock < dispute.expires_at
    None -> False
  }
}

/// Claim shards exist: from then on the finalized allocation is final.
pub fn payouts_started(state: EscrowState) -> Bool {
  state.distribution != None
}

/// `now`: real time; `clock`: escrow-clock time (`<= now`).
pub fn derive(state: EscrowState, now: Int, clock: Int) -> Phase {
  when state.finalized is {
    Some(finalized) ->
      if payouts_started(state) {
        Distributing
      } else if dispute_open(state, clock) {
        Disputed
      } else if clock < finalized.challenge_ends_at {
        Challenge
      } else {
        Distributing
      }
    None ->
      if now < state.campaign.starts_at {
        Upcoming
      } else if now < state.campaign.ends_at {
        Active
      } else if clock >= state.commit_deadline {
        Expired
      } else if state.entry_count > 0 {
        Committing
      } else {
        Ended
      }
  }
}
