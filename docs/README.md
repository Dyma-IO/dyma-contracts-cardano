# Documentation

| Document | Read it to learn |
|---|---|
| [ESCROW_RULES.md](ESCROW_RULES.md) | the rules every Dyma escrow follows, on every chain: roles, tickets, lifecycle, clock, math, limits. It is a byte-identical copy of the CosmWasm repository's file. |
| [SPEC.md](SPEC.md) | how Cardano implements those rules: scripts, data, values, time, every transition, budgets |
| [THREAT_MODEL.md](THREAT_MODEL.md) | what is protected, the trust assumptions, threats and mitigations, residual risks |
| [RUNBOOK.md](RUNBOOK.md) | keys, what a deployment costs, how to deploy, operations and incident response |
| [AUDIT_SCOPE.md](AUDIT_SCOPE.md) | what a security review covers, review priorities, and how to build and test |

Pick a reading order that fits your role:

- **Integrators** (wallets, explorers, indexers): ESCROW_RULES, then SPEC §1–3 and §6, then the
  blueprint `plutus.json` for the exact data encodings.
- **Reviewers and auditors:** ESCROW_RULES, SPEC, THREAT_MODEL, then AUDIT_SCOPE.
- **Operators:** RUNBOOK, with THREAT_MODEL §2 for what each key can do.

## Glossary

| Term | Meaning |
|---|---|
| **Badge** | A Dyma Reputation badge: a CIP-68 reference token at the badge script (its data) and a user token in the owner's wallet. It counts only while the user token sits with the owner. |
| **Allocation** | Who earned what in a campaign: sorted `(key, weight)` entries committed by the operator. |
| **Campaign key** | The 28-byte identifier of a funding attempt: `blake2b_224(serialise_data(seed))`. It names the campaign's tokens. |
| **Challenge window** | The time after finalize during which the owner can dispute and the guardian can reject the allocation. Nothing is paid before it closes. |
| **Claim shard** | A UTxO that holds up to 20 revealed entries and their amounts. Earners claim from it with their own signature. |
| **Commit chain** | Commits are hash-chained from the last batch to the first: `link(entries, next) = blake2b_256(serialise_data(entries) ++ next)`. Reveal replays the batches against the chain. |
| **Deposit** | The refundable ADA the owner locks at creation: one state deposit plus one shard deposit per 20 possible recipients. It always returns to the owner. |
| **Escrow clock** | Campaign time that stops while the campaign is paused. Every deadline after the end runs on it. |
| **Escrow version** | One set of campaign scripts, identified by the state script's hash. Tickets bind it, and the registry names the version for new campaigns. |
| **Guardian** | A multisig that rejects or keeps allocations, cancels before finalize, and pauses or unpauses campaigns. |
| **Governance** | A multisig that changes the registry configuration and rescues stray UTxOs. |
| **Operator** | Dyma's hot key that commits, resets and finalizes allocations. |
| **Pauser** | Dyma's rate-limited hot key that pauses campaigns within a budget. |
| **PayoutTag** | The datum on every owner or treasury output: the spent state's output reference and the role. It prevents double satisfaction. |
| **Reference script** | A script stored once in a UTxO, which transactions use without including its code. |
| **Registry** | The UTxO holding the registry NFT. Its datum is the trust configuration and the global pause history, and every campaign transaction reads it as a reference input. |
| **State UTxO** | A campaign's main UTxO: the state token, the pool, the deposit, and the campaign state as its datum. |
| **Ticket** | Campaign rules signed by Dyma's ticket key, used once to create a campaign. |
| **Validity range** | The `[lower, upper]` time interval of a transaction. Scripts check time against it, not against a block time. |
| **Withdraw zero** | Delegating validation to a script through a zero-ADA withdrawal from its reward account in the same transaction. `campaign_payout` and `campaign_admin` work this way. |
