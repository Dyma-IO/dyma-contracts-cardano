// Chain access through Koios' public API (no key needed): protocol parameters with the current
// cost models, UTxOs, evaluation (Koios' Ogmios), submission and confirmations.
import { KoiosProvider } from '@meshsdk/core';

const LANGUAGES = ['PlutusV1', 'PlutusV2', 'PlutusV3'];

export class Koios {
  constructor(network) {
    this.network = network;
    this.base = `https://${network}.koios.rest/api/v1`;
    // Without a token the provider sends no Authorization header (Koios' free tier).
    this.provider = new KoiosProvider(network);
  }

  async request(path, body) {
    for (let attempt = 1; ; attempt += 1) {
      const response = await fetch(`${this.base}${path}`, {
        method: body ? 'POST' : 'GET',
        headers: body ? { 'content-type': 'application/json', accept: 'application/json' } : { accept: 'application/json' },
        body: body ? JSON.stringify(body) : undefined,
      });
      if (response.ok) return response.json();
      if (attempt >= 5 || (response.status < 500 && response.status !== 429)) {
        throw new Error(`Koios ${path}: HTTP ${response.status} ${await response.text()}`);
      }
      await delay(2000 * attempt);
    }
  }

  /** Protocol parameters and the cost models in force (Mesh's built-in ones can be stale). */
  async protocol() {
    const params = await this.provider.fetchProtocolParameters();
    const [epoch] = await this.request(`/epoch_params?_epoch_no=${params.epoch}&select=cost_models`);
    const costModels = LANGUAGES.map((language) => epoch.cost_models[language]);
    if (costModels.some((model) => !Array.isArray(model))) throw new Error('Koios returned no cost models');
    return { params, costModels };
  }

  utxos(address) {
    return this.provider.fetchAddressUTxOs(address);
  }

  async utxoInfo(refs) {
    return this.request('/utxo_info', { _utxo_refs: refs, _extended: true });
  }

  async accountInfo(stakeAddresses) {
    return this.request('/account_info', { _stake_addresses: stakeAddresses });
  }

  /** A transaction's outputs with their assets, inline datums and reference scripts. */
  async txOutputs(txHash) {
    const [info] = await this.request('/tx_info', {
      _tx_hashes: [txHash],
      _inputs: false,
      _metadata: false,
      _assets: true,
      _withdrawals: false,
      _certs: false,
      _scripts: true,
      _bytecode: false,
    });
    if (!info) throw new Error(`Koios does not know transaction ${txHash}`);
    return info.outputs;
  }

  async tip() {
    const [tip] = await this.request('/tip');
    return tip;
  }

  submit(signedTx) {
    return this.provider.submitTx(signedTx);
  }

  /** Waits until the transaction has `confirmations` blocks on top of it. */
  async confirm(txHash, { confirmations = 1, timeoutMs = 15 * 60_000 } = {}) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const [status] = await this.request('/tx_status', { _tx_hashes: [txHash] });
      if ((status?.num_confirmations ?? 0) >= confirmations) return status.num_confirmations;
      await delay(10_000);
    }
    throw new Error(`transaction ${txHash} not confirmed after ${timeoutMs / 60_000} minutes`);
  }
}

export const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
