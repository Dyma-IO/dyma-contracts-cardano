# Scripts

| Script | Purpose | Usage |
|---|---|---|
| [`test-report.py`](test-report.py) | Runs `aiken check` and prints each test's status with its memory and CPU as a share of the per-transaction limits. Exits non-zero if a test fails. | `python3 scripts/test-report.py -t silent [-m <match>]` |
| [`gen-math-vectors.py`](gen-math-vectors.py) | Generates `lib/dyma/math_vectors.ak`, one test per vector of `fixtures/escrow-math.json`, formatted with `aiken fmt`. With `--check`, fails if the committed module differs. | `python3 scripts/gen-math-vectors.py [--check]` |
| [`sign-test-ticket.mjs`](sign-test-ticket.mjs) | Signs a ticket digest with the test key (Ed25519 seed `0x01` × 32), for `lib/dyma/testkit.ak`. Needed only when the test ticket changes. Never use this key outside tests. | `node scripts/sign-test-ticket.mjs <digest hex>` |

Use `-t silent` to measure budgets as deployed: traces add code and cost. The CI budget gate
is `python3 scripts/test-report.py -t silent -m budget`.

## Deployment

[`deploy/`](deploy) is a small Node.js project (Mesh 1.9.1, Koios' public API). Install it with
`npm ci` in that folder.

| Script | Purpose |
|---|---|
| [`deploy/deploy.mjs`](deploy/deploy.mjs) | Deploys the registry, the reference scripts and the reward accounts, and writes `deployments/<network>.json`. `--plan` submits nothing. A re-run resumes an interrupted deployment. |
| [`deploy/verify.mjs`](deploy/verify.mjs) | Reads a deployment back from the chain and checks it against its record. |

The procedure is in [RUNBOOK §3](../docs/RUNBOOK.md#3-deploying).
