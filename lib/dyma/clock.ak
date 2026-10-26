//// The escrow clock, ported from the CosmWasm escrow (`clock.rs`) with milliseconds instead of
//// nanoseconds. `starts_at` and `ends_at` are real times; every later deadline (commit,
//// challenge, dispute, claim) runs on the escrow clock, which stops while the escrow is paused:
////
//// ```text
//// clock(now) = now − frozen(now)          (never decreasing)
//// frozen     = min(90 days, guardian_frozen + min(pauser_budget, pauser_frozen))
//// ```
////
//// counted from `ends_at` on. Global pauses live in the registry, which keeps the latest ones
//// with the global paused time accumulated before each; the escrow keeps its own latest pause
//// and a checkpoint. When the registry's history no longer reaches back to an instant the
//// escrow needs (more than 16 global pauses since it was last touched), global pauses are left
//// out exactly like the CosmWasm escrow does when its factory cannot be read: the checkpoint
//// is not advanced and the clock never goes back once the time is known again.

use aiken/collection/list
use dyma/constants.{hard_max_frozen_secs, ms_per_sec}
use dyma/types.{
  ClockLedger, GlobalSegment, GuardianPause, LocalPause, PauseKind, PauserPause,
  Totals,
}

/// A new escrow's ledger: nothing accounted before `ends_at`.
pub fn new_ledger(ends_at: Int) -> ClockLedger {
  ClockLedger {
    local: None,
    checkpoint: ends_at,
    global_at_checkpoint: None,
    guardian_ms: 0,
    pauser_ms: 0,
    floor: 0,
  }
}

pub const zero_totals: Totals = Totals { guardian: 0, pauser: 0 }

fn max(a: Int, b: Int) -> Int {
  if a > b {
    a
  } else {
    b
  }
}

fn min(a: Int, b: Int) -> Int {
  if a < b {
    a
  } else {
    b
  }
}

/// Global totals at `at`, valid for `at >= segment.start`.
pub fn segment_totals_at(segment: GlobalSegment, at: Int) -> Totals {
  let covered = max(0, min(at, segment.until) - segment.start)
  when segment.kind is {
    GuardianPause ->
      Totals {
        guardian: segment.guardian_before + covered,
        pauser: segment.pauser_before,
      }
    PauserPause ->
      Totals {
        guardian: segment.guardian_before,
        pauser: segment.pauser_before + covered,
      }
  }
}

/// Global paused totals at `at` from the registry's history (newest first), or `None` when the
/// history no longer reaches back to `at`.
pub fn global_totals_at(history: List<GlobalSegment>, at: Int) -> Option<Totals> {
  when history is {
    [] -> Some(zero_totals)
    [segment, ..older] ->
      if at >= segment.start {
        Some(segment_totals_at(segment, at))
      } else {
        when older is {
          // Nothing was paused before the oldest kept segment: nothing before `at` either.
          [] ->
            if segment.guardian_before == 0 && segment.pauser_before == 0 {
              Some(zero_totals)
            } else {
              None
            }
          _ -> global_totals_at(older, at)
        }
      }
  }
}

/// `(guardian, pauser)` paused time between two totals.
fn since(later: Totals, earlier: Totals) -> (Int, Int) {
  (
    max(0, later.guardian - earlier.guardian),
    max(0, later.pauser - earlier.pauser),
  )
}

/// The escrow clock at one instant.
pub type Reading {
  now: Int,
  /// Escrow-clock time (`<= now`).
  clock: Int,
  /// Milliseconds the clock has been stopped since `ends_at` (capped).
  frozen: Int,
  /// The pausable actions are blocked (and, after `ends_at`, the clock stands still).
  paused: Bool,
  /// While paused: when the escrow resumes if nothing changes.
  resumes_at: Option<Int>,
  /// Freeze time the pauser key can still impose.
  pauser_left: Int,
  /// The ledger advanced to `now` (stored by the transaction).
  ledger: ClockLedger,
  /// `False` when the registry's history did not reach back far enough (global pauses left out).
  global_known: Bool,
}

/// Escrow-clock time `secs` after the reading.
pub fn after(reading: Reading, secs: Int) -> Int {
  reading.clock + secs * ms_per_sec
}

/// The escrow-clock deadline has been reached.
pub fn reached(reading: Reading, deadline: Int) -> Bool {
  reading.clock >= deadline
}

/// Reads the clock at `now` (`clock.rs::read`, with the registry's history as the factory).
pub fn read(
  ledger: ClockLedger,
  ends_at: Int,
  pauser_budget_secs: Int,
  now: Int,
  history: List<GlobalSegment>,
) -> Reading {
  let hard = hard_max_frozen_secs * ms_per_sec
  let budget = pauser_budget_secs * ms_per_sec
  let from = ledger.checkpoint
  let (guardian, pauser, next, global_known) = if now > from {
    // At most one instance pause overlaps (from, now]: every instance pause change
    // checkpoints first. Measured from its own start if it began after the checkpoint.
    let local = when ledger.local is {
      None -> None
      Some(l) -> {
        let start = max(l.start, from)
        let end = min(l.until, now)
        if end > start {
          Some((start, end, l.kind))
        } else {
          None
        }
      }
    }
    let totals = {
      let at_from = when ledger.global_at_checkpoint is {
        Some(known) -> Some(known)
        None -> global_totals_at(history, from)
      }
      let at_now = global_totals_at(history, now)
      when (at_from, at_now) is {
        (Some(at_from), Some(at_now)) ->
          when local is {
            None -> Some((at_from, at_now, at_from, at_from))
            Some((start, end, _)) -> {
              let at_start = if start == from {
                Some(at_from)
              } else {
                global_totals_at(history, start)
              }
              let at_end = if end == now {
                Some(at_now)
              } else {
                global_totals_at(history, end)
              }
              when (at_start, at_end) is {
                (Some(s), Some(e)) -> Some((at_from, at_now, s, e))
                _ -> None
              }
            }
          }
        _ -> None
      }
    }
    // Global paused time over (from, now] and over the instance pause, by kind.
    let (dg, dp, lg, lp) = when totals is {
      Some((at_from, at_now, at_local_start, at_local_end)) -> {
        let (dg, dp) = since(at_now, at_from)
        let (lg, lp) = since(at_local_end, at_local_start)
        (dg, dp, lg, lp)
      }
      None -> (0, 0, 0, 0)
    }
    let (add_guardian, add_pauser) = when local is {
      None -> (dg, dp)
      // Guardian time: the instance pause plus global guardian time outside it;
      // pauser-only time: global pauser time outside it.
      Some((start, end, GuardianPause)) ->
        (end - start + max(0, dg - lg), max(0, dp - lp))
      // Guardian time: global guardian time; pauser-only time: the instance pause outside
      // global guardian time, plus global pauser time outside the instance pause.
      Some((start, end, PauserPause)) ->
        (dg, max(0, end - start - lg) + max(0, dp - lp))
    }
    let guardian = ledger.guardian_ms + add_guardian
    let pauser = ledger.pauser_ms + add_pauser
    when totals is {
      Some((_, at_now, _, _)) ->
        (
          guardian,
          pauser,
          ClockLedger {
            ..ledger,
            checkpoint: now,
            global_at_checkpoint: Some(at_now),
            guardian_ms: guardian,
            pauser_ms: pauser,
          },
          True,
        )
      None -> (guardian, pauser, ledger, False)
    }
  } else {
    (ledger.guardian_ms, ledger.pauser_ms, ledger, True)
  }
  let frozen = min(guardian + min(pauser, budget), hard)
  let clock = max(max(now - frozen, 0), ledger.floor)
  let next = ClockLedger { ..next, floor: clock }
  let pauser_left = max(0, budget - pauser)

  // Pauses holding the escrow now (instance pauses always start at or before now).
  let latest_global = if global_known {
    list.head(history)
  } else {
    None
  }
  let active = [
    when ledger.local is {
      Some(l) -> Some((l.until, l.kind))
      None -> None
    },
    when latest_global is {
      Some(g) -> Some((g.until, g.kind))
      None -> None
    },
  ]
    |> list.filter_map(
        fn(pause) {
          when pause is {
            Some((until, kind)) ->
              if until > now {
                Some((until, kind))
              } else {
                None
              }
            None -> None
          }
        },
      )
  let guardian_end = list.foldl(
    active,
    None,
    fn((until, kind), acc) {
      when kind is {
        GuardianPause ->
          when acc is {
            None -> Some(until)
            Some(current) -> Some(max(current, until))
          }
        PauserPause -> acc
      }
    },
  )
  let pauser_end = list.foldl(
    active,
    None,
    fn((until, kind), acc) {
      when kind is {
        PauserPause ->
          when acc is {
            None -> Some(until)
            Some(current) -> Some(max(current, until))
          }
        GuardianPause -> acc
      }
    },
  )
  let resumes = if now < ends_at {
    // Before the end of the campaign a pause only blocks top-ups; no clock runs yet.
    when (guardian_end, pauser_end) is {
      (None, None) -> now
      (Some(g), None) -> g
      (None, Some(p)) -> p
      (Some(g), Some(p)) -> max(g, p)
    }
  } else {
    let end = when guardian_end is {
      Some(g) -> g
      None -> now
    }
    let end = when pauser_end is {
      Some(p) ->
        if p > end {
          end + min(p - end, pauser_left)
        } else {
          end
        }
      None -> end
    }
    min(end, now + max(0, hard - frozen))
  }
  let paused = resumes > now
  Reading {
    now,
    clock,
    frozen,
    paused,
    resumes_at: if paused {
      Some(resumes)
    } else {
      None
    },
    pauser_left,
    ledger: next,
    global_known,
  }
}

/// Real time at which an escrow-clock deadline is projected to be reached (off-chain display:
/// the remaining escrow time from now, plus what is left of the current pause after `ends_at`).
pub fn project(reading: Reading, deadline: Int, ends_at: Int) -> Int {
  if deadline <= reading.clock {
    min(deadline + reading.frozen, reading.now)
  } else {
    let real = reading.now + ( deadline - reading.clock )
    when reading.resumes_at is {
      Some(resumes) -> real + max(0, resumes - max(reading.now, ends_at))
      None -> real
    }
  }
}

// ## Tests (the CosmWasm `clock.rs` tests, in milliseconds)

const s: Int = 1000

fn t(secs: Int) -> Int {
  secs * s
}

fn ledger() -> ClockLedger {
  new_ledger(t(1_000))
}

fn local_pause(start: Int, until: Int, kind: PauseKind) -> Option<LocalPause> {
  Some(LocalPause { start: t(start), until: t(until), kind })
}

fn segment(
  start: Int,
  until: Int,
  kind: PauseKind,
  before: (Int, Int),
) -> GlobalSegment {
  GlobalSegment {
    start: t(start),
    until: t(until),
    kind,
    guardian_before: before.1st * s,
    pauser_before: before.2nd * s,
  }
}

/// Budget 200 s.
fn read_at(l: ClockLedger, now: Int, history: List<GlobalSegment>) -> Reading {
  read(l, t(1_000), 200, t(now), history)
}

test no_pause_is_real_time() {
  let r = read_at(ledger(), 5_000, [])
  let before_end = read_at(ledger(), 500, [])
  and {
    r.clock == t(5_000),
    r.frozen == 0,
    !r.paused,
    r.ledger.checkpoint == t(5_000),
    before_end.clock == t(500),
    before_end.ledger.checkpoint == t(1_000),
  }
}

test guardian_pause_stops_the_clock_and_projects_deadlines() {
  let l = ClockLedger {
    ..ledger(),
    local: local_pause(1_100, 1_200, GuardianPause),
  }
  let r = read_at(l, 1_150, [])
  let after_pause = read_at(l, 1_300, [])
  and {
    r.clock == t(1_100),
    r.paused,
    r.resumes_at == Some(t(1_200)),
    // 100 s of escrow time left on a deadline at 1 200: reached at 1 250 + 50 s of pause.
    project(r, t(1_200), t(1_000)) == t(1_300),
    after_pause.clock == t(1_200),
    !after_pause.paused,
    project(after_pause, t(1_200), t(1_000)) == t(1_300),
    project(after_pause, t(1_250), t(1_000)) == t(1_350),
  }
}

test pause_before_the_end_only_counts_after_it() {
  let l = ClockLedger {
    ..ledger(),
    local: local_pause(900, 1_050, PauserPause),
  }
  let r = read_at(l, 950, [])
  let later = read_at(l, 2_000, [])
  and {
    r.paused,
    r.clock == t(950),
    later.frozen == 50 * s,
    later.clock == t(1_950),
  }
}

test pauser_budget_caps_the_freeze() {
  // 300 s pauser pause, budget 200 s.
  let l = ClockLedger {
    ..ledger(),
    local: local_pause(1_000, 1_300, PauserPause),
  }
  let r = read_at(l, 1_100, [])
  let later = read_at(l, 1_250, [])
  and {
    r.paused,
    r.resumes_at == Some(t(1_200)),
    r.pauser_left == 100 * s,
    !later.paused,
    later.frozen == 200 * s,
    later.clock == t(1_050),
    later.pauser_left == 0,
  }
}

test overlapping_instance_and_global_pauses_count_once() {
  // Instance pauser pause 1 100..1 300, global guardian pause 1 200..1 400.
  let l = ClockLedger {
    ..ledger(),
    local: local_pause(1_100, 1_300, PauserPause),
  }
  let history = [segment(1_200, 1_400, GuardianPause, (0, 0))]
  let r = read_at(l, 1_500, history)
  // Same reading in two steps (checkpoint in the middle).
  let mid = read_at(l, 1_250, history)
  let r2 = read_at(mid.ledger, 1_500, history)
  and {
    // Frozen 1 100..1 400 = 300 s: pauser-only 100 s, guardian 200 s.
    r.frozen == 300 * s,
    r.ledger.guardian_ms == 200 * s,
    r.ledger.pauser_ms == 100 * s,
    r.clock == t(1_200),
    mid.paused,
    mid.resumes_at == Some(t(1_400)),
    r2.frozen == r.frozen,
    r2.clock == r.clock,
  }
}

test global_pause_alone_and_older_history() {
  // Two global pauses since the checkpoint: the older one comes from the kept history.
  let history = [
    segment(1_400, 1_450, PauserPause, (0, 100)),
    segment(1_100, 1_200, PauserPause, (0, 0)),
  ]
  let r = read(ledger(), t(1_000), 1_000, t(2_000), history)
  and {
    r.frozen == 150 * s,
    r.clock == t(1_850),
    r.global_known,
  }
}

test unknown_history_leaves_global_out_and_keeps_the_checkpoint() {
  let l = ClockLedger {
    ..ledger(),
    local: local_pause(1_100, 1_200, GuardianPause),
  }
  // The only kept segment starts after the checkpoint and had earlier pauses before it.
  let history = [segment(1_300, 1_350, GuardianPause, (40, 0))]
  let r = read(l, t(1_000), 200, t(1_500), history)
  // Later the history is readable again from the checkpoint.
  let known = [segment(1_300, 1_350, GuardianPause, (0, 0))]
  let r2 = read_at(r.ledger, 1_420, known)
  let r3 = read_at(r2.ledger, 1_600, known)
  and {
    r.frozen == 100 * s,
    !r.global_known,
    r.ledger.checkpoint == t(1_000),
    r.ledger.floor == t(1_400),
    // A global pause 1 300..1 350 was missed: the clock does not go back below the floor.
    r2.frozen == 150 * s,
    r2.clock == t(1_400),
    r3.clock == t(1_450),
  }
}

test hard_cap_on_frozen_time() {
  let l = ClockLedger {
    ..ledger(),
    guardian_ms: hard_max_frozen_secs * s - 10 * s,
    checkpoint: t(1_000),
    global_at_checkpoint: Some(zero_totals),
    local: local_pause(1_000, 1_100, GuardianPause),
  }
  let r = read_at(l, 1_005, [])
  let later = read_at(l, 1_050, [])
  and {
    r.paused,
    r.resumes_at == Some(t(1_010)),
    !later.paused,
    later.frozen == hard_max_frozen_secs * s,
  }
}

test clock_never_decreases() {
  // A walk over pause patterns: the clock is monotone and never ahead of now.
  let history = [segment(1_150, 1_260, PauserPause, (0, 0))]
  let start = ClockLedger {
    ..ledger(),
    local: local_pause(1_100, 1_200, GuardianPause),
  }
  let (_, _, ok) = list.foldl(
    list.range(0, 85),
    (start, 0, True),
    fn(step, (l, last, ok)) {
      let now = 1_000 + step * 7
      let r = read_at(l, now, history)
      (r.ledger, r.clock, ok && r.clock >= last && r.clock <= t(now))
    },
  )
  ok
}

test history_lookup() {
  let history = [
    segment(300, 400, GuardianPause, (5, 20)),
    segment(100, 120, PauserPause, (5, 0)),
  ]
  and {
    global_totals_at(history, t(350)) == Some(
      Totals { guardian: 55 * s, pauser: 20 * s },
    ),
    global_totals_at(history, t(500)) == Some(
      Totals { guardian: 105 * s, pauser: 20 * s },
    ),
    global_totals_at(history, t(110)) == Some(
      Totals { guardian: 5 * s, pauser: 10 * s },
    ),
    // Before the oldest kept segment, which had earlier pauses: unknown.
    global_totals_at(history, t(50)) == None,
    global_totals_at([], t(50)) == Some(zero_totals),
  }
}
