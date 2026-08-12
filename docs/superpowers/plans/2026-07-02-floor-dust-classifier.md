# Floor-Aware Dust Classifier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace every blind `try/catch` skip in AlphaVault's stake-moving paths with a deterministic, price-aware dust pre-check, so that the ONLY value that can ever silently leave share accounting is a sub-floor dust amount, and every other failure reverts (bubbles) instead of being swallowed.

**Architecture:** One private helper `_isBelowFloor(alpha, priceE18)` classifies a slice against the chain's tao-denominated min-stake floor using the alpha price precompile (0x808). Call sites (`wrap` flush pre-check, `_sweepRotatedStake`, `_drainAssets`, `unwrapForTao` partial branch, `previewUnwrap` orphan filter) skip provable dust pre-call and execute everything else bare, letting genuine failures revert. The floor value is an owner-tunable storage var (capped) so a chain-side floor change never bricks the vault. `_rebalanceStep` keeps its try/catch (a failed split-optimization loses nothing) and is NOT touched.

**Tech Stack:** Solidity ^0.8.20, Foundry (forge/cast), OpenZeppelin, Bittensor EVM precompiles (staking 0x805, alpha 0x808), MockStaking/MockAlpha test doubles.

## Why this is safe (chain ground truth — do not re-derive, verified against subtensor tag v3.4.7-422 at ~/Projects/subtensor)

| Op (vault call -> extrinsic) | Floor rule | Full-balance exemption | Can chain move MORE than requested? |
|---|---|---|---|
| `SubnetClone.moveStake` -> `move_stake` (same subnet) | spot: `price * alpha >= DefaultMinStake` (2e6 rao), exact, swap-less | **NO** | No |
| `SubnetClone.flush` -> `transfer_stake` (same subnet) | spot: `price * alpha >= DefaultMinStake`, exact, swap-less | **NO** | No |
| `SubnetClone.sellAlphaForTao` -> `remove_stake` | sim-swap output `>= DefaultMinStake` (spot minus fees) | **YES** (remainder == 0 bypasses) | Only via `clear_small_nomination_if_required` remainder sweep, gated by `NominatorMinRequiredStake` (currently 0; out of scope here) |
| `IAlpha.getAlphaPrice(uint16)` at 0x808 | returns spot tao-per-alpha price **scaled by 1e18** (internal 1e9 fixed-point, then the EVM balance conversion multiplies by 1e9 again) | n/a | n/a |
| `IStaking.getStake` at 0x805 (StakingPrecompileV2, INDEX 2053) | returns **raw rao** (no EVM balance conversion; the converting getStake belongs to legacy 0x801, unused here) | n/a | n/a |

Consequences the code below relies on:
- For move/transfer, a spot-price pre-check `alpha * priceE18 / 1e18 < floor` (alpha and floor in rao, price 1e18-scaled) is the EXACT complement of the chain's rejection rule. Skipping iff it holds loses at most sub-floor dust; attempting otherwise cannot floor-fail.
- For remove (sell), sim <= spot, so `spot-value < floor` implies the chain would reject: skip-side is safe. The reverse band (spot says ok, sim says dust, width ~ swap fee) causes a clean revert, never a loss.
- Full-balance sells are floor-exempt: the `balance <= remaining` branch in `unwrapForTao` must stay UNCHECKED and bare (checking it would wrongly strand sellable dust).
- Full-balance transfers are NOT exempt: `_drainAssets` must pre-check EVERY slice including full ones.
- Removing try/catch also removes the 63/64 OOG-grief vector: a gas-starved inner call now reverts the whole tx instead of masquerading as a floor failure.

## Global Constraints

- **NEVER run `git commit` or `git push`. The user commits. No exceptions.**
- ASCII only in all source you write or edit: no box-drawing chars, no em-dash, no smart quotes, no U+2248. Do not add new decorated section dividers.
- Comments explain WHY, never WHAT. Chain behavior is described black-box ("the chain rejects transfers below the floor"), never by internal subtensor function names or formulas.
- One statement per line. Custom errors (PascalCase). `mixedCase` functions/vars. Internal/private prefixed `_`.
- Test names: `test_<Scenario>_<Outcome>` with exactly two underscore-separated segments after `test`; repo exceptions: `test_RevertWhen_<Condition>` and `testFuzz_...`. Event assertions use `vm.expectEmit` with a concrete expected event, never `vm.getRecordedLogs` + decode (exception: pre-existing `_countRebalancedLogs` helper usage may stay where already used).
- Fuzz tests use `bound(x, min, max)`, not `vm.assume`.
- Zero compiler warnings. `forge fmt` before finishing. Update NatSpec in the same change as behavior (stale docs are a bug).
- Do not leak review finding IDs (H-1, M-2 etc.) into code or comments.
- Precompile interface entries must be validated against the `#[precompile::public(...)]` fn body in ~/Projects/subtensor at tag v3.4.7-422 (Task 1 includes the command).
- Scope discipline: implement exactly this plan. Do NOT also fix unrelated known issues (e2e Python `assets` field rename, `_redeemFromDissolvedSubnet` zero-out guard, `Unwrapped`/`UnwrappedForTao` event semantics, architecture-comment `totalShares` reference, pre-existing test naming). They are tracked separately.

## Current-state orientation (read before Task 1)

- `src/AlphaVault.sol` — the vault. Relevant today: `wrap` (~line 134, flush wrapped in `try/catch -> revert DepositTooSmall`), `unwrapForTao` (~222, sell loop with bare full-balance branch + try/catch partial branch), `_redeem` (~270), `_drainAssets` (~302, try/catch every flush), `_sweepRotatedStake` (~676, try/catch move + unconditional snapshot refresh), `previewUnwrap` (~503, counts rotated-out orphans gross), `_rebalanceStep` (~407, try/catch — KEEP AS IS).
- `src/interfaces/IStaking.sol` — pattern to copy for the new `IAlpha` interface (interface + address constant in one file).
- `test/mocks/MockStaking.sol` — mock at the staking precompile address. `_belowMinStake` scales price by **1e18**, which IS the chain's EVM-facing scale (verified: getAlphaPrice = internal 1e9 fixed-point x 1e9 EVM balance conversion). Task 1 keeps the 1e18 scale and only replaces the comment + adds the transfer-side per-hotkey revert knob.
- `test/AlphaVaultTestBase.sol` — `MIN_STAKE_FLOOR = 2e6` (line ~54), `_setAlphaPrice(uint256,uint256)` (line ~251), mock etching in `setUp`.
- `test/MinStakeTaoFloor.t.sol` — floor-behavior suite, uses `PRICE_HALF = 0.5e18` (rescaled in Task 1).
- An `IAlpha.sol` + vault price usage existed before commit 159a043 deleted it; `git show 531220a:src/interfaces/IAlpha.sol` shows the old shape (address 0x0000000000000000000000000000000000000808).

---

### Task 1: Price plumbing — IAlpha interface, MockAlpha, 1e18 price scale, per-hotkey transfer revert knob

**Files:**
- Create: `src/interfaces/IAlpha.sol`
- Create: `test/mocks/MockAlpha.sol`
- Modify: `test/mocks/MockStaking.sol` (replace `_belowMinStake` comment, keep 1e18 scale; add `setTransferStakeRevertsFor`)
- Modify: `test/AlphaVaultTestBase.sol` (etch MockAlpha; `_setAlphaPrice` sets both mocks)
- Modify: `test/MinStakeTaoFloor.t.sol` (no scale change; `PRICE_HALF` stays 0.5e18)

**Interfaces produced (later tasks rely on these exact names):**
- `IAlpha.getAlphaPrice(uint16 netuid) external view returns (uint256)` — spot price scaled by 1e18; `ALPHA_PRECOMPILE = 0x0000000000000000000000000000000000000808`.
- `MockAlpha.setPrice(uint16 netuid, uint256 priceE18)`; unset netuid defaults to 1e18 (price 1.0).
- `MockStaking.setTransferStakeRevertsFor(bytes32 hotkey, bool v)`.
- `AlphaVaultTestBase._setAlphaPrice(uint256 netuid, uint256 priceE18)` — now sets MockStaking AND MockAlpha.

- [ ] **Step 1: Validate the precompile signature against the pinned node**

Run:
```bash
git -C ~/Projects/subtensor show v3.4.7-422:precompiles/src/alpha.rs | grep -n -A 8 'precompile::public("getAlphaPrice'
```
Expected: `#[precompile::public("getAlphaPrice(uint16)")]` with a fn body that (a) multiplies `current_alpha_price` by `1_000_000_000` AND (b) passes the result through `BalanceConverter::into_evm_balance`, which multiplies by another 1e9 (`EVM_TO_SUBSTRATE_DECIMALS` in runtime/src/lib.rs) — so the EVM caller receives the price scaled by **1e18**. Also confirm `StakingPrecompileV2` (INDEX 2053 = 0x805) `get_stake` returns raw rao with NO `into_evm_balance`. If either differs, STOP and report to the user instead of proceeding.

- [ ] **Step 2: Create `src/interfaces/IAlpha.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAlpha
/// @notice Interface for the Bittensor alpha precompile on EVM.
/// @dev Precompile lives at 0x0000000000000000000000000000000000000808.
interface IAlpha {
    /// @notice Spot alpha price for a subnet in TAO, scaled by 1e18.
    function getAlphaPrice(uint16 netuid) external view returns (uint256);
}

/// @dev Alpha precompile address on Bittensor EVM.
address constant ALPHA_PRECOMPILE = 0x0000000000000000000000000000000000000808;
```

- [ ] **Step 3: Create `test/mocks/MockAlpha.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockAlpha {
    mapping(uint16 => uint256) private _priceE18;

    function setPrice(uint16 netuid, uint256 priceE18) external {
        _priceE18[netuid] = priceE18;
    }

    function getAlphaPrice(uint16 netuid) external view returns (uint256) {
        uint256 price = _priceE18[netuid];
        return price == 0 ? 1e18 : price;
    }
}
```

- [ ] **Step 4: Replace `_belowMinStake`'s comment (scale stays 1e18) and add the transfer-side per-hotkey revert knob**

In `test/mocks/MockStaking.sol`, replace `_belowMinStake` (the 1e18 scale is CORRECT — it matches the alpha precompile's EVM-facing scale; only the comment changes):

```solidity
    // The floor is tao-denominated: the chain rejects transfers and moves whose tao value is
    // below MIN_STAKE. Price is scaled 1e18 to match the alpha precompile.
    function _belowMinStake(uint256 amount, uint256 netuid) private view returns (bool) {
        uint256 priceE18 = alphaPrice[netuid] == 0 ? 1e18 : alphaPrice[netuid];
        return (amount * priceE18) / 1e18 < MIN_STAKE;
    }
```

Add next to the existing `removeStakeRevertsFor` declarations:

```solidity
    mapping(bytes32 => bool) public transferStakeRevertsFor;

    function setTransferStakeRevertsFor(bytes32 hotkey, bool v) external {
        transferStakeRevertsFor[hotkey] = v;
    }
```

And extend the guard at the top of `transferStake` (keep the existing global flag):

```solidity
        if (transferStakeReverts || transferStakeRevertsFor[hotkey]) {
            revert("MockStaking: transferStake reverted");
        }
```

Also delete the existing comment above `_belowMinStake` that names the subtensor-internal function ("Mirrors subtensor transfer_stake_within_subnet: ...") — the replacement comment above is the black-box version.

- [ ] **Step 5: Wire MockAlpha into the test base**

In `test/AlphaVaultTestBase.sol`:
1. Import: `import { MockAlpha } from "./mocks/MockAlpha.sol";` and `import { ALPHA_PRECOMPILE } from "../src/interfaces/IAlpha.sol";` (adjust relative path to match neighboring imports).
2. In `setUp`, next to the MockStaking etch and following the same etching pattern used there:
```solidity
        vm.etch(ALPHA_PRECOMPILE, type(MockAlpha).runtimeCode);
```
(If the base deploys mocks with a different pattern, e.g. `deployCodeTo`, mirror that pattern instead — the requirement is: code at `ALPHA_PRECOMPILE` behaving as MockAlpha.)
3. Replace `_setAlphaPrice` so one call keeps both mocks coherent (rename the param to reflect the new scale):
```solidity
    function _setAlphaPrice(uint256 netuid, uint256 priceE18) internal {
        MockStaking(STAKING_PRECOMPILE).setAlphaPrice(netuid, priceE18);
        // forge-lint: disable-next-line(unsafe-typecast)
        MockAlpha(ALPHA_PRECOMPILE).setPrice(uint16(netuid), priceE18);
    }
```

- [ ] **Step 6: Verify price literals are 1e18-scaled**

`PRICE_HALF` in `test/MinStakeTaoFloor.t.sol` stays `0.5e18` (already correct for the 1e18 price scale). Sweep to confirm no stray differently-scaled price literal feeds `_setAlphaPrice` or `setAlphaPrice`:
```bash
grep -rn "setAlphaPrice\|_setAlphaPrice\|PRICE_HALF" test/
```
Every price fed in must be 1e18-scaled (1e18 = price 1.0). Do NOT touch amounts denominated in `ether`/wei.

- [ ] **Step 7: Build and run the full suite**

Run: `forge build && forge test`
Expected: clean build, all tests pass (no vault behavior changed yet; default mock price is still 1.0 in the new scale). If a test fails, a price literal was missed in Step 6.

---

### Task 2: Vault floor state — `minStakeTaoFloor`, capped setter, `_isBelowFloor`

**Files:**
- Modify: `src/AlphaVault.sol`
- Test: `test/MinStakeTaoFloor.t.sol`

**Interfaces produced:**
- `AlphaVault.minStakeTaoFloor() public view returns (uint256)` (auto-getter), default 2e6.
- `AlphaVault.setMinStakeTaoFloor(uint256 newValue) external onlyOwner` — reverts `MinStakeTaoFloorTooHigh()` above `1e9`.
- `event MinStakeTaoFloorUpdated(uint256 oldValue, uint256 newValue)`.
- `AlphaVault._isBelowFloor(uint256 alpha, uint256 priceE18) private view returns (bool)`.
- Import available to later tasks: `IAlpha`, `ALPHA_PRECOMPILE`.

- [ ] **Step 1: Add the import**

In `src/AlphaVault.sol` next to the `IStaking` import:
```solidity
import { IAlpha, ALPHA_PRECOMPILE } from "./interfaces/IAlpha.sol";
```

- [ ] **Step 2: Add state, event, error, constructor init, setter, helper**

State (in the State section):
```solidity
    /// @notice Tao-denominated floor below which the chain rejects stake transfers and moves.
    ///         Owner-tunable to track chain-side changes without a redeploy; capped at
    ///         MAX_MIN_STAKE_TAO_FLOOR so misconfiguration cannot reclassify real balances as dust.
    uint256 public minStakeTaoFloor;
```

Constant (in the Precision section):
```solidity
    uint256 private constant MAX_MIN_STAKE_TAO_FLOOR = 1e9;
```

Event (in the Events section):
```solidity
    event MinStakeTaoFloorUpdated(uint256 oldValue, uint256 newValue);
```

Error (in the Errors section):
```solidity
    error MinStakeTaoFloorTooHigh();
```

Constructor body, after the existing assignments:
```solidity
        minStakeTaoFloor = 2e6;
```

Setter (in the Admin section, next to `setValidatorRegistry`):
```solidity
    function setMinStakeTaoFloor(uint256 newValue) external onlyOwner {
        if (newValue > MAX_MIN_STAKE_TAO_FLOOR) revert MinStakeTaoFloorTooHigh();
        uint256 old = minStakeTaoFloor;
        minStakeTaoFloor = newValue;
        emit MinStakeTaoFloorUpdated(old, newValue);
    }
```

Helper (in the Internal Helpers section, near `_isRotatedOut`):
```solidity
    /// @dev True when `alpha`'s tao value is below the chain's stake floor. Such moves and
    ///      transfers are rejected by the chain, so callers skip them pre-call; at most this
    ///      dust is ever left behind.
    function _isBelowFloor(uint256 alpha, uint256 priceE18) private view returns (bool) {
        return (alpha * priceE18) / 1e18 < minStakeTaoFloor;
    }
```

- [ ] **Step 3: Add setter tests to `test/MinStakeTaoFloor.t.sol`**

```solidity
    function test_SetMinStakeTaoFloor_UpdatesValueAndEmits() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit AlphaVault.MinStakeTaoFloorUpdated(2e6, 5e6);
        vault.setMinStakeTaoFloor(5e6);
        assertEq(vault.minStakeTaoFloor(), 5e6);
    }

    function test_RevertWhen_MinStakeTaoFloorAboveCap() public {
        vm.expectRevert(AlphaVault.MinStakeTaoFloorTooHigh.selector);
        vault.setMinStakeTaoFloor(1e9 + 1);
    }

    function test_RevertWhen_NonOwnerSetsMinStakeTaoFloor() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setMinStakeTaoFloor(3e6);
    }
```
Add the imports the file is missing for these (e.g. `AlphaVault`, `Ownable` from `@openzeppelin/contracts/access/Ownable.sol`) — check how sibling test files import them and mirror that. If the test contract's deployer is not the owner in this suite's setup, `vm.prank` the owner for the two owner calls (check `AlphaVaultTestBase` for who deploys the vault).

- [ ] **Step 4: Build and test**

Run: `forge build && forge test --match-path test/MinStakeTaoFloor.t.sol`
Expected: build clean, new tests pass, existing tests untouched.

---

### Task 3: `wrap` — deterministic DepositTooSmall, real flush failures bubble

**Files:**
- Modify: `src/AlphaVault.sol` (`wrap`)
- Test: `test/MinStakeTaoFloor.t.sol`

**Interfaces:** Consumes `_isBelowFloor` and `IAlpha` from Task 2. No new surface.

- [ ] **Step 1: Replace the flush try/catch with a pre-check**

In `wrap`, replace:
```solidity
        try DepositMailbox(payable(userClone)).flush(destColdkey, chosenHotkey, netuid, totalDeposit) { }
        catch {
            revert DepositTooSmall();
        }
```
with:
```solidity
        if (_isBelowFloor(totalDeposit, IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(nid))) revert DepositTooSmall();
        DepositMailbox(payable(userClone)).flush(destColdkey, chosenHotkey, netuid, totalDeposit);
```
(`nid` is the `uint16` already in scope in `wrap`.) Update the `wrap` NatSpec dev note: DepositTooSmall now fires only for a genuinely sub-floor deposit; any other transfer failure reverts with the underlying error.

- [ ] **Step 2: Add the bubble test**

In `test/MinStakeTaoFloor.t.sol`:
```solidity
    function test_RevertWhen_WrapFlushFailsForNonFloorReason() public {
        _setValidators(99, _hotkeys(hotkey4), _weights(10000));
        _simulateMailboxDeposit(alice, 99, 10e6, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setTransferStakeReverts(true);

        vm.prank(alice);
        vm.expectRevert(bytes("MockStaking: transferStake reverted"));
        vault.wrap(alice, 99, hotkey4);
    }
```
Use the SAME setup helpers the file's existing wrap-floor tests (`test_ProcessDeposit_RevertsDepositTooSmall_WhenBelowTaoFloor` at ~line 24) use for netuid/hotkey/deposit scaffolding — copy that test's arrange block verbatim and change only the mock flag, the expected revert, and use an above-floor deposit amount (e.g. 10e6 at default price). If the helper for parking mailbox stake has a different name (grep `_simulateAlphaDepositHotkey` / `_simulateMailboxDeposit` in the base), use the one the sibling test uses.

- [ ] **Step 3: Test**

Run: `forge test --match-path test/MinStakeTaoFloor.t.sol -vv`
Expected: existing `DepositTooSmall` floor tests still pass (pre-check fires where the mock used to reject); new test passes.

---

### Task 4: `_sweepRotatedStake` — skip dust deterministically, bubble real failures

**Files:**
- Modify: `src/AlphaVault.sol` (`_sweepRotatedStake`)
- Test: `test/MinStakeTaoFloor.t.sol`

**Interfaces:** Consumes `_isBelowFloor`, `IAlpha`. No new surface.

- [ ] **Step 1: Replace the try/catch body**

Replace the inner loop body of `_sweepRotatedStake` (currently: `if (bal > 0) { try ... moveStake ... catch { } }` plus its comment) with:

```solidity
                if (_isRotatedOut(hk, currentSet)) {
                    uint256 bal = staking.getStake(hk, coldkey, netuid);
                    // The chain rejects moves below the tao floor, so a sub-floor residual is
                    // skipped and forfeited by the snapshot refresh below: bounded dust. Any
                    // other move failure reverts the call so the hotkey stays tracked and the
                    // move is retried later, instead of silently stranding the balance.
                    if (bal > 0 && !_isBelowFloor(bal, priceE18)) {
                        SubnetClone(payable(clone)).moveStake(hk, currentSet[0], netuid, bal);
                        emit Rebalanced(tokenId, hk, currentSet[0], bal);
                    }
                }
```

And read the price ONCE at the top of the `if (clone != address(0))` block (moves are swap-less, so one read is exact for the whole loop):
```solidity
            uint256 priceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);
```
The unconditional snapshot refresh at the end of the function is now correct as-is (only dust can remain un-moved) — leave it unchanged.

- [ ] **Step 2: Add the stranding-regression test**

In `test/MinStakeTaoFloor.t.sol` (model the arrange block on the existing `test_Rebalance_DropsRotatedOutSubFloorDust` at ~line 87, which rotates hotkey3 out — reuse its exact setup calls, only the orphan balance and the mock flag differ):

```solidity
    function test_RevertWhen_AboveFloorOrphanSweepFails() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);

        // 10e6 alpha at default price 1.0 is far above the floor; the move failure is a real
        // fault, so the sweep must bubble instead of dropping the orphan from tracking.
        _setStake(hotkey3, NETUID1, 10e6);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        MockStaking(STAKING_PRECOMPILE).setMoveStakeReverts(true);

        uint256 totalBefore = vault.totalStake(TOKEN1);
        vm.expectRevert(bytes("MockStaking: moveStake reverted"));
        vault.rebalance(NETUID1);

        assertEq(vault.lastSeenHotkeys(TOKEN1)[2], hotkey3, "orphan must stay tracked");
        assertEq(vault.totalStake(TOKEN1), totalBefore, "orphan still counted in backing");
    }
```
Check which lastSeen slot hotkey3 occupies in this suite's setup (mirror the index the dust test asserts) and adjust the `[2]` index to match.

- [ ] **Step 3: Test**

Run: `forge test --match-path test/MinStakeTaoFloor.t.sol -vv`
Expected: `test_Rebalance_DropsRotatedOutSubFloorDust` still passes (dust is now skipped by pre-check instead of caught — same observable outcome). New test passes. `test_Rebalance_SkipsAboveFloorMoveThatChainRejects` (~line 69) must ALSO still pass — it exercises `_rebalanceStep`'s catch, which this plan does not touch; if it fails you modified the wrong function.

---

### Task 5: `_drainAssets` pre-check + `previewUnwrap` parity filter

**Files:**
- Modify: `src/AlphaVault.sol` (`_drainAssets`, `previewUnwrap`)
- Modify: `test/AlphaVault.t.sol` (rewrite the preview-overstatement test)
- Test: `test/MinStakeTaoFloor.t.sol` (new bubble test + fuzz)

**Interfaces:** Consumes `_isBelowFloor`, `IAlpha`, `MockStaking.setTransferStakeRevertsFor` (Task 1). No new surface.

- [ ] **Step 1: Rewrite `_drainAssets`**

Replace the loop body (currently try/catch around `flush`) with a pre-check. Transfers have no full-balance floor exemption on the chain, so EVERY slice is checked:

```solidity
    /// @dev Drain `assets` alpha to `userColdkey` across the active validator set.
    ///      The chain rejects transfers below the tao floor, so sub-floor slices are skipped
    ///      pre-call (bounded under-delivery, guarded by minAlphaOut and WithdrawTooSmall);
    ///      any other transfer failure reverts the whole redemption.
    function _drainAssets(
        bytes32[3] memory hotkeys,
        uint256[3] memory balances,
        uint256 validatorCount,
        address clone,
        uint16 netuid,
        bytes32 userColdkey,
        uint256 assets
    ) private returns (uint256 delivered) {
        uint256 priceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);
        uint256 remaining = assets;
        for (uint256 i; i < validatorCount && remaining > 0;) {
            uint256 takeAmount = remaining > balances[i] ? balances[i] : remaining;
            if (takeAmount > 0 && !_isBelowFloor(takeAmount, priceE18)) {
                SubnetClone(payable(clone)).flush(userColdkey, hotkeys[i], netuid, takeAmount);
                balances[i] -= takeAmount;
                remaining -= takeAmount;
            }
            unchecked {
                ++i;
            }
        }
        delivered = assets - remaining;
    }
```
One price read is exact for the whole loop because same-subnet transfers do not move the price.

- [ ] **Step 2: Restore the orphan filter in `previewUnwrap`**

In the rotated-out loop, replace:
```solidity
            if (_isRotatedOut(hk, hotkeys)) {
                totalAlpha += staking.getStake(hk, subnetColdkey, netuid);
            }
```
with:
```solidity
            if (_isRotatedOut(hk, hotkeys)) {
                uint256 bal = staking.getStake(hk, subnetColdkey, netuid);
                // A sub-floor orphan cannot be swept into the current set (the chain rejects
                // the move), so the redeem path never delivers it; excluding it keeps the
                // preview aligned with actual delivery.
                if (!_isBelowFloor(bal, priceE18)) totalAlpha += bal;
            }
```
and read the price once before that loop:
```solidity
        uint256 priceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);
```
Keep the existing NatSpec line "Live-path delivery may fall short of the preview by floor-bounded dust" — it remains true (a sub-floor FINAL SLICE in `_drainAssets` is still previewed but undelivered).

- [ ] **Step 3: Rewrite the preview test in `test/AlphaVault.t.sol`**

Find `test_PreviewUnwrapOverstatesBySubFloorOrphanDust` (~line 1185). It currently asserts preview EXCEEDS delivery by up to the floor. Replace the whole function with a parity assertion under the same scenario (keep its arrange block: it parks `MIN_STAKE_FLOOR - 1` on a rotated-out hotkey, then unwraps; reuse those exact lines):

```solidity
    function test_PreviewUnwrap_MatchesDeliveryWithSubFloorOrphan() public {
        // ... keep the existing arrange block of the old test verbatim ...
        (uint256 previewAlpha,) = vault.previewUnwrap(TOKEN1, shares);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        uint256 actualAlpha = _getStake(hotkey1, alice, NETUID1) + _getStake(hotkey2, alice, NETUID1)
            + _getStake(hotkey3, alice, NETUID1);
        assertEq(actualAlpha, previewAlpha, "preview must match delivery when only a sub-floor orphan differs");
    }
```
Adapt variable names (`shares`, receiving-side sum helper) to what the old body used; the assertion change is: `assertEq` parity instead of `assertLe(preview - actual, MIN_STAKE_FLOOR)`. If the old body's numbers produce a sub-floor FINAL SLICE as well (not just the orphan), keep `assertLe(previewAlpha - actualAlpha, ...)` with a comment that the residual gap is the undeliverable tail — determine which by running it.

- [ ] **Step 4: New bubble test for an above-floor slice failure**

In `test/MinStakeTaoFloor.t.sol` (arrange like `test_Withdraw_SkipsSubFloorValidator_DeliversInFullFromNext` at ~line 102):

```solidity
    function test_RevertWhen_AboveFloorDrainSliceFails() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, NETUID1, 40e6, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        _setStake(hotkey1, NETUID1, 20e6);
        _setStake(hotkey2, NETUID1, 20e6);
        MockStaking(STAKING_PRECOMPILE).setTransferStakeRevertsFor(hotkey1, true);

        uint256 sharesBefore = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vm.expectRevert(bytes("MockStaking: transferStake reverted"));
        vault.unwrap(TOKEN1, sharesBefore, _toSubstrate(alice), 0);

        assertEq(vault.balanceOf(alice, TOKEN1), sharesBefore, "shares intact after bubbled failure");
    }
```

- [ ] **Step 5: Fuzz the dust bound**

In `test/MinStakeTaoFloor.t.sol`:

```solidity
    function testFuzz_Withdraw_ShortfallBoundedByFloor(uint256 priceE18, uint256 deposit) public {
        priceE18 = bound(priceE18, 0.1e18, 100e18);
        uint256 floorAlpha = (2e6 * 1e18) / priceE18 + 1;
        // 4x the floor so every per-validator slot after the weight split clears the floor
        // and only the final partial tail can be sub-floor; upper bound stays in u64-ish range.
        deposit = bound(deposit, 4 * floorAlpha, 1e15);

        _setAlphaPrice(NETUID1, priceE18);
        _simulateAlphaDeposit(alice, NETUID1, deposit);
        _wrap(alice, NETUID1);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 previewAlpha,) = vault.previewUnwrap(TOKEN1, shares);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        uint256 received = _getStake(hotkey1, alice, NETUID1) + _getStake(hotkey2, alice, NETUID1)
            + _getStake(hotkey3, alice, NETUID1);
        // The only permissible shortfall is a final slice the chain would reject as sub-floor.
        assertLe(previewAlpha - received, floorAlpha, "loss must be bounded by the floor");
    }
```
If the default three-validator setup differs in this file, mirror the hotkey set the file's other `_wrap(alice, NETUID1)` tests use. The property under test: unwrap never reverts for floor reasons and the preview-vs-received gap is at most one sub-floor slice.

- [ ] **Step 6: Test**

Run: `forge test --match-path "test/MinStakeTaoFloor.t.sol" -vv && forge test --match-test "PreviewUnwrap" -vv`
Expected: all pass, including the pre-existing drain floor tests (`test_Withdraw_SkipsSubFloorValidator_DeliversInFullFromNext`, `test_Withdraw_UnderDeliversBoundedDust_OnSubFloorFinalRemainder`, `test_Withdraw_RevertsSlippage_WhenDeliveredBelowMinAlphaOut`, `test_Withdraw_RevertsWithdrawTooSmall_WhenEntireRequestBelowFloor`) whose observable behavior is unchanged by the pre-check.

---

### Task 6: `unwrapForTao` — pre-check the partial branch with a fresh price

**Files:**
- Modify: `src/AlphaVault.sol` (`unwrapForTao`)
- Test: `test/UnwrapForTao.t.sol`

**Interfaces:** Consumes `_isBelowFloor`, `IAlpha`, `MockStaking.setRemoveStakeRevertsFor` (already exists). No new surface.

- [ ] **Step 1: Rewrite the sell loop**

Replace the loop and its lead-in comment in `unwrapForTao` with:

```solidity
        uint256 balanceBefore = clone.balance;
        uint256 remaining = assets;
        // Full-balance sells are exempt from the chain's floor, so they run bare and any
        // failure bubbles. A partial remainder below the floor would be rejected by the
        // chain, so it is skipped pre-call: bounded under-delivery, guarded by minTaoOut.
        // The price is read at the moment of each partial check because earlier sells in
        // this loop move it.
        for (uint256 i; i < 6 && remaining != 0;) {
            uint256 balance = balances[i];
            if (balance != 0) {
                if (balance <= remaining) {
                    SubnetClone(payable(clone)).sellAlphaForTao(hotkeys[i], netuid, balance);
                    remaining -= balance;
                } else if (!_isBelowFloor(remaining, IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid))) {
                    SubnetClone(payable(clone)).sellAlphaForTao(hotkeys[i], netuid, remaining);
                    remaining = 0;
                }
            }
            unchecked {
                ++i;
            }
        }
```
Do NOT add a floor check to the `balance <= remaining` branch (full sells must stay bare — checking would wrongly strand sellable dust, and `test_SubFloorFullDrain_SoldViaFullUnstakeExemption` will catch it if you do). Do NOT `break` when the partial is dust: later smaller balances can still full-sell and shrink `remaining`.

Update the function's NatSpec dev block to: sells run bare and any sell failure bubbles; only a sub-floor partial remainder is left unsold (bounded dust); `minTaoOut` guards the caller; reverts `WithdrawTooSmall` if nothing sells.

- [ ] **Step 2: Align mock price with remove-rate in affected tests**

The vault's classifier reads MockAlpha's price; the mock's `removeStake` floor uses `taoPerAlpha/taoPerAlphaDenom`. Audit `test/UnwrapForTao.t.sol` for tests that set a non-unit rate (`grep -n "setRemoveStakeRate" test/UnwrapForTao.t.sol` and the base helper that wraps it): for each test where the rate ratio is not 1:1 AND the test exercises a partial (non-full) final slice, add a matching `_setAlphaPrice(NETUID1, rateNum * 1e18 / rateDenom);` so classifier and mock floor agree. Tests that only full-sell need no change. Run the file after each adjustment to confirm which ones actually need it:
```bash
forge test --match-path test/UnwrapForTao.t.sol
```
The pre-existing dust suite (`test_SubFloorFinalSlice_UnderDeliversBoundedDust`, `test_RevertWhen_UnderDeliveryBreaksMinTaoOut`, `test_DustPosition_TopUpEnablesFullValueExit`, `test_RevertWhen_PositionTooSmallToExit`) must end green with unchanged assertions.

- [ ] **Step 3: New bubble test for an above-floor partial failure**

In `test/UnwrapForTao.t.sol` (model the arrange on `test_RevertWhen_OneFullSliceSellFails_PreservesCallerShares` at ~line 189, which already stakes across hotkeys and uses `_setRemoveStakeRevertsFor`):

```solidity
    function test_RevertWhen_AboveFloorPartialSellFails() public {
        uint256 shares = _depositForAlice(60e6);
        _setVaultStakes(NETUID1, 40e6, 20e6, 0);
        _setRemoveStakeRevertsFor(hotkeys[0], true);

        // Burning half targets ~30e6: slot 0 (40e6 > 30e6) takes the partial branch, which is
        // far above the floor, so the fault must bubble instead of being skipped as dust.
        vm.prank(alice);
        vm.expectRevert(bytes("MockStaking: removeStake reverted"));
        vault.unwrapForTao(TOKEN1, shares / 2, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), shares, "shares intact after bubbled failure");
    }
```
Adapt helper names/amounts to the file's actual scaffolding (`_depositForAlice`, `_setVaultStakes`, the hotkey array variable) — copy the arrange pattern of the sibling test at line 189 and change only: which slot reverts, share amount so the FIRST touched slot has `balance > remaining` (partial branch), and the expected outcome (revert instead of under-delivery). Before this change the vault silently under-paid in this scenario; the revert is the fix.

- [ ] **Step 4: Test**

Run: `forge test --match-path test/UnwrapForTao.t.sol -vv`
Expected: all pass. Pay attention to `test_RevertWhen_AllSellsFail_PreservesCallerShares` (~line 172): with every sell reverting and above-floor balances, the first FULL-balance sell now bubbles the mock error before reaching `WithdrawTooSmall` — if that test asserted `WithdrawTooSmall`, update its expectation to the bubbled mock error (bytes("MockStaking: removeStake reverted")) and keep the shares-intact assertion; if its balances route through `WithdrawTooSmall` (all slices skipped as dust), leave it. Determine by running, then adjust the expectation to the actual (correct) new behavior — both outcomes preserve caller shares, which is the property that matters.

---

### Task 7: Full verification pipeline

**Files:**
- Modify: `.gas-snapshot`, `snapshots/AlphaVault.json` (regenerated, not hand-edited)

- [ ] **Step 1: Format** — Run: `forge fmt` then `forge fmt --check` (expect: no diff).
- [ ] **Step 2: Build clean** — Run: `forge build` (expect: zero warnings, zero errors; if a warning appears, fix the root cause — never suppress; if you believe it must be silenced, STOP and ask the user).
- [ ] **Step 3: Full suite** — Run: `forge test` (expect: all pass).
- [ ] **Step 4: Non-ASCII guard** — Run: `grep -rPn "[^\x00-\x7F]" src/ test/mocks/MockAlpha.sol test/MinStakeTaoFloor.t.sol --include="*.sol" | grep -v "$(git diff --name-only | tr '\n' '|' | sed 's/|$//')" ; grep -Pn "[^\x00-\x7F]" $(git diff --name-only -- '*.sol')` — expect: no NEW non-ASCII on lines this change added (pre-existing decorated headers elsewhere are out of scope).
- [ ] **Step 5: Gas snapshots** — Run: `FORGE_SNAPSHOT_CHECK=false forge snapshot && FORGE_SNAPSHOT_CHECK=false forge test` then verify `forge snapshot --check --tolerance 1` (expect: exit 0). Both `.gas-snapshot` and `snapshots/AlphaVault.json` will change; that is expected and they ship with the change.
- [ ] **Step 6: Coverage** — Run: `forge coverage --report summary`. Report the line/branch coverage for `src/AlphaVault.sol` and confirm the new branches (`_isBelowFloor` true/false at each call site, setter cap, bubble paths) are exercised; name any uncovered new branch and why.
- [ ] **Step 7: Self review** — Invoke the `code-review` skill on the working-tree diff and address findings.
- [ ] **Step 8: Security audit** — Invoke the `security-audit` skill if available, otherwise the `security-review` skill; if neither is available, state that explicitly in the final report rather than skipping silently. Resolve or explicitly justify every finding.
- [ ] **Step 9: Report** — Summarize: what changed per file, test results, coverage, snapshot status, review/audit findings and resolutions. **Do NOT commit — the user commits.**

---

## Acceptance criteria (the executor must be able to answer YES to all)

1. No `try`/`catch` remains in `wrap`, `_sweepRotatedStake`, `_drainAssets`, or `unwrapForTao`. Exactly one try/catch remains in the contract: `_rebalanceStep` (untouched).
2. Every skip decision is a pre-call `_isBelowFloor` check; nothing is skipped because a call reverted.
3. `test_RevertWhen_AboveFloorOrphanSweepFails` proves a non-dust orphan can no longer be silently dropped from tracking.
4. `test_RevertWhen_AboveFloorDrainSliceFails` and `test_RevertWhen_AboveFloorPartialSellFails` prove non-dust exit slices can no longer be silently forfeited.
5. The pre-existing dust/floor suites in MinStakeTaoFloor.t.sol and UnwrapForTao.t.sol pass with their assertions intact (except the two expectation updates this plan names explicitly).
6. `minStakeTaoFloor` is owner-tunable, capped at 1e9, defaulted to 2e6, and used by every classifier call.
7. `forge fmt --check`, `forge build` (zero warnings), `forge test`, `forge snapshot --check --tolerance 1` all clean; coverage reported; review + audit findings addressed.
8. Nothing was committed.
