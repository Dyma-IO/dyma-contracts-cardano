# Audit scope: Dyma escrow on Cardano 0.1.0

This document covers what a security review of this repository includes, what it leaves out,
where to look first, and how to build and test.

## 1. Summary

| | |
|---|---|
| Repository | [`Dyma-IO/dyma-contracts-cardano`](https://github.com/Dyma-IO/dyma-contracts-cardano) (public, MIT) |
| Revision | pinned to a release tag before a review starts |
| Language | Aiken v1.1.24 (Plutus V3), stdlib v4.0.0 (fuzz v3.0.0 for tests only) |
| Target | Cardano mainnet and preprod, protocol 11: 16 KB per transaction, 16.5 M memory units and 10 G CPU steps per transaction |
| Build | `aiken build --trace-level silent`; CI fails if the committed `plutus.json` differs from the build |
| Documentation | [ESCROW_RULES.md](ESCROW_RULES.md) (rules), [SPEC.md](SPEC.md) (implementation), [THREAT_MODEL.md](THREAT_MODEL.md), [RUNBOOK.md](RUNBOOK.md) |

## 2. In scope

Line counts exclude blank lines and comments, and include in-file tests.

| Path | Lines | Content |
|---|---:|---|
| `validators/registry.ak` | 206 | one-shot registry NFT, `UpdateConfig`, global pauses and their history, sweeping stray UTxOs |
| `validators/campaign_policy.ak` | 85 | `Create` from a ticket; `Delegate` minting for campaigns spent in the same transaction |
| `validators/campaign_state.ak` | 62 | dispatch of state UTxO spends: own transitions, forwarding to payout or admin, `Rescue` |
| `validators/campaign_payout.ak` | 31 | withdraw-zero entry point for reveal, shard closes and completion; registration-only `publish` |
| `validators/campaign_admin.ak` | 31 | withdraw-zero entry point for pauses, ownership and `Sync`; registration-only `publish` |
| `validators/campaign_shard.ak` | 44 | claims, shard closes, `Rescue` |
| `lib/dyma/escrow.ak` | 981 | every campaign transition, forwarding (`forwarded`), payments and their tags, continuing outputs |
| `lib/dyma/clock.ak` | 479 | escrow clock (a port of the CosmWasm `clock.rs`), global pause history |
| `lib/dyma/types.ak` | 236 | data types: their field order is the on-chain encoding |
| `lib/dyma/allocation.ak` | 170 | commit chain, batch checks, payouts into claim shards |
| `lib/dyma/ticket.ak` | 146 | ticket digest, Ed25519 signature, rule checks, initial state |
| `lib/dyma/math.ak` | 141 | pro-rata payouts, caps, skips, fees |
| `lib/dyma/holdings.ak` | 97 | exact values, deposits, pools |
| `lib/dyma/registry_rules.ak` | 94 | registry validity, role separation, privileged keys |
| `lib/dyma/auth.ak`, `time.ak`, `phase.ak`, `text.ak`, `constants.ak` | 221 | signatures and multisigs, validity ranges, phases, text checks, hard limits |
| `validators/reputation.ak`, `lib/dyma/badge.ak` | 360 | reputation badges (CIP-68): configuration NFT, attested claims, retirement of older badges, revocation |
| `plutus.json`, `aiken.toml`, `aiken.lock` | | blueprint, compiler and dependency pins |

Total: 3,024 lines (459 in validators, 2,565 in `lib/dyma`).

Supporting material, lower priority: the deployment procedure ([RUNBOOK §3](RUNBOOK.md#3-deploying))
and the deployment records (`deployments/`).

## 3. Out of scope

- Test code: `lib/dyma/testkit.ak`, `validators/*.test.ak` and the generated
  `lib/dyma/math_vectors.ak`. They are useful for reproducing scenarios.
- `scripts/` (test tooling).
- Dyma's API: the ticket signer, transaction builders, indexer and the off-chain allocation
  computation.
- Dyma's web applications, wallets, and the Cardano ledger itself.

## 4. Where to look first

1. **Fund flows and values** (`escrow.ak`, `holdings.ak`). Check that refunds, fees, shard
   creation, closes and completion move exactly the computed amounts. ADA campaigns deserve extra
   attention, because the pool and the deposit share the lovelace (`pool_of`, `deposit_left`).
2. **Double satisfaction.** Several campaigns, or a campaign and its shards, spent in one
   transaction: owner and treasury outputs are tagged per state input (`PayoutTag`), and continuing
   outputs are identified by token and exact datum.
3. **Forwarding.** `campaign_state` only checks that the payout or admin withdrawal is present, so
   `forwarded` must validate every state input whose redeemer it handles, and nothing may slip
   between the two. The reward accounts can only be registered.
4. **Time and the escrow clock** (`time.ak`, `clock.ak`, `phase.ak`). Phases must hold at both
   bounds of the validity range. Also check the pause rules (rate limit, cooldown, budget,
   guardian takeover, 90-day cap) and the handling of global pause history beyond 16 segments.
5. **Commit chain and reveal** (`allocation.ak`). Check the chain links, strict ordering below the
   lowest committed key, whole-shard batches except the first, the cap and minimum payout, shard
   index continuity, and that the deposit always covers the shards (THREAT_MODEL T11).
6. **Tickets** (`ticket.ak`). The digest is `blake2b_256(serialise_data(ticket))`. Check the
   binding to the registry and the escrow version, single use through the seed input, the owner's
   signature, and the validity window and expiry.
7. **Registry** (`registry.ak`, `registry_rules.ak`). Check the one-shot mint, role separation,
   limits within the hard ceilings, the governance quorum (old and new) for changes, global pause
   segments, and stray sweeping.
8. **Authorisation** (`auth.ak`). Check multisig counting, owners that are scripts (authorised by
   spending one of their own inputs), and privileged keys refused as recipients.
9. **Minting** (`campaign_policy.ak`). A state token is only ever minted by `Create`. `Delegate`
   requires the campaign's state input, and burns happen at cancel, expiry, shard close and
   completion.

Deliberate design decisions, not findings, are listed in
[ESCROW_RULES §9](ESCROW_RULES.md#9-where-the-chains-differ) and
[THREAT_MODEL §2](THREAT_MODEL.md#2-trust-assumptions).

## 5. Build and test

```bash
aikup install v1.1.24
aiken check -D                              # all 172 tests
python3 scripts/test-report.py -t silent    # memory and CPU per test
python3 scripts/gen-math-vectors.py --check
aiken build --trace-level silent && git diff --exit-code plutus.json
```

| Suite | Tests | Covers |
|---|---:|---|
| `validators/campaign_escrow.test.ak` | 78 | the lifecycle: creation and tickets, top-ups, cancel and expiry, commits, finalize, disputes and rejections, reveal, claims, shard closes, completion, pauses, ownership, `Sync`, rescue, minting |
| `validators/registry.test.ak` | 18 | one-shot mint, configuration updates and quorums, global pauses, history, strays |
| `validators/ada_pool.test.ak` | 7 | ADA campaigns (pool and deposit in lovelace) and double satisfaction across two campaigns |
| `validators/budget.test.ak` | 7 | execution budgets of the largest transactions |
| `validators/reputation.test.ak` | 22 | badges: configuration, claims and their refusals (signature, owner, seed, pause, expiry, score, metadata, extra mints), upgrades, revocation, burns, strays |
| `lib/dyma/math_vectors.ak` | 19 | the math vectors shared with the CosmWasm escrow (generated) |
| `lib/dyma/clock.ak` | 10 | the escrow clock, ported from the CosmWasm tests |
| `lib/dyma/allocation.ak`, `math.ak`, `text.ak`, `time.ak`, `holdings.ak` | 11 | unit tests and a property test of the payout bounds |

The test kit (`lib/dyma/testkit.ak`) builds full transactions, with the registry as a reference
input, signatures and validity ranges, and runs the real validators on them. A `fail` test passes
only if the validator rejects the transaction.
