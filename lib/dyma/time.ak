//// Time on Cardano. A script never sees "the block time", only the transaction's validity range
//// `[lower, upper]` (POSIX milliseconds): the transaction lands somewhere inside it. The escrow
//// therefore requires every condition to hold over the whole range:
////
//// - "it has happened" (a deadline reached) is checked at `lower`;
//// - "it has not happened yet" (still before a deadline) is checked at `upper`;
//// - facts written into the state (a pause's start, a dispute's time) use `lower`;
//// - new deadlines are computed from the escrow clock at `upper`, so every window is at least as
////   long as on the CosmWasm escrow, never shorter.
////
//// Ranges are bounded (one hour for pauses, one day otherwise), which bounds how far `lower`
//// can be from the real inclusion time.

use aiken/interval.{Finite, Interval}

/// The validity range as inclusive milliseconds `(lower, upper)`, or `None` when a bound is
/// infinite or the range is empty or wider than `max_width`.
pub fn bounds(range: Interval, max_width: Int) -> Option<(Int, Int)> {
  let lower = when range.lower_bound.bound_type is {
    Finite(t) ->
      Some(
        if range.lower_bound.is_inclusive {
          t
        } else {
          t + 1
        },
      )
    _ -> None
  }
  let upper = when range.upper_bound.bound_type is {
    Finite(t) ->
      Some(
        if range.upper_bound.is_inclusive {
          t
        } else {
          t - 1
        },
      )
    _ -> None
  }
  when (lower, upper) is {
    (Some(lower), Some(upper)) ->
      if lower <= upper && upper - lower <= max_width {
        Some((lower, upper))
      } else {
        None
      }
    _ -> None
  }
}

test bounds_of_a_plutus_v3_range() {
  // Plutus V3 ranges are [lower, upper).
  let range = interval.between(1_000, 5_000)
  let semi_open = Interval {
    lower_bound: range.lower_bound,
    upper_bound: interval.IntervalBound {
      bound_type: Finite(5_000),
      is_inclusive: False,
    },
  }
  and {
    bounds(semi_open, 10_000) == Some((1_000, 4_999)),
    bounds(range, 10_000) == Some((1_000, 5_000)),
    bounds(semi_open, 3_000) == None,
    bounds(interval.after(1_000), 10_000) == None,
    bounds(interval.everything, 10_000) == None,
  }
}
