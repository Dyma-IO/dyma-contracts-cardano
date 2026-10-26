//// Pro-rata math, bit for bit the CosmWasm escrow's (`math.rs`) and Dyma's TypeScript preview
//// (`dyma-shared` escrow-math). Shared vectors: `fixtures/escrow-math.json`.
////
//// ```text
//// B   = pool at finalize
//// fee = floor(B × fee_bps / 10 000)          (fee reserve; 0 for an empty allocation)
//// D   = B − fee                              ("distributable")
//// cap = floor(D × max_share_bps / 10 000)
//// amount_i = min(floor(D × w_i / P), cap)
//// skipped when amount_i == 0 or amount_i < min_payout   (stays in the leftover)
//// fee charged at completion = min(floor(paid × fee_bps / 10 000), fee reserve, pool left)
//// ```
////
//// Aiken integers are unbounded, so no intermediate can overflow (CosmWasm uses a 256-bit
//// intermediate for the same reason).

use aiken/collection/list
use aiken/fuzz
use dyma/constants.{bps_denominator}

/// `floor(amount × bps / 10 000)`.
pub fn bps_of(amount: Int, bps: Int) -> Int {
  amount * bps / bps_denominator
}

pub type Snapshot {
  gross: Int,
  fee: Int,
  distributable: Int,
  cap: Int,
}

/// The finalize snapshot of a pool.
pub fn finalize_snapshot(
  gross: Int,
  fee_bps: Int,
  max_share_bps: Int,
) -> Snapshot {
  let fee = bps_of(gross, fee_bps)
  let distributable = gross - fee
  Snapshot {
    gross,
    fee,
    distributable,
    cap: bps_of(distributable, max_share_bps),
  }
}

/// `min(floor(D × w / P), cap)`.
pub fn payout_amount(
  distributable: Int,
  points: Int,
  total_points: Int,
  cap: Int,
) -> Int {
  let share = distributable * points / total_points
  if share < cap {
    share
  } else {
    cap
  }
}

/// Entries with a zero amount or an amount below `min_payout` are skipped.
pub fn is_skipped(amount: Int, min_payout: Int) -> Bool {
  amount == 0 || amount < min_payout
}

/// The fee charged at completion on what earners received.
pub fn fee_charged(
  paid_total: Int,
  fee_bps: Int,
  max_fee: Int,
  available: Int,
) -> Int {
  let fee = bps_of(paid_total, fee_bps)
  let fee = if fee < max_fee {
    fee
  } else {
    max_fee
  }
  if fee < available {
    fee
  } else {
    available
  }
}

pub type Distribution {
  /// Paid amount per entry (0 when skipped).
  amounts: List<Int>,
  skipped: Int,
  paid_total: Int,
  /// `D − paid_total` (dust, cap overflow and skipped amounts).
  leftover: Int,
}

/// The per-entry rules applied to a whole list of weights (tests and shared vectors).
pub fn distribute_all(
  distributable: Int,
  weights: List<Int>,
  cap: Int,
  min_payout: Int,
) -> Distribution {
  let total_points = list.foldl(weights, 0, fn(w, acc) { acc + w })
  let (amounts, skipped, paid_total) = list.foldr(
    weights,
    ([], 0, 0),
    fn(w, (amounts, skipped, paid)) {
      let amount = payout_amount(distributable, w, total_points, cap)
      if is_skipped(amount, min_payout) {
        ([0, ..amounts], skipped + 1, paid)
      } else {
        ([amount, ..amounts], skipped, paid + amount)
      }
    },
  )
  Distribution {
    amounts,
    skipped,
    paid_total,
    leftover: distributable - paid_total,
  }
}

// ## Tests

test worked_examples() {
  let d = distribute_all(1_000_000_000, [50, 30, 20], 1_000_000_000, 0)
  let d2 = distribute_all(100, [1, 1, 1], 100, 0)
  let s = finalize_snapshot(1_000, 0, 5_000)
  let d3 = distribute_all(s.distributable, [90, 5, 5], s.cap, 0)
  and {
    d.amounts == [500_000_000, 300_000_000, 200_000_000],
    d.leftover == 0,
    d2.amounts == [33, 33, 33],
    d2.leftover == 1,
    s.cap == 500,
    d3.amounts == [500, 50, 50],
    d3.leftover == 400,
  }
}

test fee_is_charged_on_what_was_paid_and_bounded() {
  let s = finalize_snapshot(1_000_000, 500, 10_000)
  and {
    s.fee == 50_000,
    s.distributable == 950_000,
    fee_charged(950_000, 500, s.fee, 1_000_000) == 47_500,
    fee_charged(2_000_000, 500, s.fee, 1_000_000) == 50_000,
    fee_charged(950_000, 500, s.fee, 10) == 10,
  }
}

fn distribution_inputs() -> Fuzzer<(Int, List<Int>, Int)> {
  let d <- fuzz.and_then(fuzz.int_between(0, 1_000_000_000_000))
  let weights <- fuzz.and_then(
    fuzz.list_between(fuzz.int_between(1, 1_000_000_000), 1, 40),
  )
  let cap_bps <- fuzz.map(fuzz.int_between(1, 10_000))
  (d, weights, cap_bps)
}

test never_pays_more_than_distributable(
  (d, weights, cap_bps) via distribution_inputs(),
) {
  let cap = bps_of(d, cap_bps)
  let result = distribute_all(d, weights, cap, 0)
  and {
    result.paid_total <= d,
    list.all(result.amounts, fn(a) { a <= cap && a >= 0 }),
    result.leftover == d - result.paid_total,
    // Without a cap, the dust is below one unit per entry.
    if cap_bps == 10_000 {
      result.leftover < list.length(weights)
    } else {
      True
    },
  }
}
