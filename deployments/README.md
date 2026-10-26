# Deployments

One record per network, committed after each deployment and verified against the chain. The
procedure is in [RUNBOOK §3](../docs/RUNBOOK.md#3-deploying).

| Network | Configuration | Record | Status |
|---|---|---|---|
| Preprod | `preprod.config.json` | `preprod.json` | in preparation |
| Mainnet | `mainnet.config.json` | `mainnet.json` | after preprod |

## Configuration: `<network>.config.json`

The input of a deployment. It holds public values only (key hashes, never keys) and follows the
registry datum's field names (`lib/dyma/types.ak`):

```json
{
  "network": "preprod",
  "governance": { "required": 2, "keys": ["<payment key hash>", "<payment key hash>", "<payment key hash>"] },
  "guardian": { "required": 2, "keys": ["<payment key hash>", "<payment key hash>", "<payment key hash>"] },
  "operator": "<payment key hash>",
  "pauser": "<payment key hash>",
  "ticket_key": "<Ed25519 public key, 32 bytes hex>",
  "treasury": "<address>",
  "max_fee_bps": 1000,
  "limits": {
    "min_challenge_secs": 3600,
    "max_challenge_secs": 604800,
    "min_commit_window_secs": 432000,
    "max_commit_window_secs": 7776000,
    "min_recommit_secs": 259200,
    "min_claim_window_secs": 2592000,
    "max_claim_window_secs": 31536000,
    "dispute_timeout_secs": 259200,
    "max_pause_secs": 86400,
    "max_commit_batch": 100
  }
}
```

The limits shown are the mainnet defaults from the runbook. The registry refuses a configuration
that breaks role separation or exceeds the hard limits of
[ESCROW_RULES §6](../docs/ESCROW_RULES.md#6-hard-limits).

## Record: `<network>.json`

Written by the deployment and committed:

| Field | Content |
|---|---|
| `network` | `preprod` or `mainnet` |
| `status` | `in progress` while steps remain, then `deployed` |
| `commit`, `compiler` | the repository commit and Aiken version that built `plutus.json` |
| `seed` | the output reference that parameterises the registry (spent when its NFT is minted) |
| `registry` | policy id (also the registry script hash), address and current UTxO |
| `scripts` | for each of `registry`, `campaign_policy`, `campaign_state`, `campaign_payout`, `campaign_admin` and `campaign_shard`: hash, size and reference UTxO; the reward accounts of `campaign_payout` and `campaign_admin` |
| `escrow` | the version new campaigns use: `policy`, `state`, `shard` |
| `configuration` | the registry datum as deployed (the configuration above) |
| `transactions` | the hash of every deployment transaction |

Records are written by [`scripts/deploy/deploy.mjs`](../scripts/deploy/deploy.mjs). Before Dyma's
API is pointed at a record, [`scripts/deploy/verify.mjs`](../scripts/deploy/verify.mjs) reads
everything back from the chain: the script hashes against the recorded commit's blueprint, the
reference scripts, the registry UTxO and its datum, and the reward accounts.
