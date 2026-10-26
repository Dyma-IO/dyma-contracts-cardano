# Dyma campaign escrow: shared rules

These are the rules every Dyma campaign escrow follows, whatever the chain. Two implementations
exist:

| Ecosystem | Repository | Contracts |
|---|---|---|
| Cosmos (Safrochain) | `Dyma-IO/dyma-contracts` | CosmWasm `dyma-escrow-factory` and `dyma-campaign-escrow` (0.2.0, claim mode) |
| Cardano (Dyma UTXO) | `Dyma-IO/dyma-contracts-cardano` | Aiken `registry` and `campaign_escrow` |

This file is the source of truth. It lives in `dyma-contracts` and `dyma-contracts-cardano` keeps
a byte-identical copy, together with the shared math vectors `fixtures/escrow-math.json`. Any
change to a rule is made in both contracts, through two linked pull requests merged together.
Each repository's `docs/SPEC.md` describes how its chain implements these rules and the few places
where the chain forces a different mechanism (listed in section 9).

## 1. Roles

| Role | Holder | Can |
|---|---|---|
| Governance | multisig (3-of-5 in production) | change the trust configuration; pause and lift global pauses as a guardian |
| Guardian | multisig (2-of-3) | reject an allocation during the challenge window or a dispute; resolve disputes; cancel a campaign before finalize; pause and lift pauses |
| Operator | Dyma hot key | commit, reset and finalize allocations |
| Pauser | Dyma hot key | pause, rate-limited, within a freeze budget |
| Ticket signer | Dyma key | sign campaign tickets (off chain) |
| Treasury | Dyma address | receives the fee, frozen into each campaign at finalize |
| Owner | the wallet that funded the campaign | cancel before the start, dispute once per allocation version, transfer ownership before the start; receives every refund |
| Recipient | a key of the finalized allocation | claim its own entry before the claim deadline |
| Anyone | | top up before the end, complete a claim-mode campaign, return an expired campaign to its owner |

- The guardian is never the operator nor the pauser; the operator never receives the fee.
- Roles are live: a key rotation in the registry (factory) applies to every campaign at once.
- Privileged keys (owner, operator, pauser, guardian, governance, treasury) can never be committed as
  recipients.
- Economic rules are frozen per campaign at creation (fee, cap, minimum payout, windows, limits);
  the treasury is frozen at finalize.

## 2. Tickets

Dyma signs one ticket per campaign funding attempt. It binds the network and the trust
configuration, the campaign id (`[a-z0-9-]{1,64}`) and attempt, the owner (who must fund and sign),
the asset, the minimum funding, `starts_at < ends_at` (start at most 365 days away, campaign at most
365 days long), the fee (`fee_bps` at most the configured maximum, itself at most 1 000), the
minimum payout, `max_share_bps` (1 to 10 000), the challenge, commit and claim windows (within the
configured limits), the escrow code and an expiry. A ticket is single-use.

## 3. Lifecycle

```
UPCOMING ──now ≥ starts_at──► ACTIVE ──now ≥ ends_at──► ENDED ──commit──► COMMITTING ──finalize──► CHALLENGE
   │ owner cancel                                         ▲  reset (version + 1) ◄─┘                  │  ▲ resolve(keep) or the dispute lapses
   │ guardian cancel (any time before finalize)           │                                          ▼  │
CANCELLED                                                 └── guardian reject / resolve(reject) ── DISPUTED (owner dispute)
EXPIRED ◄── clock ≥ commit_deadline and not finalized (the owner gets everything back)
CHALLENGE ──clock ≥ challenge_ends_at, no open dispute──► DISTRIBUTING ──close, at the claim deadline or once all claimed──► COMPLETED
```

- `starts_at` and `ends_at` are real times. Active while `starts_at <= now < ends_at`.
- Top-ups: anyone, before `ends_at`.
- Commits: the operator, after `ends_at`, before the commit deadline (`ends_at + commit_window`), in
  strictly ascending recipient order (no duplicates), positive weights, under the current version.
  A reset discards the commitments (version + 1).
- Finalize: the operator, with the expected entry count and total weight, the allocation file's
  SHA-256 and URI. It snapshots the pool, reserves the fee, and opens the challenge window
  (`challenge_ends_at = clock + challenge_secs`, `claim_deadline = challenge_ends_at +
  claim_window`). An empty allocation reserves no fee and goes through the same window.
- Dispute: the owner, during the challenge window, once per allocation version, with a reason of 1
  to 280 characters. It lapses after `dispute_timeout` (escrow clock) unless resolved, and moves the
  claim deadline to `max(challenge_ends_at, dispute end) + claim_window`. It never refunds.
- Reject: the guardian, during the challenge window or an open dispute, never once a payout went
  out. The allocation is discarded (version + 1, back to ENDED) and the commit deadline moves to at
  least `clock + min_recommit`, at most twice per campaign.
- Resolve: the guardian, during an open dispute: keep the allocation (distribution starts at the
  later of `challenge_ends_at` and now; the claim deadline is that plus the claim window) or reject it.
- Claims: each recipient claims its own entry with its own key, while DISTRIBUTING, before the claim
  deadline, when not paused.
- Close: anyone, at the claim deadline or once every entry is paid (also for an empty allocation).
  The fee on what earners received goes to the treasury, everything else to the owner.
- Cancel: the owner before `starts_at`, the guardian any time before finalize. Everything goes back
  to the owner, no fee.
- Expiry: anyone returns everything to the owner once expired, no fee.

## 4. Escrow clock and pauses

Every deadline after `ends_at` (commit, challenge, dispute, claim) runs on an escrow clock that
stops while the campaign is paused:

```
clock(now) = now − frozen(now)        never decreasing
frozen     = min(90 days, guardian_frozen + min(2 × max_pause_secs, pauser_frozen))
```

counted from `ends_at`. Overlapping campaign and global pauses count once; time already covered by
a guardian pause does not use the pauser's budget.

- One pause lasts at most `max_pause_secs` (at most 7 days) from now and never shortens an active
  pause. A guardian pause over an active pauser pause takes it over.
- The pauser starts a pause only when none is active, and only `max_pause_secs` after the latest
  one ended or was lifted. Its budget per campaign is `2 × max_pause_secs`; once used up, pauser
  pauses no longer block nor freeze that campaign, and new ones are refused.
- Pauses of any kind can stop one campaign's clock for at most 90 days in total.
- A pause blocks top-ups, commits, resets, finalize, payouts, claims and close. It never blocks
  cancel, expiry, dispute, reject or resolve.
- Before `ends_at`, a pause only blocks top-ups.

## 5. Math

```
B        = pool at finalize
max_fee  = floor(B × fee_bps / 10 000)           (0 for an empty allocation)
D        = B − max_fee
cap      = floor(D × max_share_bps / 10 000)
P        = Σ weights
amount_i = min(floor(D × w_i / P), cap)
skipped_i ⇔ amount_i == 0 or amount_i < min_payout      (stays in the leftover)
fee      = min(floor(paid_total × fee_bps / 10 000), max_fee, pool left)   (once, at completion)
```

`paid_total` is what earners actually received. Everything else (dust, skipped amounts, cap
overflow, unclaimed entries, the unused fee reserve) goes back to the owner. The vectors in
`fixtures/escrow-math.json` are checked by both contracts and by Dyma's TypeScript preview.

## 6. Hard limits

| Limit | Value |
|---|---|
| fee | ≤ 1 000 bps (10%) |
| challenge window | ≤ 7 days |
| commit window | ≤ 90 days |
| re-commit floor | ≤ 14 days |
| dispute timeout | ≤ 14 days |
| claim window | ≤ 365 days |
| one pause | ≤ 7 days |
| start delay, campaign length | ≤ 365 days each |
| frozen time per campaign | ≤ 90 days |
| pauser budget | 2 × `max_pause_secs` per campaign |
| commit-deadline extensions | 2 per campaign |
| reason | 1 to 280 characters |
| allocation URI | ≤ 256 bytes |

## 7. Allocation file

One line `"<recipient>,<weight>\n"` per entry, sorted in the order the contract requires. Its
SHA-256 and URI are recorded at finalize. Watchers (Dyma's indexer, the owner, the guardian) rebuild
the file from the chain during the challenge window and compare.

## 8. Refunds and payments

- Refunds only ever go to the campaign owner; the fee only ever to the treasury frozen at finalize.
- Assets that are not the campaign's can always be returned (CosmWasm: to the owner; Cardano: by
  governance, since an unknown UTxO has no owner).

## 9. Where the chains differ

| Topic | CosmWasm (Safrochain) | Cardano |
|---|---|---|
| Time | block time | the transaction's validity range: a condition must hold over the whole range; new deadlines are computed from its end, so windows are never shorter |
| Funding attempts | the factory registry refuses a new attempt unless the previous one was cancelled | the ticket is single-use (it names an input of the funding transaction); attempt order is Dyma's to keep |
| Allocation storage | entries stored by the contract | batches hash-chained, entries in the commit transactions; committed from the end of the sorted list |
| Payouts | claims from the contract's storage | revealed into claim shards of 20 entries; claims spend a shard |
| Deposit | none | a refundable ADA deposit (state plus one per 20 recipients, `max_recipients`), returned to the owner |
| Fee output | fee only | Cardano needs ADA in every output: up to 2 ADA of the deposit can go with the fee |
| Upgrades | migrations for security fixes | immutable scripts: fixes apply to new campaigns |
| Global pause history | the factory keeps all of it | the registry keeps the latest 16; older ones are left out like an unreadable factory |
