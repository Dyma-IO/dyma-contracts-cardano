# Fixtures

## `escrow-math.json`

The pro-rata vectors shared by every implementation of the Dyma escrow math. Three
implementations check the same vectors: the CosmWasm escrow (where the file comes from), this
repository, and Dyma's TypeScript preview. This file is a byte-identical copy and must not be
edited here: a change starts in the CosmWasm repository and lands in both through linked pull
requests (see [CONTRIBUTING.md](../CONTRIBUTING.md#before-you-start)).

Each vector gives the inputs and the expected results:

| Field | Meaning |
|---|---|
| `name`, `source`, `note` | identifier, origin of the case, and an optional remark (an erratum of the source, for example) |
| `B`, `feeBps`, `fee` | optional: the pool at finalize, the fee rate and the fee reserved at finalize. Without them, `D` is the pool and there is no fee. |
| `D` | distributable amount: `B` minus the fee reserve |
| `weights` | committed weights, in allocation order |
| `capBps`, `cap` | per-earner cap in basis points of `D`, and its value |
| `minPayout` | amounts below it are skipped |
| `amounts` | expected payout per entry, `0` when skipped |
| `skipped` | number of skipped entries |
| `leftover` | what earners are not paid: `D` minus the amounts |
| `feeCharged` | the fee charged at completion, on what earners received |
| `ownerRefund` | what goes back to the owner: the pool minus the amounts and the fee charged |

Amounts are decimal strings, so they are never rounded by a JSON parser.
`scripts/gen-math-vectors.py` turns each vector into an Aiken test (`lib/dyma/math_vectors.ak`),
and CI fails when the generated module is out of date.
