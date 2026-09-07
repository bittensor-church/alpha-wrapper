# End-to-end tests

Pytest scenarios drive a real Subtensor localnet through Foundry, btcli and
Substrate extrinsics. Chainless unit tests cover the Python harness separately.

## Requirements

- Localnet at `ws://127.0.0.1:9944` / `http://127.0.0.1:9944`, funded for the dev
  keys in `alpha_e2e/config.py`.
- `cast` and `forge` on PATH.
- Python dependencies from `e2e/install-deps.sh`, including btcli.

## Run

From the repository root:

```bash
cd e2e
python3 -m pytest tests/test_full_flow.py -v -m scenario
python3 -m pytest tests -v -m "not scenario"
```

Use one scenario module per fresh chain. Modules share subnet and contract state
through the session-scoped `env` fixture; running several against one long-lived
chain is unsupported. CI gives each scenario its own container.

## Layout and coverage

`alpha_e2e/` contains configuration, address derivation, chain commands,
extrinsics, validator signatures, checks, environment actions and bootstrap.
`conftest.py` switches to the repository root and registers the fixture;
`pytest.ini` configures imports and the `scenario` marker. `chain_ops.py` is the
manual CLI for the same chain operations.

Scenario files in `tests/` cover:

- `test_full_flow.py`: deposits, exits, emissions, rotation and observability.
- `test_transfers_off.py`, `test_convicted_alpha.py`: disabled transfers and locks.
- `test_subnet_dissolved.py`: refunds and mailbox recovery.
- `test_min_stake_floor.py`, `test_dust_dos.py`, `test_min_stake_liveness.py`:
  minimums, top-ups, dust and repeated position changes.
- `test_hostile_dust.py`: third-party stake donations.
- `test_claimable_tao.py`: forced-sale proceeds and holder entitlements.
- `test_parked_stake.py`: ownerless parked stake; an unrelated watcher associates
  the hotkey without subnet re-registration, restoring the tested exit.

Each module's docstring describes its sequence. These scenarios exercise specific
recovery conditions, not an unconditional exit guarantee; see the
[design](../docs/hotkey-swaps.md).

Chainless harness tests are `test_substrate.py`, `test_chain_unit.py` and
`test_checks_unit.py`. Bootstrap creates three subnets, nine validators, the
contracts and funded test accounts once per scenario process.
