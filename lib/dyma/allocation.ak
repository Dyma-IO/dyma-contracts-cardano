//// Committed allocations. The operator commits the sorted allocation in batches, from its end
//// to its start, each batch chained to the ones committed before it:
////
//// ```text
//// head = blake2b_256(serialise_data(batch) ++ previous_head)        (previous_head = "" at first)
//// ```
////
//// so the final head commits to every batch in ascending order. After the challenge window the
//// batches are revealed again, first to last, each checked against the chain, and turned into
//// claim shards of at most 20 payable entries. Commit transactions keep the entries on chain
//// (in their redeemers), so anyone can rebuild and check the allocation during the challenge
//// window, like the CosmWasm `allocations {}` query.

use aiken/cbor
use aiken/collection/list
use aiken/crypto.{blake2b_256}
use aiken/primitive/bytearray
use dyma/auth.{valid_key_hash}
use dyma/constants.{shard_size}
use dyma/math.{is_skipped, payout_amount}
use dyma/types.{Entry, ShardEntry}

/// One link of the hash chain: a batch and the head of the batches after it.
pub fn link(entries: List<Entry>, next: ByteArray) -> ByteArray {
  blake2b_256(bytearray.concat(cbor.serialise(entries), next))
}

pub type Batch {
  points: Int,
  count: Int,
  first: ByteArray,
  last: ByteArray,
}

fn walk(
  entries: List<Entry>,
  previous: ByteArray,
  forbidden: List<ByteArray>,
  points: Int,
  count: Int,
) -> Option<(Int, Int, ByteArray)> {
  when entries is {
    [] -> Some((points, count, previous))
    [entry, ..rest] ->
      if and {
        valid_key_hash(entry.key),
        entry.points > 0,
        bytearray.compare(previous, entry.key) == Less,
        !list.has(forbidden, entry.key),
      } {
        walk(rest, entry.key, forbidden, points + entry.points, count + 1)
      } else {
        None
      }
  }
}

/// A commit batch: not empty, strictly ascending 28-byte keys (which rules out duplicates),
/// positive points, no privileged key.
pub fn check_batch(
  entries: List<Entry>,
  forbidden: List<ByteArray>,
) -> Option<Batch> {
  when entries is {
    [] -> None
    [first, ..] ->
      when walk(entries, "", forbidden, 0, 0) is {
        Some((points, count, last)) ->
          Some(Batch { points, count, first: first.key, last })
        None -> None
      }
  }
}

pub type Payouts {
  /// Claim shards of at most 20 payable entries, in allocation order.
  shards: List<List<ShardEntry>>,
  paid_total: Int,
  paid_count: Int,
  skipped_count: Int,
  skipped_total: Int,
}

fn chunks(entries: List<ShardEntry>) -> List<List<ShardEntry>> {
  when entries is {
    [] -> []
    _ ->
      [list.take(entries, shard_size), ..chunks(list.drop(entries, shard_size))]
  }
}

/// The payouts of a revealed batch (`math.rs` rules, entry by entry).
pub fn payouts(
  entries: List<Entry>,
  distributable: Int,
  total_points: Int,
  cap: Int,
  min_payout: Int,
) -> Payouts {
  let (paid, paid_total, skipped_count, skipped_total) = list.foldr(
    entries,
    ([], 0, 0, 0),
    fn(entry, (paid, paid_total, skipped_count, skipped_total)) {
      let amount = payout_amount(distributable, entry.points, total_points, cap)
      if is_skipped(amount, min_payout) {
        (paid, paid_total, skipped_count + 1, skipped_total + amount)
      } else {
        (
          [ShardEntry { key: entry.key, amount }, ..paid],
          paid_total + amount,
          skipped_count,
          skipped_total,
        )
      }
    },
  )
  Payouts {
    shards: chunks(paid),
    paid_total,
    paid_count: list.length(paid),
    skipped_count,
    skipped_total,
  }
}

// ## Tests

fn key(n: Int) -> ByteArray {
  bytearray.concat(
    #"00000000000000000000000000000000000000000000000000",
    bytearray.from_int_big_endian(n, 3),
  )
}

test batches_must_be_strictly_ascending() {
  let good = [
    Entry { key: key(1), points: 5 },
    Entry { key: key(2), points: 7 },
  ]
  let unsorted = [
    Entry { key: key(2), points: 5 },
    Entry { key: key(1), points: 7 },
  ]
  let duplicate = [
    Entry { key: key(1), points: 5 },
    Entry { key: key(1), points: 7 },
  ]
  let zero = [Entry { key: key(1), points: 0 }]
  let short_key = [Entry { key: #"0102", points: 1 }]
  and {
    check_batch(good, []) == Some(
      Batch { points: 12, count: 2, first: key(1), last: key(2) },
    ),
    check_batch(unsorted, []) == None,
    check_batch(duplicate, []) == None,
    check_batch(zero, []) == None,
    check_batch(short_key, []) == None,
    check_batch(good, [key(2)]) == None,
    check_batch([], []) == None,
  }
}

test chain_commits_to_every_batch_in_order() {
  let first = [Entry { key: key(1), points: 1 }]
  let second = [Entry { key: key(2), points: 2 }]
  // Committed last batch first: the head is the first batch linked to the rest.
  let tail = link(second, "")
  let head = link(first, tail)
  and {
    head != link(second, link(first, "")),
    head == link(first, link(second, "")),
  }
}

test payouts_fill_shards_of_twenty_and_skip_small_entries() {
  let entries = list.map(
    list.range(1, 45),
    fn(n) { Entry { key: key(n), points: n } },
  )
  let total = list.foldl(entries, 0, fn(e, acc) { acc + e.points })
  let result = payouts(entries, 1_035_000, total, 1_035_000, 1_000)
  and {
    // floor(1 035 000 × n / 1 035) = 1 000 n: only n >= 1 qualifies, every entry is paid.
    result.paid_count == 45,
    list.length(result.shards) == 3,
    list.map(result.shards, list.length) == [20, 20, 5],
    result.paid_total == 1_035_000,
    result.skipped_count == 0,
  }
}

test payouts_withhold_amounts_below_the_minimum() {
  let entries = [
    Entry { key: key(1), points: 990 },
    Entry { key: key(2), points: 5 },
    Entry { key: key(3), points: 5 },
  ]
  let result = payouts(entries, 1_000_000, 1_000, 1_000_000, 10_000)
  and {
    result.shards == [[ShardEntry { key: key(1), amount: 990_000 }]],
    result.skipped_count == 2,
    result.skipped_total == 10_000,
  }
}
