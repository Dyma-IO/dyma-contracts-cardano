## Summary

<!-- What changed and why. Link the issue it addresses. -->

## Type of change

- [ ] Bug fix
- [ ] New feature or rule
- [ ] Change to on-chain behaviour (new script hashes)
- [ ] Documentation, tests or tooling only

## Test plan

<!-- The tests you added or changed, and how you verified the change. -->

## Checklist

- [ ] `aiken fmt --check` and `aiken check -D` pass
- [ ] `plutus.json` rebuilt with `aiken build --trace-level silent` (validator changes)
- [ ] Script sizes and execution budgets checked (`python3 scripts/test-report.py -t silent -m budget`), and SPEC updated if they moved
- [ ] `docs/SPEC.md`, `docs/THREAT_MODEL.md` and `CHANGELOG.md` updated where needed
- [ ] Rule changes: linked pull request in the CosmWasm repository, and `docs/ESCROW_RULES.md` and `fixtures/escrow-math.json` identical in both
- [ ] No keys, mnemonics or other secrets
