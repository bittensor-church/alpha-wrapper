# End-to-end tests

Pytest scenarios drive a real Subtensor localnet through Foundry, btcli and
Substrate extrinsics. Chainless unit tests cover the Python harness separately.

## Requirements

- Localnet at `ws://127.0.0.1:9944` / `http://127.0.0.1:9944`, funded for the dev
  keys in `alpha_e2e/config.py`.
- `cast` and `forge` on PATH.
- Python dependencies from `e2e/install-deps.sh`, including btcli.
- Keys: the suite keeps its own wallets under `e2e/.wallets`, so btcli wallets
  you already have stay untouched; `ALPHA_E2E_WALLET_PATH` moves that root.
  Bootstrap generates the dev Alice wallet there when it is absent, and stops if
  a different coldkey already holds that name.

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

## Registry variants

The default remains `ValidatorRegistry`. CI also runs each compatible scenario in a
separate job and fresh chain with `--registry-type basic`, deploying
`BasicValidatorRegistry` with the deployer as initial owner. Pytest gives the cases
separate `[attested]` and `[basic]` IDs. To select the Basic full flow:

```bash
python3 -m pytest tests/test_full_flow.py -v -m scenario --registry-type basic
```

Both modes register and fund three hotkeys per subnet. Basic initially configures
only the first as its 100% target, and deposits must use that currently listed key:
`wrap` rejects deposits under unlisted keys. Rotations and parking releases explicitly
choose a sole successor; they submit owner transactions without signing attestations.
The full flow covers deposits under the configured target, observability, both exit
rails, emissions and a real rotation from the sole incumbent to another hotkey.
Basic churn rotates A to B and then B to C, depositing under the current target in
each phase. The min-stake-floor Basic case covers its deposit gate and
rotated-dust consolidation legs; its third leg specifically tests a weighted split
and is inapplicable to one 100% target.

These scenarios remain attested-only:

| Scenario | Why its setup cannot be reproduced with a single recorded validator |
| --- | --- |
| `test_concurrent_swap_recovery.py` | Requires simultaneous unequal balances on multiple recorded hotkeys, then independent swaps before any vault synchronization. |
| `test_shared_recovery_deadline.py` | Requires A and E to disappear while C remains located, then partial recovery of A while E stays missing. |
| `test_recovery_dust.py` | Requires multiple independently lost slots and a third case with one still-located slot to seed movable parking. |
| `test_hostile_dust.py` | Requires a recorded 50/30/20 set with A/B funded and C at zero after a skipped corrective move, then a foreign donation on C and its rotation out. A never-recorded foreign key is not the same case. |
| `test_dust_exit.py` | Requires a refused-dust slot to remain recorded alongside live backing at 9999/1 weights; a Basic rotation consolidates the old slot on the next wrap. |

## Layout and coverage

`alpha_e2e/` contains configuration, address derivation, chain commands,
extrinsics, validator signatures, checks, environment actions and bootstrap.
`conftest.py` switches to the repository root and registers the fixture;
`pytest.ini` configures imports and the `scenario` marker. `chain_ops.py` is the
manual CLI for the same chain operations.

Scenario files in `tests/` cover:

- `test_full_flow.py`: deposits, exits, emissions, rotation and observability.
- `test_transfers_off.py`, `test_convicted_alpha.py`: disabled transfers and locks.
- `test_locked_deposit.py`: poisoned candidates are rejected before deployment
  and a fresh UID creates protected mailboxes and subnet clones that own their
  own hotkeys, so coldkey swaps and locked-alpha transfers into them are refused
  on the real chain; an honest deposit still wraps and exits.
- `test_subnet_dissolved.py`: refunds and mailbox recovery.
- `test_min_stake_floor.py`, `test_dust_dos.py`, `test_min_stake_liveness.py`:
  minimums, top-ups, dust and repeated position changes.
- `test_hostile_dust.py`: third-party stake donations.
- `test_claimable_tao.py`: forced-sale proceeds and holder entitlements.
- `test_parked_stake.py`: a funded hotkey left without an owner; partial exits wait
  for the attesters to replace the name, then the vault claims the key itself.
- `test_parked_recovery.py`: a stranger cuts the trail behind a rename; the watcher
  parks the position, exits pay from the parking hotkey, a new attestation releases.
- `test_concurrent_swap_recovery.py`: two unequal swaps precede recovery; supplying
  only the larger balance cannot change the record, and joint recovery permits a full exit.
- `test_shared_recovery_deadline.py`: a second loss seen at the old deadline gets
  a full new window before write-off. Uses a three-minute constructor window and
  real chain timestamps, including when the first balance returns before expiry.
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

Bootstrap creates three subnets, nine validators, the contracts and funded test
accounts once per scenario process.
