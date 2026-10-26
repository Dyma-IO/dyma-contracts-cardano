# Dyma campaign escrow on Cardano: specification (0.1.0)

This document describes the contracts as implemented in this repository (`validators/`,
`lib/dyma/`). The shared rules are in [ESCROW_RULES.md](ESCROW_RULES.md), a byte-identical copy of
the CosmWasm repository's file; this document says how Cardano implements them. Where this document
and the code disagree, the code is right and this document is a bug.

## 1. Topology

```
                  ┌──────────── registry (one per network; parameterised by a seed output) ─────────────┐
 Dyma API ─ticket→│ UTxO holding the registry NFT, datum RegistryDatum: governance and guardian multisigs, │
 (Ed25519 key)    │ operator, pauser, ticket key, treasury, current escrow scripts, max fee, limits,        │
                  │ latest 16 global pauses                                                                  │
                  └──────────────────────────────────▲──────────────────────────────────────────────────────┘
                                                     │ reference input of every campaign transaction
 owner wallet ── Create(ticket, signature) ──► campaign_policy (mints "S" ++ key / "L" ++ key)
                  campaign_state  ─ the state UTxO: state token, pool, owner's ADA deposit (EscrowState)
                     ├─ funding, allocation and challenge transitions
                     └─ forwards payouts to campaign_payout, pauses/ownership/sync to campaign_admin
                        (zero-ADA withdrawals from their registered reward accounts, same transaction)
                  campaign_shard  ─ claim shards: shard token, ≤ 20 entries (key, amount), deposit
```

Five escrow scripts, because Cardano caps a transaction (and so any script) at 16 KB:

| Script | Purpose | Parameters | Size |
|---|---|---|---:|
| `registry` | the trust configuration and global pause ledger | seed output | 5.9 KB |
| `campaign_policy` | mints and burns campaign tokens; `Create` from a ticket | registry policy | 5.5 KB |
| `campaign_state` | campaign state UTxOs: funding, allocation, challenge | registry policy, token policy, shard, payout and admin scripts | 14.6 KB |
| `campaign_payout` | reveal into shards, close shards, complete (withdrawal) | registry policy, token policy, shard script | 13.1 KB |
| `campaign_admin` | pauses, ownership, clock checkpoints (withdrawal) | registry policy, token policy, shard script | 10.6 KB |
| `campaign_shard` | claim shards: claims and closes | registry policy, token policy | 9.3 KB |

- **Registry** (`validators/registry.ak`): its NFT (`dyma-registry`) can be minted once, when the
  seed output is spent; the script hash is both the NFT's policy id and the registry address's
  payment credential.
- **Campaign escrow**: each campaign funding attempt is one state UTxO, identified by its 28-byte
  key `blake2b_224(serialise_data(seed))`, where `seed` is an input of the funding transaction named
  by the ticket: keys are unique by construction and a ticket can be used once. The state script is
  parameterised by the other scripts, so its hash names the whole escrow version; tickets bind it
  and the registry names the version new campaigns use (`escrow: { policy, state, shard }`).
- **Forwarding**: for a payout or admin transition, `campaign_state` only checks that the matching
  script's zero-ADA withdrawal is in the transaction; that script validates every campaign state
  the transaction spends with one of its transitions (it reads each redeemer from the transaction).
  The two reward accounts are registered at deployment and can never be deregistered.
- **Roles are live**: campaign transactions read the registry as a reference input, so a key
  rotation applies to every campaign at once. **Economic rules are frozen**: the ticket's values
  and a copy of the registry's limits are stored in the campaign at creation; the treasury is frozen
  at finalize.
- **Immutable scripts**: a corrected escrow is a new set of script hashes; governance points the
  registry at it and new campaigns use it. Existing campaigns keep their scripts.

## 2. Data

All types are in `lib/dyma/types.ak`; the blueprint (`plutus.json`) is generated from them. Times
are POSIX milliseconds; durations are seconds (the same values as CosmWasm).

| Datum | Holder | Content |
|---|---|---|
| `RegistryDatum` | registry UTxO | roles, `ticket_key` (32-byte Ed25519), `treasury`, `escrow` (current token policy, state and shard scripts), `max_fee_bps`, `limits`, `global_pauses` (newest first, ≤ 16) |
| `StateDatum(EscrowState)` | state UTxO | `campaign` (immutable parameters), `owner`, `pending_owner`, `version`, `entry_count`, `total_points`, `chain_head`, `lowest_committed`, `commit_deadline`, `recommit_extensions`, `funded_total`, `finalized`, `dispute`, `distribution`, `clock` (the escrow-clock ledger) |
| `ShardDatum(Shard)` | claim shard | `campaign` (key), `index`, `entries: [(key, amount)]` |
| `PayoutTag` | refund and fee outputs | `{ from: the spent state's output reference, role: 0 owner / 1 treasury }` |

`Owner` is a credential (a payment key, or a script such as a native multisig wallet) and the
address every refund goes to.

## 3. Values

The state UTxO holds exactly: the state token, the pool (ADA, or one native token) and the owner's
deposit in lovelace, nothing else.

```
max_shards    = ceil(max_recipients / 20)
deposit_total = state_deposit + shard_deposit × max_shards            (paid at creation)
deposit_left  = state_deposit + shard_deposit × (max_shards − shards_created)
pool          = token quantity, or (ADA campaigns) lovelace − deposit_left
```

Each claim shard holds exactly its shard token, the sum of its entries (token or lovelace) and at
least `shard_deposit` lovelace (whoever reveals may add ADA if Cardano's minimum rises; it goes to
the owner at close). Both deposits are computed by Dyma's API from the protocol parameters with a
margin, and checked against a floor of 2 ADA.

## 4. Time

A script sees the transaction's validity range `[lower, upper]`, not a block time.

- A transition requires its phase over the whole range (computed at `lower` and at `upper`).
- "Reached" checks use `lower`; "not yet" checks use `upper`.
- Facts written into the state (a pause's start, a dispute's time, `finalized.at`) use `lower`.
- New deadlines use the escrow clock at `upper` (`after(hi, secs)`), so every window is at least as
  long as on CosmWasm.
- Ranges span at most one hour for pauses and unpauses, one day otherwise.

## 5. The escrow clock

`lib/dyma/clock.ak` is a port of the CosmWasm `clock.rs`, in milliseconds, with the registry's
`global_pauses` as the factory's ledger. Global paused time at an instant `t` is read from the
newest kept segment that starts at or before `t` (`totals_before` plus its covered time). When the
16 kept segments do not reach back to an instant the campaign needs, the reading leaves global
pauses out, keeps the checkpoint and only advances the floor: exactly what the CosmWasm escrow does
when its factory cannot be read. The operator can checkpoint any campaign (`Sync`) after global
pauses so that this never happens in practice.

## 6. Transitions

The state UTxO's spend handler dispatches on the redeemer. Unless stated, the transition keeps the
state UTxO at the same address with exactly the same value, writes the expected new datum (compared
as data, field by field), stores the clock ledger advanced to `lower`, and mints or burns none of
the campaign's tokens.

| Redeemer | Who | Phase (whole range) | Paused? | Effect |
|---|---|---|---|---|
| mint `Create { ticket, signature }` | the ticket's owner | registry not globally paused | — | ticket checks (`lib/dyma/ticket.ak`, the factory's order), Ed25519 signature over `blake2b_256(serialise_data(ticket))` by the registry's `ticket_key`, seed spent; mints exactly the state token; the state output (payment credential = the escrow) carries `initial_state(ticket)`, the deposit and a pool `>= min_funding` |
| `TopUp` | anyone | UPCOMING, ACTIVE | blocks | pool grows, `funded_total` grows |
| `Cancel` | owner before `starts_at`, guardian any time before finalize | not finalized | no | everything but the state token to a tagged owner output; burns the state token |
| `ReclaimExpired` | anyone | EXPIRED at `lower` | no | same as cancel |
| `Commit { version, entries }` | operator | ENDED, COMMITTING | blocks | 1..`max_commit_batch` entries; a multiple of 20 except the first batch committed; strictly ascending 28-byte keys below `lowest_committed`; positive weights; no privileged key; `entry_count + n <= max_recipients`; `chain_head = blake2b_256(serialise_data(entries) ++ chain_head)` |
| `Reset { version }` | operator | ENDED, COMMITTING | blocks | version + 1, commitments cleared |
| `Finalize {..}` | operator | ENDED, COMMITTING | blocks | expected count and weight match; 32-byte hash; URI ≤ 256 bytes; snapshot of the pool (§5 of the rules); `challenge_ends_at = clock(upper) + challenge_secs`; treasury frozen |
| `RaiseDispute { reason }` | owner | CHALLENGE, no dispute yet | no | `expires_at = clock(upper) + dispute_timeout`; claim deadline moves |
| `Reject { reason }` | guardian | CHALLENGE, DISPUTED | no | allocation discarded; commit deadline moves to at least `clock(upper) + min_recommit`, twice at most |
| `Resolve { keep_allocation }` | guardian | DISPUTED | no | keep: `resolved_at = lower`, claim deadline from `max(challenge_ends_at, clock(upper))`; reject: as `Reject` |
| `Reveal { entries, next }` | anyone | DISTRIBUTING, before the claim deadline | blocks | `link(entries, next)` equals the next chain head; payable entries (rules §5) become claim shards of 20 in order (`index` continues); the pool and one `shard_deposit` per shard leave the state; mints one shard token per shard |
| `CloseShards` | anyone | DISTRIBUTING | blocks | closes the campaign's shard inputs: empty ones any time, others at the claim deadline; their value goes to a tagged owner output; burns their tokens; counts unclaimed entries |
| `Complete` | anyone | DISTRIBUTING, no open shard, everything revealed or the claim deadline reached | blocks | fee `min(floor(paid × fee_bps / 10 000), max_fee, pool)` to a tagged treasury output (with at most 2 ADA of the deposit, or exactly the fee in ADA campaigns); the rest to a tagged owner output; burns the state token |
| `Pause { until }` | pauser, guardian | any | — | the CosmWasm rules (rate limit, cooldown, budget, hard cap, guardian extends and takes over); needs the global history known |
| `Unpause` | guardian | the pause active over the range | — | the pause ends at `lower` |
| `TransferOwnership`, `AcceptOwnership`, `CancelOwnershipTransfer` | owner, pending owner, owner | before `starts_at` (cancel: any time) | no | two-step ownership with optional expiry |
| `Sync` | operator | any | no | clock checkpoint only |

Claim shards (spend handler, the UTxO holds a shard token):

| Redeemer | Who | Effect |
|---|---|---|
| `Claim { index }` | the entry's key (signature) | the campaign state is a reference input, DISTRIBUTING over the range, not paused, `clock(upper) < claim_deadline`; an output to the entry key's payment credential holds at least the amount; the shard continues at the same address without the entry, its value lowered by exactly the amount; no campaign token minted |
| `ShardClose` | — | the campaign's state UTxO is spent in the same transaction with `CloseShards` |

Anything else at the escrow address (no campaign token) can only be spent with `Rescue`, signed by
the registry's governance. Minting with `Delegate` is allowed only for tokens of campaigns whose
state UTxO is spent in the same transaction (never to create a state token); that spend checks the
exact quantities.

Registry (spend handler, the UTxO holds the NFT):

| Redeemer | Who | Effect |
|---|---|---|
| `UpdateConfig` | governance threshold (and the new governance's, if it changes) | any change but the pause history; the result must pass `valid_registry` (limits, multisigs, role separation) |
| `GlobalPause { until }` | pauser (rate-limited), guardian or governance | the factory's rules; a new segment carries the global paused totals before it; 16 segments kept |
| `GlobalUnpause` | guardian or governance | the active pause ends at `lower` |

A UTxO sent to the registry address by mistake leaves only with an `UpdateConfig` of the registry
in the same transaction.

## 7. Double satisfaction

Every payment a validator requires to the owner or the treasury is an output tagged with the spent
state's output reference and the role (`PayoutTag`), so one output can never satisfy two campaigns.
Claims pay distinct keys. Continuing outputs are identified by their token (and, for shards, by
their exact datum, which includes the shard index).

## 8. Execution budget

`validators/budget.test.ak` measures the largest transactions (traces off, mainnet limits 16.5 M
memory, 10 G CPU per transaction):

| Transaction | Memory | CPU |
|---|---:|---:|
| commit 100 entries | 37.7% | 23.8% |
| reveal 100 entries into 5 shards (state + payout + minting) | 38.3% | 28.1% |
| close 5 shards (state + payout + 5 shards + burning) | 34.1% | 18.0% |
| claim from a 20-entry shard | 7.9% | 4.4% |
| complete with a fee (state + payout) | 7.5% | 4.1% |

Dyma's API commits at most 100 entries per transaction and closes at most 5 shards per transaction.

## 9. Differences from the CosmWasm escrow

See [ESCROW_RULES.md §9](ESCROW_RULES.md#9-where-the-chains-differ). In short: validity ranges
instead of block time; single-use tickets instead of a factory attempt registry; hash-chained
commits revealed into 20-entry claim shards; a refundable ADA deposit; up to 2 ADA of the deposit
with a fee output; immutable scripts; 16 global pauses of history; strays rescued by governance;
reasons counted in UTF-8 characters (bytes ≤ 4 × 280).

## 10. Reputation badges (CIP-68)

`validators/reputation.ak` (with `lib/dyma/badge.ak`) is the Cardano counterpart of the CosmWasm
`dyma-reputation`: Dyma computes reputation off chain and signs attestations; the script only
checks them. One script, parameterised by a seed output, is the badges' policy id and the address
that holds the configuration and every badge reference (5.6 KB).

| Datum | Holder | Content |
|---|---|---|
| `ReputationConfig` | the UTxO with the `dyma-reputation` NFT | governance multisig, `attester` (32-byte Ed25519), `paused`, collection name and description, `tiers` (1 to 32, ascending by tier and minimum score, boosts 10 000 to 50 000 bps never decreasing, images ≤ 256 bytes) |
| `Cip68Datum` | a badge reference (CIP-67 label 100) | `metadata` (`name` = collection · tier name, `image`, `description`, `tier`, `tier_name`, `score`, `boost_bps`, `account`, `issued_at`), `version` 1, `extra` = `BadgeState { account, owner, tier, score, boost_bps, nonce, issued_at }` |

An `Attestation { version, policy, account, owner, tier, score, nonce, issued_at, expires_at, seed }`
is signed with Ed25519 over `blake2b_256(serialise_data(attestation))`. A badge's asset names are
the CIP-67 labels 100 and 222 followed by `blake2b_224(serialise_data(seed))`.

| Redeemer | Who | Effect |
|---|---|---|
| mint `Init` | whoever spends the seed | the configuration NFT, once, into a valid configuration at the script |
| mint `Claim { attestation, signature }` | the attested `owner` (signature) | not paused; the attester's signature; `policy` is this script; the seed is spent (single use); `upper < expires_at`, `issued_at < expires_at`, `issued_at ≤ lower + 10 min`; the tier exists and `score ≥ min_score`; mints exactly the pair (other names of the policy may only burn); the reference goes to the script with exactly its ADA and token and the expected `Cip68Datum` |
| mint `Burn` | holders | burning only (a holder burns its user token) |
| spend `UpdateConfig` | governance (and a new governance) | any valid configuration; the NFT stays at the script |
| spend `Retire` (a reference) | a newer claim of the same account in the same transaction (`nonce` greater), or governance (revocation) | the reference token is burned |
| spend `Retire` (anything else) | governance | strays sent to the script address |

**Validity rule** (for Dyma and anyone reading badges): an account's badge is its reference with
the highest nonce, and it counts only while its user token (label 222, same name) sits at an
address whose payment key is the reference's `owner`. Moving the token voids the badge, which makes
it soulbound in effect; a newer claim retires the older reference. Badges carry no economic power:
the boost a distribution applies comes from Dyma's records, as on Cosmos.

Differences from the CosmWasm contract: a claim cannot burn a user token held in someone else's
wallet, so the older user token stays as an orphan without a reference; `revoke_badge` burns the
reference (unused attestations of the account expire within 15 minutes); there is no IBC bridge.
