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
- `test_clone_contamination.py`: a stranger's coldkey swap lands a conviction lock in
  a published deposit address and in the shared subnet clone. The first strands its
  user's deposit; the second lets the stranger mint shares against locked alpha and
  leave with an honest holder's unlocked alpha.
- `test_subnet_dissolved.py`: refunds and mailbox recovery.
- `test_min_stake_floor.py`, `test_dust_dos.py`, `test_min_stake_liveness.py`:
  minimums, top-ups, dust and repeated position changes.
- `test_hostile_dust.py`: third-party stake donations.
- `test_claimable_tao.py`: forced-sale proceeds and holder entitlements.
- `test_parked_stake.py`: a funded hotkey left without an owner; partial exits wait
  for the attesters to replace the name, then the vault claims the key itself.
- `test_parked_recovery.py`: a stranger cuts the trail behind a rename; the watcher
  parks the position, exits pay from the parking hotkey, a new attestation releases.
- `test_parking_isolation.py`: two subnets park on the one parking hotkey; each keeps
  its own balance, the other keeps trading, and each releases on its own attestation.
- `test_subnet_generation.py`: a rewritten registration block leaves the token and its
  exits untouched; dissolving and re-registering the netuid yields a new token.
- `test_dust_exit.py`: on a pool deepened to where most subnets trade, a leftover the
  pool refuses to quote makes the plain TAO exit burn its gas; the exit that excludes
  that slot pays partial and full exits from live backing on a hotkey outside the
  metagraph, which no emissions touch.

Each module's docstring describes its sequence. These scenarios exercise specific
recovery conditions, not an unconditional exit guarantee; see the
[design](../docs/hotkey-swaps.md).

Chainless harness tests are `test_substrate.py`, `test_chain_unit.py`,
`test_checks_unit.py`, `test_environment_unit.py` and `test_plan_tao_exit_unit.py`.
Bootstrap creates three subnets, nine validators, the contracts and funded test
accounts once per scenario process.
