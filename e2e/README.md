# e2e

Real-chain end-to-end tests for the alpha-wrapper vault. A pytest suite that
drives a live localnet through cast/forge/btcli subprocess calls and
substrate extrinsics -- deposits, unwraps on both rails, floor handling,
dust and hostility scenarios, subnet dissolution, and the observability
scripts.

## Prerequisites

- A running localnet subtensor at `ws://127.0.0.1:9944` (RPC at
  `http://127.0.0.1:9944`), pre-funded with the well-known dev keys in
  `alpha_e2e/config.py`.
- `btcli` and `cast`/`forge` (Foundry) on `PATH`.
- Python deps installed via `e2e/install-deps.sh` (CI runs the same script).

## How to run

From the repo root:

```bash
cd e2e

# One scenario against a fresh localnet:
python3 -m pytest tests/test_full_flow.py -v -m scenario

# All chainless unit tests (no chain required):
python3 -m pytest tests -v -m "not scenario"
```

`pytest.ini` sets `testpaths = tests` and registers the `scenario` marker
(a full localnet scenario -- slow, needs a running chain). Tests without that
marker are pure-Python unit tests (address derivation, cast-output parsing,
assertion helpers) and run with no chain at all.

**IMPORTANT:** scenario modules are designed for one-module-per-fresh-chain.
CI runs each `tests/test_*.py` scenario as its own matrix job against its own
subtensor container. Running multiple scenario modules in a single pytest
invocation against one long-lived localnet is not supported -- they share
chain and contract state (netuids, token ids, alpha price) via the session
`env` fixture, and a later module's assumptions about that state will not
hold if an earlier module already mutated the chain.

## Layout

`alpha_e2e/` -- the framework package:

- `config.py` -- localnet dev constants (RPC/chain endpoints, dev keys, gas
  budgets, rounding-dust tolerances).
- `substrate.py` -- pure-Python substrate address derivation (blake2b
  HashedAddressMapping, SS58) and wallet-file readers.
- `chain.py` -- typed subprocess wrappers over `cast`/`forge`/`btcli`.
- `extrinsics.py` -- substrate extrinsics signed by the dev Alice key (stake
  transfers and sales, conviction locks, sudo toggles, subnet dissolution);
  failures raise with the chain's decoded module error.
- `validators.py` -- EIP-712 validator-set attestations for the
  ValidatorRegistry.
- `checks.py` -- shared assertion helpers (gas budgets, quote-based payout
  checks, CSV invariants over the observability scripts).
- `environment.py` -- the `Environment` dataclass: on-chain getters and typed
  actions (`deposit_and_wrap`, `vault_send`, `assert_vault_reverts_with`,
  `set_validators`, `crash_price_until_below`, ...) every scenario drives.
- `bootstrap.py` -- `build_environment()`: one-time localnet setup (subnets,
  validators, staking, contract deploy, funding), pre-flight + Phases 0-5.
- `fixtures.py` -- the session-scoped `env` pytest fixture wrapping
  `bootstrap.build_environment()`.

`pytest.ini` puts the package on the import path (`pythonpath = .`);
`conftest.py` `chdir`s to the repo root (so `cast`/`forge` and the
observability scripts see repo-relative paths like `src/...`) and registers
the `env` fixture plugin. `chain_ops.py` is a standalone CLI over the same
chain operations, kept for manual localnet work.

## Scenarios

One module per scenario (each expects its own fresh localnet); the module
docstring in each file carries the full phase-by-phase description.

- `test_full_flow.py` -- the main flow: deposits split across 3 validators on
  3 subnets, full alpha unwraps, both TAO-rail exits, emission accrual,
  validator rotation, the TAO-exit slippage guard, and every observability
  script asserted row-by-row.
- `test_transfers_off.py` -- subnet alpha transfers disabled: the alpha rail
  reverts with shares intact, both TAO rails still pay out on quote.
- `test_convicted_alpha.py` -- conviction-locked alpha: over-movable deposits
  refused on-chain, the movable portion wraps, unwraps to a lock-holding
  coldkey and TAO exits leave lock state untouched.
- `test_subnet_dissolved.py` -- a dissolved subnet: dissolved unwrap and
  mailbox reclaim recover native TAO pro-rata, alpha rails revert, an
  untouched subnet is unaffected.
- `test_min_stake_floor.py` -- min-stake floor handling: the wrap gate refuses
  a sub-floor deposit in-budget, rotated-out dust is consolidated by the next
  wrap, sub-floor rebalance moves are skipped in-budget.
- `test_dust_dos.py` -- dust lockout: rotated-out dust, a price crash, and a
  sub-floor co-holder all refuse cheaply with designed errors while the TAO
  exit, top-ups, and fresh deposits clear them.
- `test_hostile_dust.py` -- third-party dust: stake planted in a user's
  mailbox and on the vault is ignored or absorbed as a donation, never a way
  to stop wraps or unwraps.
- `test_min_stake_liveness.py` -- sequence liveness: two churn cycles of
  deposits, withdrawals, and rotations leave every kind of small leftover, with
  every call staying live and nothing forfeited.
- `test_claimable_tao.py` -- a governance dust-threshold raise force-sells the
  vault's position: the stranded native TAO is credited to the holders present
  at that moment, withdrawable in full, and denied to later depositors.

Chainless unit tests for the framework itself: `test_substrate.py`,
`test_chain_unit.py`, `test_checks_unit.py`.

## The `env` fixture

`env` (in `alpha_e2e/fixtures.py`, session-scoped) calls
`bootstrap.build_environment()` once per pytest process: it creates three
subnets, registers and stakes nine validators, deploys the contracts, and
funds the test accounts. Every test in a scenario module that requests `env`
shares that one build -- this is what makes running more than one scenario
module per localnet unsupported (see the IMPORTANT note above).
