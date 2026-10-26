# Runbook: Dyma escrow on Cardano

Procedures for deploying and operating the contracts. Rules: [ESCROW_RULES.md](ESCROW_RULES.md).
Interface: [SPEC.md](SPEC.md). Threats: [THREAT_MODEL.md](THREAT_MODEL.md).

## 1. Keys

| Role | Kind | Holder | Where it is used |
|---|---|---|---|
| Governance | multisig, 3-of-5 on mainnet | hardware wallets of Dyma's directors | registry `UpdateConfig`, global pauses, `Rescue` |
| Guardian | multisig, 2-of-3 | hardware wallets, not the governance keys | reject, resolve, cancel, pause, unpause |
| Operator | payment key | Dyma's API (encrypted credential or AWS KMS Ed25519) | commits, finalize, sync; pays the operator's fees |
| Pauser | payment key | Dyma's API | rate-limited pauses |
| Ticket signer | raw Ed25519 key | Dyma's API | signs campaign tickets off chain |
| Badge attester | raw Ed25519 key | Dyma's API | signs reputation badge attestations off chain |
| Treasury | address | Dyma | receives fees (and plan payments, as a separate account) |
| Deployer | wallet | whoever deploys | pays the deployment; holds nothing afterwards |

- The guardian is never the operator nor the pauser; the operator never receives fees (the
  registry refuses such a configuration).
- On preprod every key may be a software wallet. On mainnet, governance and guardian keys are
  hardware wallets; their **payment key hashes** (not addresses) go into the registry.
- Software keys are 24-word CIP-1852 wallets (importable into Eternl, Lace or Yoroi), stored outside
  any repository with mode 600.

## 2. What a deployment costs

Every script lives on chain once, as a reference script whose UTxO must hold the minimum ADA for its
size (4 310 lovelace per byte). These deposits stay at the registry address, under governance.

| Item | ADA |
|---|---:|
| reference scripts (registry 5.9 KB, policy 5.5 KB, state 14.6 KB, payout 13.1 KB, admin 10.6 KB, shard 9.3 KB) | ≈ 262 |
| registry UTxO (NFT and configuration) | ≈ 5 |
| reward-account registrations of `campaign_payout` and `campaign_admin` | 4 |
| fees (about 8 transactions, up to 16 KB each) | ≈ 6 |
| **total, with margin** | **≈ 300** |

Preprod costs the same in test ADA (Cardano faucet, 10 000 tADA per request).

## 3. Deploying

1. **Configuration**: `deployments/<network>.config.json` lists the role key hashes and thresholds,
   the ticket public key, the treasury address, `max_fee_bps` and the limits (mainnet defaults:
   challenge 1 hour to 7 days, commit window 5 to 90 days, re-commit 3 days, claim window 30 to 365
   days, dispute 3 days, pause 1 day, commit batches of 100).
2. **Build**: `aiken build --trace-level silent` with Aiken v1.1.24; the deployment refuses a
   `plutus.json` that differs from the committed one.
3. **Scripts**: the deployment script picks a seed output of the deployer wallet and applies the
   parameters in order: `registry(seed)`, `campaign_policy(registry)`,
   `campaign_shard(registry, policy)`, `campaign_payout(registry, policy, shard)`,
   `campaign_admin(registry, policy, shard)`, `campaign_state(registry, policy, shard, payout,
   admin)`.
4. **Registry**: the first transaction spends the seed, mints the registry NFT and creates the
   registry UTxO with the configuration (escrow: policy, state and shard script hashes). It carries
   the registry script itself, since no reference exists yet.
5. **Reference scripts**: one transaction per script, each output at the registry address carrying
   the script. Only governance can move them (with an `UpdateConfig`).
6. **Reward accounts**: one transaction registers the reward accounts of `campaign_payout` and
   `campaign_admin`.
7. **Record**: `deployments/<network>.json` gets the network, the seed, every script hash and
   reference UTxO, the registry UTxO and the configuration, after each confirmed step (a re-run
   resumes where the last one stopped); it is committed.
8. **Verify**: read everything back from the chain (scripts by hash, registry datum field by field)
   before Dyma's API is pointed at the record.

```bash
cd scripts/deploy && npm ci
node deploy.mjs --network preprod --wallet <deployer mnemonic file> --plan   # nothing submitted
node deploy.mjs --network preprod --wallet <deployer mnemonic file>
node verify.mjs --network preprod
```

`--plan` prints the script hashes, addresses and deposits, and has a node evaluate the registry
transaction. On mainnet, the deployment also needs `--confirm-mainnet`.

The reputation badges deploy the same way from `deployments/<network>.reputation.config.json`
(governance, attester public key, collection, tiers): `node deploy-reputation.mjs --network preprod
--wallet <deployer mnemonic file> [--plan]` mints the configuration NFT, then stores the script as a
reference script at its own address, and writes `deployments/<network>.reputation.json`.

## 4. Operating

- **Key rotation**: governance signs an `UpdateConfig` with the new operator, pauser or ticket key;
  every campaign uses it immediately. Issued but unused tickets of an old ticket key stop working.
- **New escrow version**: deploy the new scripts (steps 3 to 5), then an `UpdateConfig` points the
  registry's `escrow` at them. Existing campaigns keep their version.
- **Global pause**: the pauser (rate-limited) or the guardian or governance, at most `max_pause_secs`
  at a time. After global pauses, Dyma's API checkpoints open campaigns (`Sync`) so that none
  depends on more than the 16 pauses the registry keeps.
- **Guardian transactions** (reject, resolve, cancel, pause, unpause): Dyma's Admin prepares the
  transaction for the chosen guardian signers (at least the threshold) and shows its CBOR; each
  signer adds a witness, from a CIP-30 wallet in Admin or with `cardano-cli transaction witness`;
  at the threshold Dyma's operator signs as fee payer and submits. Signers have six hours (one
  hour for a pause).
- **Governance transactions** (`UpdateConfig`, `Rescue`): the same witness flow; Admin does not
  build them yet, so they are assembled with the deploy tooling's libraries and `cardano-cli`.
- **Strays**: anything sent by mistake to the escrow or shard addresses leaves with a governance
  `Rescue`; to the registry address, with a governance `UpdateConfig` in the same transaction.

## 5. Incidents

| Situation | Action |
|---|---|
| Operator key suspected | pauser or guardian pauses affected campaigns (or a global pause); governance rotates the operator; the guardian rejects any hostile allocation still in its challenge window |
| Pauser key suspected | governance rotates it; its pauses are bounded by the cooldown and each campaign's budget, and the guardian can lift them |
| Ticket key suspected | governance rotates it (outstanding tickets die with it) |
| Escrow script flaw | governance points the registry at a fixed version for new campaigns; the guardian cancels affected campaigns that are not finalized yet |
