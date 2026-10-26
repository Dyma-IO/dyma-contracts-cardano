# Reputation badge images

One PNG (512 × 512) per Dyma Reputation tier, rendered from the SVG badges Dyma UTXO's API draws
(`/v1/reputation/badges/<tier>.svg`). The badge configuration of a deployment names them, tier by
tier (`deployments/<network>.reputation.config.json`), and every badge copies its tier's image into
its CIP-68 reference datum when it is claimed.

They are PNG rather than SVG because wallets and marketplaces display PNG images everywhere, and
SVG not always. A configuration refers to them by commit, so a badge's image never changes after
it is minted.
