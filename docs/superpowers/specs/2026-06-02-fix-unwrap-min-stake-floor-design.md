# Fix: unwrap reverts on subtensor's TAO-denominated min-stake floor

Date: 2026-06-02
Status: Approved (pending spec review)
Branch: pg/fix_unwrap_bug

## Problem

The vault gates every stake-move it initiates (`transferStake` / `moveStake`) with
`minRebalanceAmt`, an **alpha-denominated** threshold (default `2e6`). Subtensor's
`transfer_stake_within_subnet` instead enforces a **TAO-denominated** floor:

```
tao_equivalent = current_alpha_price(netuid) * alpha
ensure!(tao_equivalent >= DefaultMinStake /* 2e6 TAO-RAO */, AmountTooLow)
```

Both `transferStake` (via `flush`) and same-subnet `moveStake` reach this check, and it has
**no full-balance bypass**. When `alpha_price < 1` (the common case for subnet alpha), `2e6`
alpha is worth `< 2e6` TAO and the move reverts.

`removeStake` (the `withdrawForTao` rail) has a full-balance bypass
(`validate_remove_stake`: the floor is skipped when the remaining stake is zero), which is why
that rail already escapes the lock.

### Impact

The unwrap-to-alpha path (`_drainAssets`) applies no threshold at all, so any withdrawal that
reaches a validator holding `0 < balance < DefaultMinStake / alpha_price` reverts and locks the
holder out of the alpha rail. The deposit gate and the rebalance/sweep moves share the same
root cause.

## Root cause

A single global alpha threshold cannot represent a per-subnet TAO floor: different subnets have
different alpha prices, and a given subnet's price moves over time. The floor must be evaluated
as `alpha * alpha_price` against a TAO-RAO value, using the live per-subnet price.

## Decision summary

- **Source of truth is subtensor.** Wrap each vault-initiated `transferStake` / `moveStake` in
  `try/catch`. On failure, re-read the live price and re-evaluate subtensor's own condition
  `alpha * price < floor`. If it is that sub-floor case, handle it gracefully; otherwise
  re-bubble the original revert so unrelated failures still fail loudly.
- **Price source:** the Alpha precompile (`0x...0808`), method `getAlphaPrice(uint16)`, read
  only on the failure (catch) path, so there is no happy-path gas cost on any rail.
- **Caller absorbs bounded dust, but never a total loss.** On the withdraw rail, a genuinely
  non-transferable residual (its TAO value is below the floor) is left in the vault; the caller
  receives less than the shares they burned. If, however, the *entire* request is
  non-transferable (every slice sub-floor, so `delivered == 0`), the withdraw reverts
  `WithdrawTooSmall` rather than burning shares for nothing - the caller keeps their shares and
  exits via `withdrawForTao`. Truly non-transferable positions always have that escape.
- **Rename** `minRebalanceAmt` -> `minStakeTaoFloor`, default `2e6`, now compared against
  `alpha * price` (TAO-RAO). It mirrors subtensor's `DefaultMinStake` and stays owner-tunable.

## Design

### New on-chain component

- `IAlpha` interface and `ALPHA_PRECOMPILE = 0x0000000000000000000000000000000000000808`.
  - Signature validated against the precompile body
    (`#[precompile::public("getAlphaPrice(uint16)")] fn get_alpha_price(_, netuid: u16) -> U256`):
    `function getAlphaPrice(uint16 netuid) external view returns (uint256);`
  - Returns `alpha_price * 1e18` (the precompile scales by `1e9` then RAO->wei by `1e9`). The
    value is truncated to `1e9` precision, so it is `<=` subtensor's full-precision price.

### Helpers

- `_isBelowMinStake(uint256 alpha, uint16 netuid) -> bool`:
  `Math.mulDiv(alpha, getAlphaPrice(netuid), 1e18) < minStakeTaoFloor`.
  Because the precompile price is `<=` the full-precision price subtensor uses, our
  `tao_equivalent` is `<=` subtensor's: a real sub-floor failure is never misclassified as
  "other" (conservative). `getAlphaPrice == 0` makes every amount classify as sub-floor, which
  degrades the alpha rail to "use withdrawForTao" -- the correct behavior for near-zero price.
- `_bubbleRevert(bytes memory err)`: re-throws captured revert data via assembly so the original
  error is preserved when the failure is not the sub-floor case.
- `_requireSubFloorElseBubble(bytes memory err, uint256 alpha, uint16 netuid)`: the single,
  reused catch-handler. If `_isBelowMinStake` is false it `_bubbleRevert`s; otherwise it returns
  so the caller runs its site-specific sub-floor action. Every `catch` block calls this, so the
  classify-and-bubble logic lives in one place (DRY); only the `try` boilerplate and the
  per-site success/skip action remain at each call site.

### `minStakeTaoFloor` semantics

Default `2e6` (mirrors `DefaultMinStake`). Compared against `alpha * price`, not raw alpha.
Renames: state var `minRebalanceAmt` -> `minStakeTaoFloor`, setter `setMinRebalanceAmt` ->
`setMinStakeTaoFloor`, event `MinRebalanceAmtUpdated` -> `MinStakeTaoFloorUpdated`. Docstring
updated to describe the TAO-RAO semantics.

### Per-path behavior

| Path | Site | On sub-floor |
|---|---|---|
| Withdraw drain | `_drainAssets` `flush` | skip that validator, continue draining the next; leftover dust stays staked, captured into `totalStake` by the post-drain `_alignToWeights` (accrues to remaining holders); caller absorbs the bounded loss. If `delivered == 0` (nothing transferable), revert `WithdrawTooSmall` to preserve shares |
| Rebalance | `_rebalanceStep` `moveStake` | skip the move and stop the loop (the largest over/under move is sub-floor, so all smaller pairings are too); replaces the old `moveAmt < threshold` alpha pre-check |
| Rotation sweep | `_sweepRotatedStake` `moveStake` | drop the hotkey from `_lastSeenHotkeys` (already today's behavior for sub-`2e6`-alpha balances; the change only stops the revert when `alpha >= 2e6` but `alpha * price < 2e6`) |
| Deposit | `processDeposit` mailbox->clone `flush` | revert `DepositTooSmall`; removes the old `totalDeposit < minRebalanceAmt` alpha pre-check |

The shared helpers cover deposit-rebalance, withdraw-rebalance, and the public `rebalance()` at
once. Only the catch branch reads the price.

### Accounting and events

- `_drainAssets` returns the delivered amount; `Withdrawn` emits the delivered amount, not the
  requested one.
- `totalStake` stays correct: `_alignToWeights` recomputes it from live balances after the drain.
- Last-holder edge: if the only holder under-delivers, the dust is stranded once supply hits
  zero (same class as the existing stuck-clone note). Bounded and accepted.

### Edge cases

- Transfer toggle on: above-floor takes are not sub-floor, so they bubble and `withdraw` reverts
  (preserves the existing `withdrawForTao` escape). `moveStake` is unaffected by the toggle in
  subtensor (`do_move_stake` passes `check_transfer_toggle = false`).
- `getAlphaPrice == 0`: alpha rail fully skipped; route to `withdrawForTao`.

## Out of scope

- `reclaimAlphaFromMailbox`: single full-amount `flush` with no next-validator fallback. Stays
  reverting on sub-floor; the `reclaimMailboxAlphaAsTao` TAO escape already exists.
- `removeStake` partial-bypass floor is not modeled in the mock beyond current needs.

## Testing

- New `MockAlpha` at `0x...0808` exposing `getAlphaPrice(uint16)`, settable per netuid, default
  `1e18`. Etched in `AlphaVaultTestBase.setUp`. Default `1e18` makes `alpha == tao`, so all
  existing tests behave unchanged (regression-safe).
- `MockStaking`: enforce the floor on `transferStake` and `moveStake` (read price from `0x808`,
  revert `AmountTooLow` when `alpha * price / 1e18 < 2e6`, no bypass). `removeStake` left as-is.
- Test helper `_setAlphaPrice(netuid, priceE18)`.
- New tests:
  - withdraw skips a sub-floor validator balance and drains the rest (no revert).
  - withdraw final-remainder under-delivery (two validators `10e6`, price `0.5`, withdraw
    `11e6`): caller receives `10e6`, vault retains `1e6`.
  - `rebalance()` skips sub-floor moves without reverting.
  - rotation sweep drops sub-floor dust without reverting.
  - deposit below floor reverts `DepositTooSmall`; deposit at the boundary succeeds.
  - non-sub-floor failure (transfer toggle) still bubbles (existing toggle test stays green).
  - event assertions use `vm.expectEmit` with a concrete expected event.
- `.gas-snapshot` regenerated (try/catch adds minor happy-path overhead).

## Conventions

- ASCII-only in all source and test files (no box-drawing, em-dash, or smart quotes).
- Minimal code comments. No comment restates what the code does; comments explain only the
  non-obvious "why" (e.g., the conservative-price rationale, the sub-floor classification).
- Surgical edits only: rename and the per-path try/catch, no unrelated refactoring.
- Event assertions use `vm.expectEmit` with a concrete expected event.
- Clean and DRY: the classify-and-bubble logic is one helper (`_requireSubFloorElseBubble`)
  reused by every rail; no copy-pasted catch bodies.
- Tests are focused with no redundant cases: one test per distinct behavior, sharing setup
  through the existing base helpers rather than repeating it.

## Done criteria

- All new and existing tests pass; `.gas-snapshot` regenerated and committed by the user.
- A final senior-smart-contract-engineer self code-review is performed before declaring done,
  covering: security (no new precompile-trust or reentrancy issues, conservative price use),
  contract liveness (no path can be bricked; escape hatches intact), and clean, readable code.

## Files touched

- `src/interfaces/IAlpha.sol` (new)
- `src/AlphaVault.sol` (helpers, rename, per-path try/catch, deposit gate, event)
- `test/mocks/MockAlpha.sol` (new)
- `test/mocks/MockStaking.sol` (floor enforcement)
- `test/AlphaVaultTestBase.sol` (etch MockAlpha, `_setAlphaPrice`)
- new test file(s) for the floor behavior; rename references in existing tests
- `.gas-snapshot`
