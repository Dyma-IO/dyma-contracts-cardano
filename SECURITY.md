# Security policy

These contracts hold campaign funds, so security reports get our full attention. Thank you for
disclosing responsibly.

## Reporting a vulnerability

Do not open a public issue, discussion or pull request for a security problem. Instead, use one
of these private channels:

- **GitHub:** [report a vulnerability](https://github.com/Dyma-IO/dyma-contracts-cardano/security/advisories/new)
  (private vulnerability reporting). This is the preferred channel.
- **E-mail:** [dymaweb3@gmail.com](mailto:dymaweb3@gmail.com).

A useful report includes:

- the affected scripts and the commit or deployment (`deployments/<network>.json`);
- what goes wrong and what an attacker gains;
- a reproduction, ideally an Aiken test in the style of `validators/*.test.ak`;
- a suggested fix, if you have one.

## What to expect

- We aim to acknowledge a report within 3 business days and to send a first assessment within 10.
- We keep you informed while we work on a fix and agree on a disclosure date with you. Disclosure
  normally follows the fix's deployment.
- With your agreement, we credit you in the advisory and in the changelog.

Please give us reasonable time to fix an issue before you disclose it. Do not exploit a
vulnerability beyond what a proof requires. Never touch funds that are not yours; use preprod
whenever possible.

## Scope

In scope:

- the validators (`validators/*.ak`) and the shared logic (`lib/dyma/`), as compiled in
  `plutus.json`;
- the deployment records in `deployments/`;
- the key and deployment procedures in [docs/RUNBOOK.md](docs/RUNBOOK.md).

Out of scope here: Dyma's web applications and API (report them to the same e-mail address),
third-party wallets, the Cardano node and ledger, social engineering, and denial-of-service attacks
on Dyma's infrastructure.

## Supported versions

| Version | Supported |
|---|---|
| 0.1.x | yes |

## How fixes reach the chain

Cardano scripts are immutable, so a fix is a new escrow version (new script hashes). Depending on
the issue:

- governance points the registry at the fixed version, and new campaigns use it from then on;
- the pauser or the guardian pauses affected campaigns while the fix is prepared;
- the guardian cancels affected campaigns that are not finalized yet, which refunds their owners.

The procedures are in [RUNBOOK §5](docs/RUNBOOK.md#5-incidents). The assumptions and threats
behind them are in [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md), and the review scope is in
[docs/AUDIT_SCOPE.md](docs/AUDIT_SCOPE.md).
