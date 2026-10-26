//// Registry scenarios: the one-shot NFT, configuration updates and the global pause ledger
//// (the CosmWasm factory's `pause` / `unpause` rules).

use cardano/assets
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use dyma/constants.{registry_nft_name}
use dyma/testkit.{
  governor, guardian, operator, out_ref, pauser, paying, registry_address,
  registry_datum, registry_input, registry_policy, registry_value, signed,
  spending, tx_at, wallet_input,
}
use dyma/types.{
  GlobalPause, GlobalSegment, GlobalUnpause, GuardianPause, MultiSig,
  PauserPause, RegistryAction, RegistryDatum, UpdateConfig,
}
use registry

const now: Int = 1_800_000_000_000

const hour: Int = 3_600_000

const day: Int = 86_400_000

fn seed() -> transaction.OutputReference {
  out_ref(#"5eed00", 0)
}

fn registry_output(datum: RegistryDatum) -> Output {
  Output {
    address: registry_address(),
    value: registry_value(),
    datum: InlineDatum(datum),
    reference_script: None,
  }
}

// ## Minting

fn mint_tx(output: Output) -> Transaction {
  let base = tx_at(now)
    |> spending(
        [
          Input {
            output_reference: seed(),
            output: wallet_input(governor(1), 20_000_000).output,
          },
        ],
      )
    |> paying([output])
  Transaction {
    ..base,
    mint: assets.from_asset(registry_policy, registry_nft_name, 1),
  }
}

test mints_the_registry_once() {
  registry.registry.mint(
    seed(),
    Void,
    registry_policy,
    mint_tx(registry_output(registry_datum())),
  )
}

test minting_needs_the_seed() fail {
  registry.registry.mint(
    out_ref(#"0e", 0),
    Void,
    registry_policy,
    mint_tx(registry_output(registry_datum())),
  )
}

test minting_checks_the_configuration() fail {
  let bad = RegistryDatum { ..registry_datum(), max_fee_bps: 1_001 }
  registry.registry.mint(
    seed(),
    Void,
    registry_policy,
    mint_tx(registry_output(bad)),
  )
}

test minting_refuses_the_operator_as_guardian() fail {
  let bad = RegistryDatum {
    ..registry_datum(),
    guardian: MultiSig { required: 1, keys: [operator()] },
  }
  registry.registry.mint(
    seed(),
    Void,
    registry_policy,
    mint_tx(registry_output(bad)),
  )
}

// ## Spending

fn spend(
  current: RegistryDatum,
  action: RegistryAction,
  next: RegistryDatum,
  at: Int,
  signers: List<ByteArray>,
) -> Bool {
  let datum: Data = current
  let input = registry_input(current)
  registry.registry.spend(
    seed(),
    Some(datum),
    action,
    input.output_reference,
    tx_at(at)
      |> spending([input])
      |> paying([registry_output(next)])
      |> signed(signers),
  )
}

test governance_updates_the_configuration() {
  let next = RegistryDatum { ..registry_datum(), max_fee_bps: 500 }
  spend(registry_datum(), UpdateConfig, next, now, [governor(1), governor(3)])
}

test one_governor_is_not_enough() fail {
  let next = RegistryDatum { ..registry_datum(), max_fee_bps: 500 }
  spend(registry_datum(), UpdateConfig, next, now, [governor(1)])
}

test a_new_governance_must_sign_too() fail {
  let next = RegistryDatum {
    ..registry_datum(),
    governance: MultiSig {
      required: 1,
      keys: [#"99999999999999999999999999999999999999999999999999999999"],
    },
  }
  spend(registry_datum(), UpdateConfig, next, now, [governor(1), governor(2)])
}

test updates_never_rewrite_pause_history() fail {
  let next = RegistryDatum {
    ..registry_datum(),
    global_pauses: [
      GlobalSegment {
        start: now - day,
        until: now - hour,
        kind: PauserPause,
        guardian_before: 0,
        pauser_before: 0,
      },
    ],
  }
  spend(registry_datum(), UpdateConfig, next, now, [governor(1), governor(2)])
}

fn paused(segments: List<GlobalSegment>) -> RegistryDatum {
  RegistryDatum { ..registry_datum(), global_pauses: segments }
}

test pauser_starts_a_global_pause() {
  let until = now + 12 * hour
  spend(
    registry_datum(),
    GlobalPause { until },
    paused(
      [
        GlobalSegment {
          start: now,
          until,
          kind: PauserPause,
          guardian_before: 0,
          pauser_before: 0,
        },
      ],
    ),
    now,
    [pauser()],
  )
}

test global_pauses_last_at_most_max_pause() fail {
  let until = now + day + 1
  spend(
    registry_datum(),
    GlobalPause { until },
    paused(
      [
        GlobalSegment {
          start: now,
          until,
          kind: PauserPause,
          guardian_before: 0,
          pauser_before: 0,
        },
      ],
    ),
    now,
    [pauser()],
  )
}

test pauser_cools_down_after_a_pause() fail {
  let earlier = GlobalSegment {
    start: now - 3 * hour,
    until: now - hour,
    kind: GuardianPause,
    guardian_before: 0,
    pauser_before: 0,
  }
  let until = now + hour
  spend(
    paused([earlier]),
    GlobalPause { until },
    paused(
      [
        GlobalSegment {
          start: now,
          until,
          kind: PauserPause,
          guardian_before: 2 * hour,
          pauser_before: 0,
        },
        earlier,
      ],
    ),
    now,
    [pauser()],
  )
}

test pauser_may_pause_again_after_the_cooldown() {
  let earlier = GlobalSegment {
    start: now - 3 * day,
    until: now - 2 * day,
    kind: GuardianPause,
    guardian_before: 0,
    pauser_before: 0,
  }
  let until = now + hour
  spend(
    paused([earlier]),
    GlobalPause { until },
    paused(
      [
        GlobalSegment {
          start: now,
          until,
          kind: PauserPause,
          guardian_before: day,
          pauser_before: 0,
        },
        earlier,
      ],
    ),
    now,
    [pauser()],
  )
}

test guardian_takes_over_a_pauser_pause() {
  let active = GlobalSegment {
    start: now - hour,
    until: now + 5 * hour,
    kind: PauserPause,
    guardian_before: 0,
    pauser_before: 0,
  }
  spend(
    paused([active]),
    GlobalPause { until: now + 2 * hour },
    paused(
      [
        GlobalSegment {
          start: now,
          // Never shortens: the active pause ran until now + 5 h.
          until: now + 5 * hour,
          kind: GuardianPause,
          guardian_before: 0,
          pauser_before: hour,
        },
        GlobalSegment { ..active, until: now },
      ],
    ),
    now,
    [guardian(1), guardian(2)],
  )
}

test guardian_extends_its_pause() {
  let active = GlobalSegment {
    start: now - hour,
    until: now + 2 * hour,
    kind: GuardianPause,
    guardian_before: 0,
    pauser_before: 0,
  }
  spend(
    paused([active]),
    GlobalPause { until: now + 20 * hour },
    paused([GlobalSegment { ..active, until: now + 20 * hour }]),
    now,
    [governor(1), governor(2)],
  )
}

test guardian_lifts_the_global_pause() {
  let active = GlobalSegment {
    start: now - hour,
    until: now + 5 * hour,
    kind: PauserPause,
    guardian_before: 0,
    pauser_before: 0,
  }
  spend(
    paused([active]),
    GlobalUnpause,
    paused([GlobalSegment { ..active, until: now }]),
    now,
    [guardian(2), guardian(3)],
  )
}

test the_pauser_cannot_lift_a_pause() fail {
  let active = GlobalSegment {
    start: now - hour,
    until: now + 5 * hour,
    kind: PauserPause,
    guardian_before: 0,
    pauser_before: 0,
  }
  spend(
    paused([active]),
    GlobalUnpause,
    paused([GlobalSegment { ..active, until: now }]),
    now,
    [pauser()],
  )
}

test history_keeps_the_latest_sixteen_pauses() {
  let old = fn(n) {
    GlobalSegment {
      start: now - ( 40 - n ) * day,
      until: now - ( 40 - n ) * day + hour,
      kind: GuardianPause,
      guardian_before: n * hour,
      pauser_before: 0,
    }
  }
  // Sixteen past guardian pauses, newest first.
  let history = [
    old(15),
    old(14),
    old(13),
    old(12),
    old(11),
    old(10),
    old(9),
    old(8),
    old(7),
    old(6),
    old(5),
    old(4),
    old(3),
    old(2),
    old(1),
    old(0),
  ]
  let until = now + hour
  spend(
    paused(history),
    GlobalPause { until },
    paused(
      [
        GlobalSegment {
          start: now,
          until,
          kind: GuardianPause,
          guardian_before: 16 * hour,
          pauser_before: 0,
        },
        old(15),
        old(14),
        old(13),
        old(12),
        old(11),
        old(10),
        old(9),
        old(8),
        old(7),
        old(6),
        old(5),
        old(4),
        old(3),
        old(2),
        old(1),
      ],
    ),
    now,
    [guardian(1), guardian(3)],
  )
}

test a_stray_utxo_leaves_with_a_governance_update() {
  let stray = Input {
    output_reference: out_ref(#"de", 0),
    output: Output {
      address: registry_address(),
      value: assets.from_lovelace(3_000_000),
      datum: transaction.NoDatum,
      reference_script: None,
    },
  }
  let registry_in = registry_input(registry_datum())
  let redeemer: Data = UpdateConfig
  let base = tx_at(now) |> spending([registry_in, stray])
  registry.registry.spend(
    seed(),
    None,
    UpdateConfig,
    stray.output_reference,
    Transaction {
      ..base,
      redeemers: [
        Pair(transaction.Spend(registry_in.output_reference), redeemer),
      ],
    },
  )
}
