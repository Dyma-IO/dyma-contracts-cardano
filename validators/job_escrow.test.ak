//// Job escrow scenarios: the configuration, funding from a ticket, top-ups, assignment, releases
//// to the worker with Dyma's fee (on top of the reward or out of it), withdrawals, the owner's
//// reclaim after expiry, rescue, and what the script refuses. Tickets and approvals are signed
//// with the test key (seed 0x01 × 32, `ticket_public_key`, scripts/sign-test-ticket.mjs).

use aiken/cbor
use aiken/crypto.{blake2b_256}
use aiken/primitive/bytearray
use cardano/address.{Address}
use cardano/assets.{Assets}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction,
}
use dyma/jobs.{
  Approved, AssignWorker, Burn, Create, Init, JobApproval, JobMint, JobSpend,
  JobState, JobTicket, JobsConfig, Reclaim, ReleasePay, Rescue, TopUp,
  UpdateConfig, WithdrawFunds, config_nft_name, initial_state, job_token,
}
use dyma/testkit.{
  ada, governor, out_ref, owner, owner_key, range, ticket_public_key, treasury,
  usdm, usdm_policy,
}
use dyma/types.{MultiSig}
use job_escrow

const now: Int = 1_800_000_000_000

const hour: Int = 3_600_000

const day: Int = 86_400_000

/// The job escrow's hash (policy id and script address).
const policy: ByteArray =
  #"9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a"

fn param() -> OutputReference {
  out_ref(#"5eed", 0)
}

fn worker() -> ByteArray {
  #"e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1"
}

// ## Configuration

fn config() -> JobsConfig {
  JobsConfig {
    governance: MultiSig {
      required: 2,
      keys: [governor(1), governor(2), governor(3)],
    },
    attester: ticket_public_key,
    treasury: treasury(),
    max_fee_bps: 1_000,
    paused: False,
  }
}

fn script_address() -> Address {
  address.from_script(policy)
}

fn config_input(c: JobsConfig) -> Input {
  Input {
    output_reference: out_ref(#"c0f1", 0),
    output: Output {
      address: script_address(),
      value: assets.from_lovelace(3_000_000)
        |> assets.add(policy, config_nft_name, 1),
      datum: InlineDatum(c),
      reference_script: None,
    },
  }
}

fn wallet(at: OutputReference, holder: ByteArray) -> Input {
  Input {
    output_reference: at,
    output: Output {
      address: address.from_verification_key(holder),
      value: assets.from_lovelace(900_000_000)
        |> assets.add(usdm_policy, "USDM", 900_000_000),
      datum: NoDatum,
      reference_script: None,
    },
  }
}

// ## Tickets and approvals

/// 100 ADA per task, 5% on top, no worker yet.
fn ada_ticket() -> JobTicket {
  JobTicket {
    version: 1,
    policy,
    job_id: "job-ada-1",
    seed: out_ref(#"f00d", 0),
    owner: owner(),
    asset: ada(),
    reward: 100_000_000,
    fee_bps: 500,
    fee_on_top: True,
    worker: None,
    min_funding: 105_000_000,
    deposit: 2_000_000,
    expires_at: now + 90 * day,
    issued_at: now,
    valid_until: now + hour,
  }
}

/// 500 USDM a month, 5% on top, the worker invited from the start.
fn usdm_ticket() -> JobTicket {
  JobTicket {
    ..ada_ticket(),
    job_id: "job-usdm-1",
    seed: out_ref(#"f00d", 1),
    asset: usdm(),
    reward: 500_000_000,
    worker: Some(worker()),
    min_funding: 525_000_000,
  }
}

/// Validly signed, but its worker is the owner.
fn self_hire_ticket() -> JobTicket {
  JobTicket {
    ..ada_ticket(),
    job_id: "job-self-1",
    seed: out_ref(#"f00d", 2),
    worker: Some(owner_key()),
  }
}

fn approval(state: JobState, action: jobs.ApprovedAction) -> JobApproval {
  JobApproval {
    version: 1,
    policy,
    key: state.key,
    nonce: state.nonce,
    action,
    issued_at: now,
    valid_until: now + hour,
  }
}

/// The ADA job as funded (no worker, nonce 0).
fn ada_job() -> JobState {
  initial_state(ada_ticket())
}

/// The ADA job once its worker is hired (nonce 1).
fn ada_hired() -> JobState {
  JobState { ..ada_job(), worker: Some(worker()), nonce: 1 }
}

fn usdm_job() -> JobState {
  initial_state(usdm_ticket())
}

fn hire() -> JobApproval {
  approval(ada_job(), AssignWorker { worker: Some(worker()) })
}

fn release_ada() -> JobApproval {
  approval(ada_hired(), ReleasePay { gross: 100_000_000, close: False })
}

fn release_ada_and_close() -> JobApproval {
  approval(ada_hired(), ReleasePay { gross: 100_000_000, close: True })
}

fn withdraw_some() -> JobApproval {
  approval(ada_hired(), WithdrawFunds { amount: 50_000_000, close: False })
}

fn withdraw_all() -> JobApproval {
  approval(ada_hired(), WithdrawFunds { amount: 210_000_000, close: True })
}

fn release_usdm() -> JobApproval {
  approval(usdm_job(), ReleasePay { gross: 500_000_000, close: False })
}

fn release_usdm_and_close() -> JobApproval {
  approval(usdm_job(), ReleasePay { gross: 500_000_000, close: True })
}

// Signatures of the fixtures above (regenerate with `print_digests` and the signing script).

const ada_ticket_sig: ByteArray =
  #"84c3c5e46fbe2e07fe0b636f706bdbb77f8273b857462616351d97ccb8daddf7d0e49e95a1dc69ae67ce93778f7e0bd23d1475e312b5e5e3a50fa6c9ae478208"

const usdm_ticket_sig: ByteArray =
  #"b5565ff41e2176dbe4e32d083dbe78d76360ac632c48308e8480259d999cdff05e52646eb8eb0231839ee318edbfadc943b2dc842ce8d4909eb4ecf48c2e9f0b"

const self_hire_ticket_sig: ByteArray =
  #"dda3ecf964fa82797b857548603b699b98783448683e11d0438066fba416a38a1e91751dcdaa4e59c37619f13804dbca7cb3ad5089d938dae1679c92045d9d00"

const hire_sig: ByteArray =
  #"a63ee0a8f5b304454b6ed45b5a3d22d309c2514117fcee5004ba93adab7248830f6170f2a9ab8d46a7359e96bc1e2b17c5b1c51a500a79c0b2bf223c4e2e0f0a"

const release_ada_sig: ByteArray =
  #"dd85b1e7a0c0edbaa6b830860f4642bc57ffdd96780c9149942b27eb1484bf0c8c2b628a39ebe33cf7e00d32eba77ef5259451aa80b4bd050790dbba3da52f00"

const release_ada_and_close_sig: ByteArray =
  #"f6bb5e618949b5310d73274bcd94749f62305417fcd8c1cbb877334079b4c43d7f96239729e967b88e4247da318dad4179b1d4540c792d25038ed546f8c34e07"

const withdraw_some_sig: ByteArray =
  #"37295b0ea1b1037bc45be11cb967cab5020f5b862840b4c88c5e1900a151de9dcfcc44d194b0208c7bf89b704cdccdf1b4eb00e64b0e2a7a54a0c87a959f4301"

const withdraw_all_sig: ByteArray =
  #"116f3913f1d0928320c8e0299d11e3733eccbfb2aea5e23eeb4c41c7d792140e8a27ae65b5ca247b04a8d1b9faf8aaa51502fde57b8490a81795cdd7d7dcbe03"

const release_usdm_sig: ByteArray =
  #"b5de9d421a3c0be25c8ff2fa56a33c918e68ebd5cc66e0b3ed4574073bcc9e625e0f3ea0f471947b121a73044aeda615a874b7de235d63005a05301d16e4840b"

const release_usdm_and_close_sig: ByteArray =
  #"a8deed0f28653177676f5dd78c4dafe54665fde4a3dbfba32b27620c7676b4035beea2991853a12a8dd2c1ec9f3a0a8f1ea2b738864712af264ebd93cc481a01"

fn digest(data: Data) -> ByteArray {
  blake2b_256(cbor.serialise(data))
}

/// Prints what the test key must sign when a fixture changes (`aiken check -t verbose`).
test print_digests() {
  let show = fn(label: String, data: Data) {
    trace label: bytearray.to_hex(digest(data))
    True
  }
  and {
    show(@"ada_ticket", ada_ticket()),
    show(@"usdm_ticket", usdm_ticket()),
    show(@"self_hire_ticket", self_hire_ticket()),
    show(@"hire", hire()),
    show(@"release_ada", release_ada()),
    show(@"release_ada_and_close", release_ada_and_close()),
    show(@"withdraw_some", withdraw_some()),
    show(@"withdraw_all", withdraw_all()),
    show(@"release_usdm", release_usdm()),
    show(@"release_usdm_and_close", release_usdm_and_close()),
  }
}

// ## Transactions

fn to_key(key: ByteArray, value: Assets) -> Output {
  Output {
    address: address.from_verification_key(key),
    value,
    datum: NoDatum,
    reference_script: None,
  }
}

fn to_address(at: Address, value: Assets) -> Output {
  Output { address: at, value, datum: NoDatum, reference_script: None }
}

fn usdm_value(amount: Int, lovelace: Int) -> Assets {
  assets.from_lovelace(lovelace) |> assets.add(usdm_policy, "USDM", amount)
}

fn job_value(state: JobState, pool: Int) -> Assets {
  let token = assets.from_asset(policy, job_token(state.key), 1)
  if state.asset.policy == "" {
    assets.merge(token, assets.from_lovelace(state.deposit + pool))
  } else {
    assets.merge(token, usdm_value(pool, state.deposit))
  }
}

fn job_output(state: JobState, pool: Int) -> Output {
  Output {
    address: script_address(),
    value: job_value(state, pool),
    datum: InlineDatum(state),
    reference_script: None,
  }
}

fn job_ref() -> OutputReference {
  out_ref(#"10b0", 0)
}

fn job_input(state: JobState, pool: Int) -> Input {
  Input { output_reference: job_ref(), output: job_output(state, pool) }
}

fn ten_minutes_from(at: Int) {
  range(at, at + 600_000)
}

fn job_tx(
  input: Input,
  outputs: List<Output>,
  signers: List<ByteArray>,
  c: JobsConfig,
) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    inputs: [
      input,
      wallet(
        out_ref(#"fee0", 0),
        #"a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1",
      ),
    ],
    reference_inputs: [config_input(c)],
    outputs,
    extra_signatories: signers,
    validity_range: ten_minutes_from(now),
  }
}

fn burn_of(state: JobState) -> Assets {
  assets.from_asset(policy, job_token(state.key), -1)
}

fn spend(state: JobState, redeemer: JobSpend, tx: Transaction) -> Bool {
  let datum: Data = state
  job_escrow.job_escrow.spend(param(), Some(datum), redeemer, job_ref(), tx)
}

fn mint(redeemer: JobMint, tx: Transaction) -> Bool {
  job_escrow.job_escrow.mint(param(), redeemer, policy, tx)
}

// ## Configuration

fn init_tx(c: JobsConfig, seed: OutputReference) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    inputs: [wallet(seed, governor(1))],
    outputs: [config_input(c).output],
    mint: assets.from_asset(policy, config_nft_name, 1),
  }
}

test mints_the_configuration_once() {
  mint(Init, init_tx(config(), param()))
}

test the_configuration_needs_its_seed() fail {
  mint(Init, init_tx(config(), out_ref(#"07e2", 0)))
}

test the_fee_cap_is_at_most_ten_percent() fail {
  mint(Init, init_tx(JobsConfig { ..config(), max_fee_bps: 1_001 }, param()))
}

fn update_tx(next: JobsConfig, signers: List<ByteArray>) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    inputs: [config_input(config())],
    outputs: [config_input(next).output],
    extra_signatories: signers,
  }
}

fn update(next: JobsConfig, signers: List<ByteArray>) -> Bool {
  let datum: Data = config()
  job_escrow.job_escrow.spend(
    param(),
    Some(datum),
    UpdateConfig,
    config_input(config()).output_reference,
    update_tx(next, signers),
  )
}

test governance_pauses_the_escrow() {
  update(JobsConfig { ..config(), paused: True }, [governor(1), governor(3)])
}

test one_governor_cannot_change_the_configuration() fail {
  update(JobsConfig { ..config(), paused: True }, [governor(1)])
}

// ## Funding

fn create_tx(
  ticket: JobTicket,
  pool: Int,
  signers: List<ByteArray>,
  c: JobsConfig,
) -> Transaction {
  let state = initial_state(ticket)
  Transaction {
    ..transaction.placeholder,
    inputs: [wallet(ticket.seed, owner_key())],
    reference_inputs: [config_input(c)],
    outputs: [job_output(state, pool)],
    mint: assets.from_asset(policy, job_token(state.key), 1),
    extra_signatories: signers,
    validity_range: ten_minutes_from(now),
  }
}

fn create(ticket: JobTicket, signature: ByteArray, tx: Transaction) -> Bool {
  mint(Create { ticket, signature }, tx)
}

test funds_an_ada_task() {
  create(
    ada_ticket(),
    ada_ticket_sig,
    create_tx(ada_ticket(), 105_000_000, [owner_key()], config()),
  )
}

test funds_two_usdm_periods_with_the_worker_invited() {
  create(
    usdm_ticket(),
    usdm_ticket_sig,
    create_tx(usdm_ticket(), 1_050_000_000, [owner_key()], config()),
  )
}

test funding_needs_dymas_signature() fail {
  create(
    ada_ticket(),
    usdm_ticket_sig,
    create_tx(ada_ticket(), 105_000_000, [owner_key()], config()),
  )
}

test funding_needs_the_owner() fail {
  create(
    ada_ticket(),
    ada_ticket_sig,
    create_tx(ada_ticket(), 105_000_000, [], config()),
  )
}

test funding_spends_the_tickets_seed() fail {
  let tx = create_tx(ada_ticket(), 105_000_000, [owner_key()], config())
  create(
    ada_ticket(),
    ada_ticket_sig,
    Transaction { ..tx, inputs: [wallet(out_ref(#"07e2", 0), owner_key())] },
  )
}

test funding_below_the_minimum_fails() fail {
  create(
    ada_ticket(),
    ada_ticket_sig,
    create_tx(ada_ticket(), 104_999_999, [owner_key()], config()),
  )
}

test a_paused_escrow_takes_no_new_job() fail {
  create(
    ada_ticket(),
    ada_ticket_sig,
    create_tx(
      ada_ticket(),
      105_000_000,
      [owner_key()],
      JobsConfig { ..config(), paused: True },
    ),
  )
}

test the_fee_cannot_exceed_the_cap() fail {
  create(
    ada_ticket(),
    ada_ticket_sig,
    create_tx(
      ada_ticket(),
      105_000_000,
      [owner_key()],
      JobsConfig { ..config(), max_fee_bps: 400 },
    ),
  )
}

test the_owner_cannot_hire_themselves() fail {
  create(
    self_hire_ticket(),
    self_hire_ticket_sig,
    create_tx(self_hire_ticket(), 105_000_000, [owner_key()], config()),
  )
}

test an_expired_ticket_funds_nothing() fail {
  let tx = create_tx(ada_ticket(), 105_000_000, [owner_key()], config())
  create(
    ada_ticket(),
    ada_ticket_sig,
    Transaction { ..tx, validity_range: ten_minutes_from(now + 2 * hour) },
  )
}

test the_job_datum_is_the_tickets() fail {
  let tx = create_tx(ada_ticket(), 105_000_000, [owner_key()], config())
  let tampered = JobState { ..ada_job(), fee_bps: 0 }
  create(
    ada_ticket(),
    ada_ticket_sig,
    Transaction { ..tx, outputs: [job_output(tampered, 105_000_000)] },
  )
}

test the_job_utxo_holds_nothing_else() fail {
  let tx = create_tx(ada_ticket(), 105_000_000, [owner_key()], config())
  let output = job_output(ada_job(), 105_000_000)
  create(
    ada_ticket(),
    ada_ticket_sig,
    Transaction {
      ..tx,
      outputs: [
        Output { ..output, value: assets.add(output.value, #"0102", "junk", 1) },
      ],
    },
  )
}

// ## Top-ups

fn top_up_tx(pool_after: Int, expires_at: Int, signers: List<ByteArray>) {
  job_tx(
    job_input(ada_hired(), 105_000_000),
    [job_output(JobState { ..ada_hired(), expires_at }, pool_after)],
    signers,
    config(),
  )
}

test the_owner_locks_another_period_and_extends_the_job() {
  let later = now + 120 * day
  spend(
    ada_hired(),
    TopUp { expires_at: later },
    top_up_tx(210_000_000, later, [owner_key()]),
  )
}

test a_top_up_never_shortens_the_job() fail {
  let sooner = now + 30 * day
  spend(
    ada_hired(),
    TopUp { expires_at: sooner },
    top_up_tx(210_000_000, sooner, [owner_key()]),
  )
}

test a_top_up_never_takes_funds() fail {
  let same = ada_hired().expires_at
  spend(
    ada_hired(),
    TopUp { expires_at: same },
    top_up_tx(100_000_000, same, [owner_key()]),
  )
}

test only_the_owner_tops_up() fail {
  let same = ada_hired().expires_at
  spend(
    ada_hired(),
    TopUp { expires_at: same },
    top_up_tx(210_000_000, same, [worker()]),
  )
}

// ## Hiring

fn hire_tx(
  state: JobState,
  output: Output,
  signers: List<ByteArray>,
  c: JobsConfig,
) {
  job_tx(job_input(state, 105_000_000), [output], signers, c)
}

fn hired_output() -> Output {
  job_output(ada_hired(), 105_000_000)
}

test the_owner_hires_with_dymas_approval() {
  spend(
    ada_job(),
    Approved { approval: hire(), signature: hire_sig },
    hire_tx(ada_job(), hired_output(), [owner_key()], config()),
  )
}

test hiring_needs_the_owner() fail {
  spend(
    ada_job(),
    Approved { approval: hire(), signature: hire_sig },
    hire_tx(ada_job(), hired_output(), [], config()),
  )
}

test an_approval_names_the_current_nonce() fail {
  let moved_on = JobState { ..ada_job(), nonce: 3 }
  spend(
    moved_on,
    Approved { approval: hire(), signature: hire_sig },
    hire_tx(
      moved_on,
      job_output(JobState { ..ada_hired(), nonce: 4 }, 105_000_000),
      [owner_key()],
      config(),
    ),
  )
}

test an_approval_expires() fail {
  let tx = hire_tx(ada_job(), hired_output(), [owner_key()], config())
  spend(
    ada_job(),
    Approved { approval: hire(), signature: hire_sig },
    Transaction { ..tx, validity_range: ten_minutes_from(now + hour) },
  )
}

test a_paused_escrow_hires_nobody() fail {
  spend(
    ada_job(),
    Approved { approval: hire(), signature: hire_sig },
    hire_tx(
      ada_job(),
      hired_output(),
      [owner_key()],
      JobsConfig { ..config(), paused: True },
    ),
  )
}

test hiring_moves_no_money() fail {
  spend(
    ada_job(),
    Approved { approval: hire(), signature: hire_sig },
    hire_tx(
      ada_job(),
      job_output(ada_hired(), 104_000_000),
      [owner_key()],
      config(),
    ),
  )
}

// ## Releases

/// What the worker's claim of one ADA task pays, from a pool of `pool`.
fn release_ada_tx(
  pool: Int,
  worker_gets: Int,
  fee: Int,
  signers: List<ByteArray>,
) {
  let next = JobState {
    ..ada_hired(),
    nonce: 2,
    released: worker_gets,
    fees_paid: fee,
  }
  job_tx(
    job_input(ada_hired(), pool),
    [
      to_key(worker(), assets.from_lovelace(worker_gets)),
      to_address(treasury(), assets.from_lovelace(fee)),
      job_output(next, pool - worker_gets - fee),
    ],
    signers,
    config(),
  )
}

fn release(state: JobState, approval: JobApproval, signature: ByteArray, tx) {
  spend(state, Approved { approval, signature }, tx)
}

test the_worker_claims_an_approved_task() {
  release(
    ada_hired(),
    release_ada(),
    release_ada_sig,
    release_ada_tx(210_000_000, 100_000_000, 5_000_000, [worker()]),
  )
}

test a_release_needs_the_workers_signature() fail {
  release(
    ada_hired(),
    release_ada(),
    release_ada_sig,
    release_ada_tx(210_000_000, 100_000_000, 5_000_000, [owner_key()]),
  )
}

test the_worker_gets_the_whole_reward() fail {
  release(
    ada_hired(),
    release_ada(),
    release_ada_sig,
    release_ada_tx(210_000_000, 99_000_000, 6_000_000, [worker()]),
  )
}

test dyma_gets_its_whole_fee() fail {
  let tx = release_ada_tx(210_000_000, 100_000_000, 5_000_000, [worker()])
  expect [to_worker, _, rest] = tx.outputs
  release(
    ada_hired(),
    release_ada(),
    release_ada_sig,
    Transaction {
      ..tx,
      outputs: [
        to_worker,
        to_address(treasury(), assets.from_lovelace(4_999_999)),
        rest,
      ],
    },
  )
}

test the_fee_goes_to_the_treasury() fail {
  let tx = release_ada_tx(210_000_000, 100_000_000, 5_000_000, [worker()])
  expect [to_worker, _, rest] = tx.outputs
  release(
    ada_hired(),
    release_ada(),
    release_ada_sig,
    Transaction {
      ..tx,
      outputs: [
        to_worker,
        to_key(owner_key(), assets.from_lovelace(5_000_000)),
        rest,
      ],
    },
  )
}

test a_release_pays_the_hired_worker_only() fail {
  let tx = release_ada_tx(210_000_000, 100_000_000, 5_000_000, [worker()])
  expect [_, fee, rest] = tx.outputs
  release(
    ada_hired(),
    release_ada(),
    release_ada_sig,
    Transaction {
      ..tx,
      outputs: [
        to_key(owner_key(), assets.from_lovelace(100_000_000)),
        fee,
        rest,
      ],
    },
  )
}

test a_release_cannot_overdraw() fail {
  release(
    ada_hired(),
    release_ada(),
    release_ada_sig,
    release_ada_tx(104_999_999, 100_000_000, 5_000_000, [worker()]),
  )
}

test an_approval_works_once() fail {
  let after = JobState { ..ada_hired(), nonce: 2 }
  let tx = release_ada_tx(210_000_000, 100_000_000, 5_000_000, [worker()])
  release(
    after,
    release_ada(),
    release_ada_sig,
    Transaction { ..tx, inputs: [job_input(after, 210_000_000)] },
  )
}

test no_release_without_a_hired_worker() fail {
  let nobody = JobState { ..ada_hired(), worker: None }
  let tx = release_ada_tx(210_000_000, 100_000_000, 5_000_000, [worker()])
  release(
    nobody,
    release_ada(),
    release_ada_sig,
    Transaction { ..tx, inputs: [job_input(nobody, 210_000_000)] },
  )
}

test one_job_per_transaction() fail {
  let tx = release_ada_tx(210_000_000, 100_000_000, 5_000_000, [worker()])
  let other = Input {
    output_reference: out_ref(#"10b1", 0),
    output: job_output(usdm_job(), 525_000_000),
  }
  release(
    ada_hired(),
    release_ada(),
    release_ada_sig,
    Transaction { ..tx, inputs: [other, ..tx.inputs] },
  )
}

fn close_ada_tx(pool: Int, mint: Assets) {
  job_tx(
    job_input(ada_hired(), pool),
    [
      to_key(worker(), assets.from_lovelace(100_000_000)),
      to_address(treasury(), assets.from_lovelace(5_000_000)),
      to_key(owner_key(), assets.from_lovelace(2_000_000)),
    ],
    [worker()],
    config(),
  )
    |> fn(tx) { Transaction { ..tx, mint } }
}

test the_last_release_closes_the_job_and_refunds_the_deposit() {
  release(
    ada_hired(),
    release_ada_and_close(),
    release_ada_and_close_sig,
    close_ada_tx(105_000_000, burn_of(ada_hired())),
  )
}

test closing_needs_an_empty_pool() fail {
  release(
    ada_hired(),
    release_ada_and_close(),
    release_ada_and_close_sig,
    close_ada_tx(210_000_000, burn_of(ada_hired())),
  )
}

test closing_burns_the_job_token() fail {
  release(
    ada_hired(),
    release_ada_and_close(),
    release_ada_and_close_sig,
    close_ada_tx(105_000_000, assets.zero),
  )
}

/// One month of a USDM opportunity: Dyma pays the ADA the token outputs need.
fn release_usdm_tx(state: JobState, pool: Int, worker_gets: Int, fee: Int) {
  let next = JobState {
    ..state,
    nonce: 1,
    released: worker_gets,
    fees_paid: fee,
  }
  job_tx(
    job_input(state, pool),
    [
      to_key(worker(), usdm_value(worker_gets, 1_200_000)),
      to_address(treasury(), usdm_value(fee, 1_200_000)),
      job_output(next, pool - worker_gets - fee),
    ],
    [worker()],
    config(),
  )
}

test the_worker_claims_a_usdm_period() {
  release(
    usdm_job(),
    release_usdm(),
    release_usdm_sig,
    release_usdm_tx(usdm_job(), 1_050_000_000, 500_000_000, 25_000_000),
  )
}

test the_fee_can_come_out_of_the_reward() {
  let inclusive = JobState { ..usdm_job(), fee_on_top: False }
  release(
    inclusive,
    release_usdm(),
    release_usdm_sig,
    release_usdm_tx(inclusive, 1_050_000_000, 475_000_000, 25_000_000),
  )
}

test the_last_usdm_period_closes_the_job() {
  let tx = job_tx(
    job_input(usdm_job(), 525_000_000),
    [
      to_key(worker(), usdm_value(500_000_000, 1_200_000)),
      to_address(treasury(), usdm_value(25_000_000, 1_200_000)),
      to_key(owner_key(), assets.from_lovelace(2_000_000)),
    ],
    [worker()],
    config(),
  )
  release(
    usdm_job(),
    release_usdm_and_close(),
    release_usdm_and_close_sig,
    Transaction { ..tx, mint: burn_of(usdm_job()) },
  )
}

// ## Withdrawals and reclaim

test the_owner_takes_back_unused_funds() {
  let next = JobState { ..ada_hired(), nonce: 2 }
  release(
    ada_hired(),
    withdraw_some(),
    withdraw_some_sig,
    job_tx(
      job_input(ada_hired(), 210_000_000),
      [
        to_key(owner_key(), assets.from_lovelace(50_000_000)),
        job_output(next, 160_000_000),
      ],
      [owner_key()],
      config(),
    ),
  )
}

test a_withdrawal_needs_the_owner() fail {
  let next = JobState { ..ada_hired(), nonce: 2 }
  release(
    ada_hired(),
    withdraw_some(),
    withdraw_some_sig,
    job_tx(
      job_input(ada_hired(), 210_000_000),
      [
        to_key(owner_key(), assets.from_lovelace(50_000_000)),
        job_output(next, 160_000_000),
      ],
      [worker()],
      config(),
    ),
  )
}

fn withdraw_all_tx(pool: Int) {
  let tx = job_tx(
    job_input(ada_hired(), pool),
    [to_key(owner_key(), assets.from_lovelace(212_000_000))],
    [owner_key()],
    config(),
  )
  Transaction { ..tx, mint: burn_of(ada_hired()) }
}

test withdrawing_everything_closes_the_job() {
  release(
    ada_hired(),
    withdraw_all(),
    withdraw_all_sig,
    withdraw_all_tx(210_000_000),
  )
}

test a_withdrawal_cannot_overdraw() fail {
  release(
    ada_hired(),
    withdraw_all(),
    withdraw_all_sig,
    withdraw_all_tx(200_000_000),
  )
}

fn reclaim_tx(at: Int, signers: List<ByteArray>, c: JobsConfig) {
  let tx = job_tx(
    job_input(ada_hired(), 105_000_000),
    [to_key(owner_key(), assets.from_lovelace(107_000_000))],
    signers,
    c,
  )
  Transaction {
    ..tx,
    mint: burn_of(ada_hired()),
    validity_range: ten_minutes_from(at),
  }
}

test the_owner_reclaims_everything_after_expiry() {
  spend(
    ada_hired(),
    Reclaim,
    reclaim_tx(now + 91 * day, [owner_key()], config()),
  )
}

test the_reclaim_works_while_paused() {
  spend(
    ada_hired(),
    Reclaim,
    reclaim_tx(
      now + 91 * day,
      [owner_key()],
      JobsConfig { ..config(), paused: True },
    ),
  )
}

test no_reclaim_before_expiry() fail {
  spend(
    ada_hired(),
    Reclaim,
    reclaim_tx(now + 89 * day, [owner_key()], config()),
  )
}

test only_the_owner_reclaims() fail {
  spend(ada_hired(), Reclaim, reclaim_tx(now + 91 * day, [worker()], config()))
}

// ## Rescue and burning

fn stray() -> Input {
  Input {
    output_reference: job_ref(),
    output: to_address(script_address(), assets.from_lovelace(7_000_000)),
  }
}

test governance_rescues_what_was_sent_by_mistake() {
  job_escrow.job_escrow.spend(
    param(),
    None,
    Rescue,
    job_ref(),
    job_tx(
      stray(),
      [to_key(governor(1), assets.from_lovelace(7_000_000))],
      [governor(1), governor(2)],
      config(),
    ),
  )
}

test governance_cannot_take_a_job() fail {
  spend(
    ada_hired(),
    Rescue,
    job_tx(
      job_input(ada_hired(), 105_000_000),
      [to_key(governor(1), assets.from_lovelace(107_000_000))],
      [governor(1), governor(2)],
      config(),
    ),
  )
}

test burning_never_touches_the_configuration() fail {
  mint(
    Burn,
    Transaction {
      ..transaction.placeholder,
      mint: assets.from_asset(policy, config_nft_name, -1),
    },
  )
}
