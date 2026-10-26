//// Text rules shared with the CosmWasm contracts.

use aiken/primitive/bytearray
use dyma/constants.{max_campaign_id_bytes, max_reason_chars, max_uri_bytes}

/// Campaign ids are `[a-z0-9-]{1,64}` (Dyma's UUIDs).
pub fn valid_campaign_id(id: ByteArray) -> Bool {
  let length = bytearray.length(id)
  and {
    length >= 1,
    length <= max_campaign_id_bytes,
    bytearray.foldl(id, True, fn(byte, ok) { ok && or {
          byte >= 0x61 && byte <= 0x7a,
          byte >= 0x30 && byte <= 0x39,
          byte == 0x2d,
        } }),
  }
}

/// Number of UTF-8 code points (bytes that do not continue a sequence).
pub fn utf8_length(text: ByteArray) -> Int {
  bytearray.foldl(
    text,
    0,
    fn(byte, count) {
      if byte >= 0x80 && byte < 0xc0 {
        count
      } else {
        count + 1
      }
    },
  )
}

/// Dispute and rejection reasons: 1 to 280 characters.
pub fn valid_reason(reason: ByteArray) -> Bool {
  let bytes = bytearray.length(reason)
  let chars = utf8_length(reason)
  bytes >= 1 && bytes <= 4 * max_reason_chars && chars <= max_reason_chars
}

pub fn valid_uri(uri: ByteArray) -> Bool {
  bytearray.length(uri) <= max_uri_bytes
}

test campaign_ids() {
  and {
    valid_campaign_id("6f1c2a9e-1b2c-4d5e-8f90-123456789abc"),
    !valid_campaign_id(""),
    !valid_campaign_id("Campaign"),
    !valid_campaign_id("a b"),
    !valid_campaign_id(bytearray.replicate(65, 0x61)),
  }
}

test reasons_count_characters() {
  and {
    valid_reason("Allocation includes farmed wallets"),
    // "été": "é" is two bytes (c3 a9) but one character.
    utf8_length(#"c3a974c3a9") == 3,
    valid_reason(bytearray.replicate(280, 0x61)),
    !valid_reason(bytearray.replicate(281, 0x61)),
    !valid_reason(""),
  }
}
