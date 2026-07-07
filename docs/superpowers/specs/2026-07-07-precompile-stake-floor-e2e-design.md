# Precompile-driven min-stake floor — localnet e2e design

- **Date:** 2026-07-07
- **Status:** implemented — passing green against a live localnet
- **Branch:** `pg/incorporate_added_precompile` (alpha-wrapper)
- **Script:** `e2e/localnet-e2e-precompile-stake-floor.sh`
- **Scope:** POC. The contract stays POC-quality and unchanged; this covers only
  the e2e that proves the mechanism works against a real subtensor localnet.

## Goal

Prove end-to-end, against a live subtensor localnet, that:

1. the staking precompile's `getStakeOperationThreshold()` returns the chain's
   real min-stake (`DefaultMinStake`), and
2. `AlphaVault` reads that value **live from inside the contract** and uses it to
   recognise stake the chain would refuse to move/transfer — matching the chain's
   own enforcement.

## Background (verified in subtensor @ `pg/add_precompile_for_extracting_minimal_movable_stake_value`)

- `getStakeOperationThreshold()` → `get_stake_operation_threshold()` →
  `DefaultMinStake::<T>::get()` → `T::InitialMinStake` = `SubtensorInitialMinStake`
  = **`2_000_000` RAO (0.002 TAO)**. A runtime constant, identical in prod and
  fast-runtime, **not** settable at runtime (`sudo_set_stake_threshold` writes an
  unrelated `StakeThreshold` storage, not this value).
- The moves/transfers the vault performs gate on the **same** constant:
  `do_transfer_stake`/`do_move_stake` → `transition_stake_internal(validate=true)`
  → `validate_stake_transition` → `ensure!(tao_equivalent >= DefaultMinStake, AmountTooLow)`
  (`stake_utils.rs:1009`). A sub-floor move/transfer reverts `AmountTooLow`, and
  the precompile returns exactly that threshold.

## Key implementation finding: you cannot seed a sub-floor position on a live chain

The original design included a "vault rejects a sub-floor deposit at the exact
boundary" test (`boundary-1` → `DepositTooSmall`). Running it exposed a real
constraint: **every stake-creating op — including the `transfer_stake` that seeds
a mailbox deposit — enforces `DefaultMinStake`.** So a sub-floor position simply
cannot be created on-chain; the seeding transfer reverts `AmountTooLow` before the
vault is ever reached. The vault's `DepositTooSmall` is only reachable inside a
sub-RAO price-quantisation gap that is usually empty.

Consequence:
- The exact-boundary precision test is **infeasible on a live chain** and is left
  to the mock unit tests (`test/StakeFloorPrecompile.t.sol`), where price is fixed.
- "Recognise unmovable stake" is instead proved the way the chain actually allows:
  a **rebalance skip**, where the sub-floor amount arises *internally* from a
  50/50 split (no seeding required).

## Non-goals

- No contract changes: no owner-fallback semantics rework, gas-cap, or efficiency
  threading (all deferred — POC).
- No dynamic runtime-upgrade to change the constant (chosen: static-value rigor).

## Harness

- Standalone script sourcing `e2e_common.sh` and calling `e2e_bootstrap`
  (3 subnets × 3 validators, deployed vault).
- Localnet started with the prebuilt fast-runtime node:
  `BUILD_BINARY=0 scripts/localnet.sh` (the node post-dates the precompile commit,
  so it ships the view; group 1 double-checks at runtime).
- Reuses `floor_boundary` (as a "≈ one chain-floor of TAO" sizing unit),
  `deposit_and_wrap`, `vault_send`, `set_validators_py`, `transfer_stake_py`,
  `get_stake`. Adds thin `cast` reads for `effectiveStakeFloor()` and a `cast send`
  for `setMinStakeTaoFloor()`.
- `CHAIN_FLOOR_EXPECTED = 2_000_000`; `FALLBACK_SENTINEL = 50_000_000`
  (≠ chain floor, < `STAKE_FLOOR_CAP` = `100e6`).

## Assertions (all passing)

Bracketed proof: **(1) the precompile alone → (2–5) the contract → (6) the chain alone.**

1. **Precompile is live and returns the chain floor.**
   `getStakeOperationThreshold() == 2_000_000`. Also confirms the node ships the view.
2. **The contract reads it live — disambiguated from the fallback.**
   `setMinStakeTaoFloor(50e6)`, then `effectiveStakeFloor() == 2e6` while
   `minStakeTaoFloor() == 50e6`. Returning the chain value with the stored fallback
   at `50e6` is only possible if `_stakeFloor()` called the precompile.
3. **Transfer rail gated on the chain value.** A deposit worth ~`5×` the chain floor
   (∈ `(2e6, 50e6)`) → wrap **succeeds**; it would revert `DepositTooSmall` if gated
   on the `50e6` fallback.
4. **Move rail gated on the chain value.** Two-validator 50/50, deposit worth ~`30×`
   the floor (> `50e6`, so it clears the deposit gate under either gating) → the
   ~half corrective move (~`15×`, ∈ `(2e6, 50e6)`) **executes** (under-validator
   receives stake); it would be skipped if gated on the `50e6` fallback.
5. **Recognition: sub-floor move skipped.** Two-validator 50/50, deposit worth
   ~`1.5×` the floor → the ~half corrective move (~`0.75×`, genuinely sub-floor) is
   **skipped** (under-validator stays `0`) and the wrap still completes in-budget —
   the vault recognises the unmovable stake rather than attempting a doomed move.
6. **The chain independently refuses the same threshold.** A raw `transfer_stake` of
   a clearly sub-floor amount (~½ the floor unit) → reverts `AmountTooLow`; an
   above-floor amount → succeeds. The gate the precompile reports is the gate the
   chain enforces.

## Run

1. `BUILD_BINARY=0 ./scripts/localnet.sh` (from subtensor; prebuilt node) → chain
   up on `:9944`.
2. From the alpha-wrapper worktree root: `./e2e/localnet-e2e-precompile-stake-floor.sh`.

## Risks / notes

- **Sub-floor seeding is impossible on a live chain** (see finding above) — the
  reason the deposit-rejection precision test is left to the mocks.
- **Emission / price drift:** the floor unit is recomputed from the live price
  immediately before each scenario; gap-amounts are sized with margin so drift
  cannot cross a gate.

## Success criteria — met

Script exits `0` with all of groups 1–6 asserted green against a freshly
bootstrapped localnet. (Validated 2026-07-07: chain floor `2_000_000`; group 4
moved `11_705_309` RAO to the under-validator; group 6 refused `206_257` alpha RAO
with `AmountTooLow`.)
