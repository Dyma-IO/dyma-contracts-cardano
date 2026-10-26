# dyma-contracts-cardano

Cardano smart contracts for **Dyma UTXO**, the task-to-earn platform of the UTXO ecosystem: the
**campaign reward escrow** and its **registry**, written in [Aiken](https://aiken-lang.org)
(Plutus V3). They follow the same rules as Dyma's CosmWasm escrow on Safrochain
([ESCROW_RULES.md](docs/ESCROW_RULES.md), shared by both repositories).

> **Status:** 0.1.0, **not audited**. Do not hold third-party funds beyond a small canary before
> an external audit.

| Document | Content |
|---|---|
| [docs/ESCROW_RULES.md](docs/ESCROW_RULES.md) | the rules every Dyma escrow follows, on every chain (byte-identical copy of the CosmWasm repository's) |
| [docs/SPEC.md](docs/SPEC.md) | how Cardano implements them: scripts, data, transitions, time, budgets |
| [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) | trust assumptions, threats, mitigations, residual risks |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | key ceremony, deployment, multisig operations |

## How it works

A project funds a campaign with a ticket signed by Dyma: its pool (ADA or any native token) and a
refundable ADA deposit go into the campaign's **state UTxO**. After the campaign, Dyma's operator
commits the allocation (who earned what), hash-chained in batches, then finalizes it. During the
**challenge window** the owner can dispute and the guardian (a multisig) can reject. Afterwards the
allocation is revealed into **claim shards** of 20 entries; each earner claims its own share with
its wallet. At the claim deadline, what was not claimed goes back to the owner, and Dyma's fee (if
any) is charged once, on what earners actually received.

```
payout_i = min(floor(D · w_i / Σw), cap)        D = pool − fee reserve, cap = D · max_share_bps / 10 000
fee      = floor(paid · fee_bps / 10 000)       charged once, at completion
```

Pauses stop an escrow clock instead of letting deadlines pass; the pauser hot key is rate-limited
and has a freeze budget per campaign; nothing can freeze a pool for more than 90 days.

## Layout

| Path | Purpose |
|---|---|
| `validators/registry.ak` | registry NFT (one-shot) and its configuration: roles, ticket key, treasury, limits, global pauses |
| `validators/campaign_policy.ak` | campaign tokens; creates a campaign from a signed ticket |
| `validators/campaign_state.ak` | campaign state UTxOs: funding, allocation, challenge |
| `validators/campaign_payout.ak` | reveal, shard closes, completion (zero-ADA withdrawal) |
| `validators/campaign_admin.ak` | pauses, ownership, clock checkpoints (zero-ADA withdrawal) |
| `validators/campaign_shard.ak` | claim shards and claims |
| `lib/dyma/` | shared logic: escrow transitions, clock and phases (ports of the CosmWasm `clock.rs` and `phase.rs`), math, tickets, allocations |
| `validators/*.test.ak` | scenarios and execution budgets |
| `fixtures/escrow-math.json` | pro-rata vectors shared with the CosmWasm escrow and Dyma's TypeScript preview |
| `plutus.json` | the blueprint (compiled scripts and data schemas) |

## Build and test

Requirements: Aiken **v1.1.24** (`aikup install v1.1.24`), Python 3, Node.js ≥ 20 (scripts).

```bash
aiken check -D                         # 150 tests: scenarios, shared math vectors, budgets
scripts/test-report.py -t silent       # per-test memory and CPU against the transaction limits
scripts/gen-math-vectors.py --check    # the math tests match fixtures/escrow-math.json
aiken build --trace-level silent       # plutus.json, as deployed
```

## Deployments

| Network | Registry policy | Record |
|---|---|---|
| preprod | to be deployed | `deployments/preprod.json` |
| mainnet | to be deployed after preprod and an audit | `deployments/mainnet.json` |

## License

MIT, see [LICENSE](LICENSE).
