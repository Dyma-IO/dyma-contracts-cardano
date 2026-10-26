#!/usr/bin/env node
// Signs a digest with the test ticket key (Ed25519 seed 0x01 × 32), for lib/dyma/testkit.ak.
// Usage: node scripts/sign-test-ticket.mjs <digest hex>. Never use this key outside tests.
import crypto from 'node:crypto';

const digest = process.argv[2];
if (!/^[0-9a-fA-F]{64}$/.test(digest ?? '')) {
  console.error('usage: sign-test-ticket.mjs <32-byte digest hex>');
  process.exit(1);
}
const seed = Buffer.alloc(32, 1);
const key = crypto.createPrivateKey({
  key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]),
  format: 'der',
  type: 'pkcs8',
});
console.log(crypto.sign(null, Buffer.from(digest, 'hex'), key).toString('hex'));
