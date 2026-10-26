# Contributing

Thank you for helping improve the Dyma escrow on Cardano. This guide covers the setup, the
workflow and the extra care that smart-contract changes need.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md). Security problems
never go into public issues or pull requests: see [SECURITY.md](SECURITY.md).

## Before you start

- Open an issue, or comment on an existing one, before any large change, and before any change
  to what a validator accepts.
- The escrow rules are shared with Dyma's CosmWasm escrow. A change to
  [docs/ESCROW_RULES.md](docs/ESCROW_RULES.md) or `fixtures/escrow-math.json` must land in both
  repositories, through two linked pull requests merged together, and CI fails while the copies
  differ. Maintainers handle the CosmWasm side.

## Setup

| Tool | Version | For |
|---|---|---|
| [Aiken](https://aiken-lang.org) | v1.1.24 (`aikup install v1.1.24`) | building and testing |
| Python | 3.9 or later | `scripts/test-report.py`, `scripts/gen-math-vectors.py` |
| Node.js | 20 or later | `scripts/sign-test-ticket.mjs` only |

The compiler version is pinned in `aiken.toml`. Another version can produce different scripts.

## Workflow

1. Fork the repository and create a branch from `main`.
2. Make your change with its tests.
3. Run the same checks as CI:

   ```bash
   aiken fmt --check
   aiken check -D
   python3 scripts/gen-math-vectors.py --check
   python3 scripts/test-report.py -t silent -m budget
   aiken build --trace-level silent && git diff --exit-code plutus.json
   ```

4. Open a pull request against `main` and fill in the template.

## Changing a validator

A change to `validators/` or `lib/dyma/` changes the deployed scripts. Check each of these points:

- **Tests.** Each new rule gets a passing test and a `fail` test. A `fail` test must fail for the
  reason it names: drop `fail` for a moment and read the trace.
- **Script sizes.** A transaction is capped at 16 KB and each script is deployed in its own
  transaction, so every compiled validator must stay below about 15.5 KB. Update the sizes in
  [SPEC §1](docs/SPEC.md#1-topology) and in the README.
- **Execution budgets.** The transactions in `validators/budget.test.ak` must stay well inside the
  per-transaction limits. Update [SPEC §8](docs/SPEC.md#8-execution-budget) when they move.
- **Blueprint.** Commit `plutus.json` rebuilt with `aiken build --trace-level silent`.
- **Data types.** The field order in `lib/dyma/types.ak` is part of the on-chain encoding. Never
  reorder fields, and call out any type change in the pull request: off-chain code must follow it.
- **Documents.** Update [SPEC.md](docs/SPEC.md) and [THREAT_MODEL.md](docs/THREAT_MODEL.md)
  when behaviour or assumptions change. Add an entry under `Unreleased` in
  [CHANGELOG.md](CHANGELOG.md): a changed validator means new script hashes, so a new escrow
  version.

## Style

- Format with `aiken fmt`.
- Keep the validators thin: they dispatch to `lib/dyma/`, where the logic lives.
- Times are POSIX milliseconds and durations are seconds, as in the CosmWasm escrow.
- Name things after what they are. Comments explain why, not what.

## Commits and pull requests

- Use [Conventional Commits](https://www.conventionalcommits.org): `feat:`, `fix:`, `docs:`,
  `test:`, `ci:`, `chore:`.
- Keep each pull request to one subject. Its description says what changed, why, and how it was
  tested.
- Never commit keys, mnemonics, `.env` files or other credentials.

## License

Contributions are licensed under the [MIT License](LICENSE), like the rest of the repository.
