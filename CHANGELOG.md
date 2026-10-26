# Changelog

This file lists every notable change to this project. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

A change to a validator produces new script hashes. Each released version is therefore a separate
escrow version, which governance can point the registry at for new campaigns. Existing campaigns
keep the version they were created with.

## [Unreleased]

### Added

- Project documentation: contributing guide, security policy, code of conduct, this changelog, a
  documentation index, the audit scope, and issue and pull request templates.
- `scripts/deploy`: a resumable deployment (registry, reference scripts, reward accounts) and a
  verification that reads everything back from the chain.
- Preprod deployment of 0.1.0 (`deployments/preprod.json`).
- `reputation`: Dyma Reputation badges (CIP-68), the counterpart of the CosmWasm `dyma-reputation`:
  a one-shot configuration (governance, Ed25519 attester, tiers), claims from single-use attestations
  signed by Dyma and the owner, upgrades that retire the older badge, revocation by governance.
  22 tests. `scripts/deploy/deploy-reputation.mjs` deploys it.
- `job_escrow`: Dyma Jobs escrow. Pay for a task or for each period of an opportunity is locked per
  job and released to the hired worker with Dyma's approval and the worker's signature, Dyma's fee
  split on chain; the owner withdraws unused funds with Dyma's approval, or alone after expiry.
  55 tests. `scripts/deploy/deploy-jobs.mjs` deploys it.

### Changed

- The shared rules and the threat model name the five campaign scripts instead of a single
  `campaign_escrow`.

## [0.1.0] - 2026-10-26

### Added

- `registry`: one-shot registry NFT and its configuration. It holds the governance and guardian
  multisigs, the operator, pauser and ticket keys, the treasury, the current escrow version, the
  maximum fee and the limits. It also records global pauses, keeping the latest 16.
- `campaign_policy`: campaign creation from an Ed25519-signed, single-use ticket; state and shard
  tokens.
- `campaign_state`: funding, top-ups, cancellation, expiry, hash-chained commits, resets, finalize,
  the challenge window, disputes and rejections.
- `campaign_payout`: reveal into claim shards of 20 entries, shard closes, and completion with the
  fee charged once on what earners received.
- `campaign_admin`: pauses (a rate-limited pauser and the guardian), two-step ownership transfers
  and clock checkpoints.
- `campaign_shard`: claims signed by each earner, and shard closes.
- The escrow clock and phases, ported from the CosmWasm escrow (`clock.rs`, `phase.rs`). The
  pro-rata math is checked against the shared vectors in `fixtures/escrow-math.json`.
- 150 tests: lifecycle scenarios, ADA pools, double satisfaction, the registry, execution budgets
  and the shared math vectors.
- Specification, threat model, runbook and the shared escrow rules.

[Unreleased]: https://github.com/Dyma-IO/dyma-contracts-cardano/compare/83c5d84...main
[0.1.0]: https://github.com/Dyma-IO/dyma-contracts-cardano/commit/83c5d84
