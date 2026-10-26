# Threat model: Dyma escrow on Cardano

Scope: the `registry`, the five campaign escrow validators (`campaign_policy`, `campaign_state`,
`campaign_payout`, `campaign_admin`, `campaign_shard`) and the `reputation` badges, their
deployment, and the off-chain roles that drive them. Rules: [ESCROW_RULES.md](ESCROW_RULES.md). Interface: [SPEC.md](SPEC.md).
Procedures: [RUNBOOK.md](RUNBOOK.md). **No external audit yet**: this document is its input.

## 1. What is protected

- **Campaign pools**: each campaign's ADA or native tokens, held by its state UTxO and then by its
  claim shards.
- **Earner payouts**: each key of a finalized allocation can claim `min(floor(D·w/P), cap)` (if not
  below the minimum payout) and nothing else, with its own signature, for the whole claim window.
- **Owner refunds**: everything not claimed (dust, skipped amounts, cap overflow, unclaimed entries,
  the unused fee reserve) and the whole ADA deposit go back to the owner; on cancellation and expiry,
  everything.
- **Platform fee**: at most `fee_bps` (≤ the registry's maximum, ≤ 10%) of what earners received,
  once, to the treasury frozen at finalize.
- **Review time**: the challenge window and the owner's dispute, which no hot key can shorten.

## 2. Trust assumptions

1. **Verification is off chain.** The contracts cannot know who earned what. They guarantee
   transparency (every committed entry is in a commit transaction's redeemer), the challenge window,
   bounded damage per key (`max_share_bps`), and that funds only leave to the allocation, the
   treasury (fee) or the owner. The allocation file's hash is recorded, not checked: watchers must
   rebuild it from the commit transactions during the window.
2. **Roles are live; governance is trusted for unfinalized pools.** The registry's governance
   (multisig) can install its own operator and guardian; for campaigns not finalized yet, a
   compromised quorum could commit a hostile allocation and dismiss the owner's dispute. Campaign
   economics (fee, cap, minimum payout, windows, limits) are frozen at creation and the treasury at
   finalize. Registry changes are public transactions and must be monitored.
3. **Ticket signer.** A ticket fixes the rules an owner's pool will follow; the owner signs the
   funding transaction that names them. The ticket key cannot touch existing campaigns. Attempt
   sequencing (a new attempt only after the previous one was cancelled) is Dyma's API's to keep: the
   chain only guarantees that each ticket is used once and that each campaign has its own key.
4. **Native tokens.** A Cardano native token cannot be frozen, clawed back or blocked by its issuer
   (no account-level controls), unlike tokenfactory denoms or CW20 contracts. Its minting policy can
   still mint more of it (dilution, not theft from the escrow).
5. **No upgrade path.** Scripts are immutable: a flaw stays in the campaigns created with that
   script. A corrected script is installed in the registry for new campaigns; the guardian can
   cancel affected campaigns before finalize (refund to owners).

## 3. Threats and mitigations

| # | Threat | Mitigation |
|---|---|---|
| T1 | A forged or replayed ticket funds a campaign under rules the owner never saw | Ed25519 signature by the registry's ticket key over `blake2b_256(serialise_data(ticket))`; the ticket names an input that must be spent (single use) and the owner, who must sign; expiry |
| T2 | A fake campaign UTxO (forged state) | the state token can only be minted by `Create` with a valid ticket, and only into an output carrying the exact initial state; tokens never leave their UTxO except through a validated transition |
| T3 | Double satisfaction: one output satisfies two campaigns | refunds and fees are tagged with the spent state's output reference and the role; continuing outputs are identified by token and, for shards, by exact datum |
| T4 | Value injection or theft through the continuing UTxO | state and shard outputs must hold exactly the expected assets (no extra tokens, exact pool and deposit) |
| T5 | A rogue operator commits a hostile allocation | challenge window, owner dispute, guardian rejection, `max_share_bps` cap per key, privileged keys refused, strict ordering (no duplicates); the pauser can freeze the window while the guardian convenes |
| T6 | A compromised pauser key freezes campaigns forever | rate limit and cooldown, per-campaign budget `2 × max_pause_secs`, 90-day hard cap on frozen time; the guardian lifts pauses; a pause never blocks cancel, expiry, dispute, reject or resolve |
| T7 | Time manipulation through the validity range | conditions must hold over the whole range; reached checks at `lower`, not-yet checks at `upper`; new deadlines from `upper`; ranges capped at one hour (pauses) or one day |
| T8 | Someone claims another earner's entry | the entry's key must sign; the payout goes to an output with that key's payment credential; the entry is removed |
| T9 | A revealer tampers with amounts or splits | the batch must match the hash chain; shard datums and values must equal the amounts computed on chain; shard indexes are sequential |
| T10 | Shards closed early to cut claims short | only empty shards close before the claim deadline; the state counts unclaimed entries; claims stop only at the deadline |
| T11 | The deposit runs out (more shards than paid for) | commit batches are whole shards except the first committed, so shards never exceed `ceil(entries / 20)`; entries never exceed `max_recipients` |
| T12 | Contention: someone spams the state UTxO | only top-ups are open to anyone (before the end, at the spammer's cost); claims use the state as a reference input and contend only within their 20-entry shard |
| T13 | Assets sent to the escrow or registry address by mistake | escrow: governance `Rescue`; registry: swept with a governance `UpdateConfig` |
| T14 | Registry history too short for an old campaign | the clock leaves unknown global pauses out (like an unreadable CosmWasm factory) and never goes back; the operator `Sync`s campaigns after global pauses |
| T15 | Minimum-UTxO rises after creation | the revealer may add ADA to shards (returned to the owner); deposits are computed with a margin |
| T16 | Fee output drains the owner's deposit | the treasury output may carry at most 2 ADA beyond the fee (Cardano requires ADA in every output); none when the fee is zero (Dyma's default) |
| T17 | A forged or replayed badge attestation | Ed25519 signature by the configuration's attester over the attestation's `serialise_data`; the attestation names an input the claim must spend (single use), the owner must sign, and it expires (15 minutes) |
| T18 | A badge passed on to another wallet keeps counting | a badge counts only while its user token sits with the reference's `owner` (payment key); moving it voids it |
| T19 | Several references for one account | readers take the highest nonce; a newer claim can retire older references in the same transaction; governance can revoke any |

## 4. Residual risks

- Unaudited code: canary amounts only until an external audit.
- Governance key compromise (§2.2).
- Earners without a Cardano wallet able to sign cannot claim; Dyma sponsors fees and collateral, but
  a token claim still needs about 1.2 ADA in the earner's output (provided by the sponsor or the
  earner).
- Off-chain watchers must check the allocation during the window; the contract cannot.
