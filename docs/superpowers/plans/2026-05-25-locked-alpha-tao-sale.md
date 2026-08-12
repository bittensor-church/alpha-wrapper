# Locked-Alpha TAO Sale Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `withdrawForTao` and `reclaimMailboxAlphaAsTao` to `AlphaVault` so holders can exit to native TAO via `IStaking.removeStake`, which bypasses the per-netuid `TransferToggle` that blocks the existing transfer-based withdraw paths.

**Architecture:** Two new entry points on `AlphaVault` -> `CloneBase.sellAlphaForTao` (calling staking precompile `removeStake`, idx 2053) -> TAO credited to clone's `HashedAddressMapping` EVM balance -> `CloneBase.withdrawTao` forwards to caller. Slippage protection enforced at the EVM layer by snapshotting `clone.balance` delta and comparing to caller-supplied `minTaoOut`. Vault path drains the union of `getBestValidators(netuid)` and `_lastSeenHotkeys[tokenId]` (deduplicated, order-independent).

**Tech Stack:** Solidity 0.8.20, Foundry (forge), OpenZeppelin contracts (ReentrancyGuard, Address, ERC1155, Clones), EIP-1167 minimal proxies, Bittensor subtensor staking precompile (0x0805).

**Source spec:** `docs/superpowers/specs/2026-05-25-locked-alpha-tao-sale-design.md`. Read it before starting.

**Commit policy:** Do NOT commit on the user's behalf. After each task's steps pass, prompt the user to review the diff and commit themselves. Plan steps say "Stop and let user review/commit"  -  do not run `git commit`.

**Style enforcement:** Every code change in this plan obeys these rules (the spec's Implementation Style section is the source of truth):

- One statement per line. No `if (x) { y; }` collapsed to a single line. No `a = b; c = d;`.
- ASCII only. No box drawing, em-dashes, smart quotes.
- Comments explain WHY, not WHAT. No restating-the-code. No alternatives-considered. No file/line/ticket references that rot. No identifier names except in NatSpec `@param`/`@return`.

---

## File Structure

**Created:**
- `test/AlphaVaultTestBase.sol` - abstract base lifted from `AlphaVault.t.sol` (state, `setUp`, helpers)
- `test/WithdrawForTao.t.sol` - vault-path tests
- `test/ReclaimMailboxAlphaAsTao.t.sol` - mailbox-path tests

**Modified:**
- `src/interfaces/IStaking.sol` - one new function signature
- `src/CloneBase.sol` - one new method
- `src/AlphaVault.sol` - one new error, two new events, two new external functions, one internal helper
- `test/mocks/MockStaking.sol` - new `removeStake` plus rate + revert toggle
- `test/AlphaVault.t.sol` - replace its `AttestationHelper` base with `AlphaVaultTestBase` and remove duplicated state, `setUp` body, and helpers

---

## Task 1: Refactor - extract `AlphaVaultTestBase`

**Files:**
- Create: `test/AlphaVaultTestBase.sol`
- Modify: `test/AlphaVault.t.sol`

The refactor is a no-op behaviorally. Acceptance criterion: `forge test` produces an identical per-test pass/fail report before and after.

- [ ] **Step 1: Snapshot current test results**

Run: `forge test --summary > /tmp/before.txt 2>&1`

This file is the baseline for the acceptance check at the end of this task.

- [ ] **Step 2: Create `test/AlphaVaultTestBase.sol`**

Copy lines 1-214 of the current `test/AlphaVault.t.sol` into a new file `test/AlphaVaultTestBase.sol`, then make these edits:

- Replace `contract AlphaVaultTest is AttestationHelper` with `abstract contract AlphaVaultTestBase is AttestationHelper`.
- Change `function setUp() public` to `function setUp() public virtual`.
- Change every private helper to internal: `_setValidators`, `_hks1`, `_hks2`, `_hks3`, `_wts1`, `_wts2`, `_wts3`, `_countRebalancedLogs`, `_toSubstrate`, `_simulateAlphaDeposit`, `_simulateAlphaDepositHotkey`, `_processDeposit`, `_processDepositHotkey`, `_getStake`, `_subnetColdkey`, `_getVaultStake`, `_totalVaultStakeAcrossHotkeys`, `_setRegBlock`, `_simulateTaoAwardedOnDissolution`, `_simulateDissolutionCompleted`, `_simulateNewNetworkRegistered`, `_simulateDissolutionStarted`.
- Keep `_simulateEmissions` PRIVATE in this file and DO NOT remove from `AlphaVault.t.sol` later  -  it is used only by `AlphaVault.t.sol`.

  Wait  -  `_simulateEmissions` is currently in `AlphaVault.t.sol`. Decision: do not lift it. Delete it from the copy.

- Keep all event declarations (`SubnetProxyCreated`, `Rebalanced`, `MinStakeTaoFloorUpdated`, `Deposited`).
- Drop the test functions: this new file should contain only state, events, `setUp`, and helpers  -  no `test_*` functions.

- [ ] **Step 3: Refactor `test/AlphaVault.t.sol` to inherit from the base**

In `test/AlphaVault.t.sol`:

- Add `import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";`
- Change `contract AlphaVaultTest is AttestationHelper` to `contract AlphaVaultTest is AlphaVaultTestBase`.
- Delete the duplicated state declarations now in the base (everything from `AlphaVault public vault;` through `uint256 public TOKEN2;`).
- Delete the duplicated event declarations now in the base.
- Delete the entire `setUp()` body and the duplicated helpers (everything from line 51 through line 214 of the original file). Keep `_simulateEmissions` (it stays only here).
- Remove now-unused imports if they are exclusively pulled by the base (e.g., `MockAddressMapping`, `MockStorageQuery`). Keep imports still used by `AlphaVault.t.sol`'s tests.

- [ ] **Step 4: Run forge test, confirm identical results**

Run: `forge test --summary > /tmp/after.txt 2>&1`

Then: `diff /tmp/before.txt /tmp/after.txt`

Expected: zero diff. If any test changes status, fix the refactor  -  do not edit any test bodies to mask a regression.

- [ ] **Step 5: Stop and let user review/commit**

Show: `git status` and `git diff --stat`. Suggested commit message: `test: extract AlphaVaultTestBase from AlphaVault.t.sol`. Do not run `git commit`.

---

## Task 2: Add `removeStake` to `IStaking` and extend `MockStaking`

**Files:**
- Modify: `src/interfaces/IStaking.sol`
- Modify: `test/mocks/MockStaking.sol`

This is plumbing-only: an interface line and a mock implementation. The mock test in Step 4 below is the first failing test of the feature.

- [ ] **Step 1: Add `removeStake` to `IStaking.sol`**

Add inside the `interface IStaking` block, next to `transferStake`/`moveStake`/`getStake`:

```solidity
function removeStake(bytes32 hotkey, uint256 netuid, uint256 amount) external;
```

No NatSpec needed in the interface beyond what is consistent with the file  -  match neighboring entries' style.

- [ ] **Step 2: Write a failing unit test for `MockStaking.removeStake`**

Add `test/MockStaking.t.sol` (new file):

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { MockStaking } from "./mocks/MockStaking.sol";

contract MockStakingTest is Test {
    MockStaking staking;
    bytes32 constant HOTKEY = keccak256("hk");
    uint256 constant NETUID = 1;

    function setUp() public {
        staking = new MockStaking();
        vm.deal(address(staking), 1000 ether);
    }

    function test_RemoveStake_ReducesStakeAndCreditsCaller() public {
        bytes32 caller = keccak256(abi.encodePacked("evm:", address(this)));
        staking.setStake(HOTKEY, caller, NETUID, 100 ether);
        staking.setRemoveStakeRate(1, 1);
        uint256 balanceBefore = address(this).balance;

        staking.removeStake(HOTKEY, NETUID, 40 ether);

        assertEq(staking.getStake(HOTKEY, caller, NETUID), 60 ether);
        assertEq(address(this).balance - balanceBefore, 40 ether);
    }

    function test_RemoveStake_RevertsWhenToggled() public {
        bytes32 caller = keccak256(abi.encodePacked("evm:", address(this)));
        staking.setStake(HOTKEY, caller, NETUID, 100 ether);
        staking.setRemoveStakeRate(1, 1);
        staking.setRemoveStakeReverts(true);

        vm.expectRevert();
        staking.removeStake(HOTKEY, NETUID, 1 ether);
    }

    receive() external payable { }
}
```

- [ ] **Step 3: Run the test, confirm it fails**

Run: `forge test --match-contract MockStakingTest -vv`

Expected: compilation error (no `removeStake`, no `setRemoveStakeRate`, no `setRemoveStakeReverts` on `MockStaking`).

- [ ] **Step 4: Extend `test/mocks/MockStaking.sol`**

Add to the contract:

```solidity
uint256 public taoPerAlpha;
uint256 public taoPerAlphaDenom;
bool public removeStakeReverts;

function setRemoveStakeRate(uint256 num, uint256 denom) external {
    taoPerAlpha = num;
    taoPerAlphaDenom = denom;
}

function setRemoveStakeReverts(bool v) external {
    removeStakeReverts = v;
}

function removeStake(bytes32 hotkey, uint256 netuid, uint256 alphaAmount) external {
    if (removeStakeReverts) {
        revert("MockStaking: removeStake reverted");
    }
    stakes[hotkey][_senderColdkey()][netuid] -= alphaAmount;
    uint256 taoOut = (alphaAmount * taoPerAlpha) / taoPerAlphaDenom;
    (bool ok,) = msg.sender.call{ value: taoOut }("");
    require(ok, "MockStaking: TAO credit failed");
}
```

- [ ] **Step 5: Run the test, confirm it passes**

Run: `forge test --match-contract MockStakingTest -vv`

Expected: both tests pass.

- [ ] **Step 6: Stop and let user review/commit**

Suggested commit message: `feat: add removeStake to IStaking and MockStaking`.

---

## Task 3: Add `sellAlphaForTao` to `CloneBase`

**Files:**
- Modify: `src/CloneBase.sol`
- Create: `test/CloneBase.t.sol` (small isolation test)

- [ ] **Step 1: Write a failing test**

Create `test/CloneBase.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { SubnetClone } from "src/SubnetClone.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract CloneBaseSellAlphaTest is Test {
    SubnetClone clone;
    bytes32 constant HOTKEY = keccak256("hk");
    uint256 constant NETUID = 1;

    function setUp() public {
        vm.etch(STAKING_PRECOMPILE, address(new MockStaking()).code);
        vm.deal(STAKING_PRECOMPILE, 1000 ether);
        MockStaking(STAKING_PRECOMPILE).setRemoveStakeRate(1, 1);

        SubnetClone impl = new SubnetClone();
        clone = SubnetClone(payable(Clones.clone(address(impl))));
        clone.initialize(address(this));

        bytes32 cloneColdkey = keccak256(abi.encodePacked("evm:", address(clone)));
        MockStaking(STAKING_PRECOMPILE).setStake(HOTKEY, cloneColdkey, NETUID, 50 ether);
    }

    function test_SellAlphaForTao_CreditsCloneNativeBalance() public {
        uint256 before = address(clone).balance;
        clone.sellAlphaForTao(HOTKEY, NETUID, 30 ether);
        assertEq(address(clone).balance - before, 30 ether);
    }

    function test_SellAlphaForTao_NoOpOnZero() public {
        uint256 before = address(clone).balance;
        clone.sellAlphaForTao(HOTKEY, NETUID, 0);
        assertEq(address(clone).balance, before);
    }

    function test_SellAlphaForTao_OnlyWrapper() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        clone.sellAlphaForTao(HOTKEY, NETUID, 1);
    }
}
```

- [ ] **Step 2: Run the test, confirm it fails (compile error)**

Run: `forge test --match-contract CloneBaseSellAlphaTest -vv`

Expected: compilation error - `sellAlphaForTao` not defined.

- [ ] **Step 3: Add `sellAlphaForTao` to `CloneBase.sol`**

Insert next to `flush` and `withdrawTao`:

```solidity
/// @notice Convert alpha stake held by this clone into native TAO via the staking precompile.
/// @dev    No-op when `amount == 0`. Callable only by the wrapper.
/// @param  hotkey Hotkey under which the alpha sits.
/// @param  netuid Subnet id.
/// @param  amount Alpha amount to swap.
function sellAlphaForTao(bytes32 hotkey, uint256 netuid, uint256 amount) external onlyWrapper {
    if (amount > 0) {
        IStaking(STAKING_PRECOMPILE).removeStake(hotkey, netuid, amount);
    }
}
```

- [ ] **Step 4: Run the test, confirm it passes**

Run: `forge test --match-contract CloneBaseSellAlphaTest -vv`

Expected: 3 passes.

- [ ] **Step 5: Stop and let user review/commit**

Suggested commit message: `feat: add CloneBase.sellAlphaForTao`.

---

## Task 4: Add `SlippageExceeded`, events, and `_drainCandidates` to `AlphaVault`

This task lands the supporting declarations and the pure-view helper. No new entry-point behavior yet; the new functions are added but stubbed in Task 5.

**Files:**
- Modify: `src/AlphaVault.sol`

- [ ] **Step 1: Add error and events near existing declarations**

In the errors block (around line 88, after `ChosenHotkeyNotInSet`):

```solidity
error SlippageExceeded(uint256 taoOut, uint256 minTaoOut);
```

In the events block (after `Deposited` and other events near the top of the contract):

```solidity
event WithdrawnForTao(address indexed user, uint256 indexed tokenId, uint256 shares, uint256 assetsBurned, uint256 taoOut);
event MailboxAlphaSoldForTao(address indexed user, uint256 indexed netuid, bytes32 indexed hotkey, uint256 alpha, uint256 taoOut);
```

- [ ] **Step 2: Add the `_drainCandidates` internal view helper**

Insert in the private/internal helper region (near `_sweepRotatedStake` and `lastSeenHotkeys`):

```solidity
/// @dev Returns the deduplicated union of the current validator set and `_lastSeenHotkeys[tokenId]`,
///      together with each entry's stake under the clone's coldkey. Order is not significant.
function _drainCandidates(uint256 tokenId, uint16 netuid)
    internal
    view
    returns (bytes32[6] memory hotkeys, uint256[6] memory balances, uint256 totalStakeOut)
{
    (bytes32[3] memory current,) = validatorRegistry.getValidators(netuid);
    bytes32[3] memory historical = _lastSeenHotkeys[tokenId];

    uint256 n = 0;
    for (uint256 i = 0; i < 3; i++) {
        bytes32 hk = historical[i];
        if (hk == bytes32(0)) {
            continue;
        }
        hotkeys[n] = hk;
        n++;
    }
    for (uint256 i = 0; i < 3; i++) {
        bytes32 hk = current[i];
        if (hk == bytes32(0)) {
            continue;
        }
        bool seen = false;
        for (uint256 j = 0; j < n; j++) {
            if (hotkeys[j] == hk) {
                seen = true;
                break;
            }
        }
        if (seen) {
            continue;
        }
        hotkeys[n] = hk;
        n++;
    }

    address clone = subnetClone[tokenId];
    if (clone == address(0)) {
        return (hotkeys, balances, 0);
    }
    bytes32 coldkey = _coldkeyOf(clone);
    IStaking staking = IStaking(STAKING_PRECOMPILE);
    for (uint256 i = 0; i < n; i++) {
        uint256 bal = staking.getStake(hotkeys[i], coldkey, netuid);
        balances[i] = bal;
        totalStakeOut += bal;
    }
}
```

Verify against current source: `validatorRegistry.getValidators(uint256)` returns `(bytes32[3], uint16[3])`. If the cast `uint16 netuid` -> `uint256` parameter is needed, adjust at the call site by widening. The existing helper `_netuid(tokenId)` returns `uint16` (line 675 of `AlphaVault.sol`).

- [ ] **Step 3: Compile-check (no runtime test yet)**

Run: `forge build`

Expected: clean build. The helper is unused at this point, which the compiler will warn about  -  that resolves in Task 5.

- [ ] **Step 4: Stop and let user review/commit**

Suggested commit message: `feat: add SlippageExceeded, TAO-rail events, and _drainCandidates`.

---

## Task 5: Add shared TAO-rail test helpers to `AlphaVaultTestBase`

**Files:**
- Modify: `test/AlphaVaultTestBase.sol`

These helpers are used by both `WithdrawForTao.t.sol` and `ReclaimMailboxAlphaAsTao.t.sol`. Land them now so subsequent task tests can call them.

- [ ] **Step 1: Add the helpers**

```solidity
function _setRemoveStakeRate(uint256 num, uint256 denom) internal {
    MockStaking(STAKING_PRECOMPILE).setRemoveStakeRate(num, denom);
}

function _setRemoveStakeReverts(bool v) internal {
    MockStaking(STAKING_PRECOMPILE).setRemoveStakeReverts(v);
}

function _donateToClone(address clone, uint256 amount) internal {
    vm.deal(clone, clone.balance + amount);
}

function _expectedTaoFor(uint256 alpha) internal view returns (uint256) {
    uint256 num = MockStaking(STAKING_PRECOMPILE).taoPerAlpha();
    uint256 denom = MockStaking(STAKING_PRECOMPILE).taoPerAlphaDenom();
    return (alpha * num) / denom;
}
```

- [ ] **Step 2: Pre-fund the precompile in `setUp`**

Inside `AlphaVaultTestBase.setUp()`, after the three `vm.etch` lines, add:

```solidity
vm.deal(STAKING_PRECOMPILE, 1_000_000 ether);
```

This ensures `removeStake`'s `.call{value:}` credit succeeds in every test.

- [ ] **Step 3: Compile-check**

Run: `forge build`

Expected: clean.

- [ ] **Step 4: Run full test suite, confirm nothing regressed**

Run: `forge test --summary`

Expected: same pass count as after Task 1.

- [ ] **Step 5: Stop and let user review/commit**

Suggested commit message: `test: add shared TAO-rail helpers to AlphaVaultTestBase`.

---

## Task 6: Implement `withdrawForTao` and the H1 happy path

**Files:**
- Modify: `src/AlphaVault.sol`
- Create: `test/WithdrawForTao.t.sol`

- [ ] **Step 1: Write the H1 test**

Create `test/WithdrawForTao.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";

contract WithdrawForTaoTest is AlphaVaultTestBase {
    function _depositForAlice(uint256 amount) internal returns (uint256 shares) {
        _simulateAlphaDeposit(alice, NETUID1, amount);
        _processDeposit(alice, NETUID1);
        shares = vault.balanceOf(alice, TOKEN1);
    }

    function test_H1_SingleHotkey_FullBurn() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);
        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), 0);
        assertEq(alice.balance - aliceBalanceBefore, 100 ether);
        assertEq(vault.totalStake(TOKEN1), 0);
    }

    receive() external payable { }
}
```

- [ ] **Step 2: Run the test, confirm it fails (compile error)**

Run: `forge test --match-contract WithdrawForTaoTest -vv`

Expected: `withdrawForTao` not defined.

- [ ] **Step 3: Implement `withdrawForTao` in `AlphaVault.sol`**

Insert next to the existing `withdraw` (around line 204):

```solidity
/// @notice Burn vault shares pro-rata and pay the caller native TAO from swapping the backing alpha.
/// @dev    Uses `IStaking.removeStake`, which is not gated by `TransferToggle`, so this exit is
///         available even when the regular alpha-rail `withdraw` is blocked.
/// @param  tokenId    Vault token id (encodes netuid + reg block).
/// @param  shares     Shares to burn.
/// @param  minTaoOut  Slippage floor; revert if realized TAO is less.
function withdrawForTao(uint256 tokenId, uint256 shares, uint256 minTaoOut) external nonReentrant {
    if (shares == 0) {
        revert ZeroAmount();
    }
    if (balanceOf(msg.sender, tokenId) < shares) {
        revert InsufficientShares();
    }
    address clone = subnetClone[tokenId];
    if (clone == address(0)) {
        revert NothingToWithdraw();
    }
    uint16 netuid = _netuid(tokenId);
    if (StorageQueryReader.isNetuidInDissolvedQueue(netuid)) {
        revert SubnetInDissolutionBlackoutPeriod();
    }
    if (_isIssuedForDissolvedSubnet(tokenId)) {
        revert SubnetDissolved();
    }

    (bytes32[6] memory hotkeys, uint256[6] memory balances, uint256 total) = _drainCandidates(tokenId, netuid);
    if (total == 0) {
        revert NothingToWithdraw();
    }

    totalStake[tokenId] = total;
    uint256 assets = _convertToAssets(tokenId, shares);
    if (assets == 0) {
        revert ZeroAmount();
    }

    _burn(msg.sender, tokenId, shares);
    totalStake[tokenId] -= assets;

    uint256 balanceBefore = clone.balance;
    uint256 remaining = assets;
    for (uint256 i = 0; i < 6; i++) {
        if (remaining == 0) {
            break;
        }
        uint256 bal = balances[i];
        if (bal == 0) {
            continue;
        }
        uint256 take = bal < remaining ? bal : remaining;
        SubnetClone(payable(clone)).sellAlphaForTao(hotkeys[i], netuid, take);
        remaining -= take;
    }

    uint256 taoOut = clone.balance - balanceBefore;
    if (taoOut < minTaoOut) {
        revert SlippageExceeded(taoOut, minTaoOut);
    }

    SubnetClone(payable(clone)).withdrawTao(payable(msg.sender), taoOut);
    emit WithdrawnForTao(msg.sender, tokenId, shares, assets, taoOut);
}
```

- [ ] **Step 4: Run the H1 test, confirm it passes**

Run: `forge test --match-test test_H1 -vv`

Expected: pass.

- [ ] **Step 5: Run the full suite, confirm no regressions**

Run: `forge test`

Expected: every existing test still passes; new test passes.

- [ ] **Step 6: Stop and let user review/commit**

Suggested commit message: `feat: implement withdrawForTao`.

---

## Task 7: WithdrawForTao H2-H6 (multi-hotkey and slippage boundary)

**Files:**
- Modify: `test/WithdrawForTao.t.sol`

These tests exercise the existing `withdrawForTao` implementation; no source changes expected.

- [ ] **Step 1: Add H2-H6 tests**

```solidity
function test_H2_TwoHotkeys_PartialBurn() public {
    _setRemoveStakeRate(1, 1);
    uint256 shares = _depositForAlice(100 ether);

    bytes32 cloneCk = _subnetColdkey(NETUID1);
    MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, cloneCk, NETUID1, 60 ether);
    MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, cloneCk, NETUID1, 40 ether);

    uint256 half = shares / 2;
    uint256 balanceBefore = alice.balance;

    vm.prank(alice);
    vault.withdrawForTao(TOKEN1, half, 0);

    assertEq(alice.balance - balanceBefore, 50 ether);
}

function test_H3_RotatedOutHotkey_DrainedViaLastSeen() public {
    _setRemoveStakeRate(1, 1);
    uint256 shares = _depositForAlice(100 ether);

    bytes32 cloneCk = _subnetColdkey(NETUID1);
    MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, cloneCk, NETUID1, 0);
    MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, cloneCk, NETUID1, 100 ether);

    _setValidators(NETUID1, _hks1(hotkey4), _wts1(10000));
    bytes32 cloneCkAfter = _subnetColdkey(NETUID1);
    MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, cloneCkAfter, NETUID1, 100 ether);

    uint256 balanceBefore = alice.balance;

    vm.prank(alice);
    vault.withdrawForTao(TOKEN1, shares, 0);

    assertEq(alice.balance - balanceBefore, 100 ether);
}

function test_H4_DuplicateHotkey_DedupedDrainedOnce() public {
    _setRemoveStakeRate(1, 1);
    uint256 shares = _depositForAlice(100 ether);

    bytes32 cloneCk = _subnetColdkey(NETUID1);
    MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, cloneCk, NETUID1, 100 ether);

    uint256 balanceBefore = alice.balance;
    vm.prank(alice);
    vault.withdrawForTao(TOKEN1, shares, 0);

    assertEq(alice.balance - balanceBefore, 100 ether);
}

function test_H5_MinTaoOutZero() public {
    _setRemoveStakeRate(1, 100);
    uint256 shares = _depositForAlice(100 ether);

    vm.prank(alice);
    vault.withdrawForTao(TOKEN1, shares, 0);
}

function test_H6_MinTaoOutExactBoundary() public {
    _setRemoveStakeRate(1, 1);
    uint256 shares = _depositForAlice(100 ether);
    uint256 expected = _expectedTaoFor(100 ether);

    vm.prank(alice);
    vault.withdrawForTao(TOKEN1, shares, expected);
}
```

- [ ] **Step 2: Run, confirm all pass**

Run: `forge test --match-contract WithdrawForTaoTest -vv`

Expected: H1-H6 all pass.

- [ ] **Step 3: Stop and let user review/commit**

Suggested commit message: `test: WithdrawForTao H2-H6 (multi-hotkey, slippage boundary)`.

---

## Task 8: WithdrawForTao R1-R5 (input validation and dissolution)

**Files:**
- Modify: `test/WithdrawForTao.t.sol`

- [ ] **Step 1: Add R1-R5 tests**

```solidity
function test_R1_RevertWhen_SharesZero() public {
    _depositForAlice(100 ether);
    vm.prank(alice);
    vm.expectRevert(AlphaVault.ZeroAmount.selector);
    vault.withdrawForTao(TOKEN1, 0, 0);
}

function test_R2_RevertWhen_SharesExceedBalance() public {
    uint256 shares = _depositForAlice(100 ether);
    vm.prank(alice);
    vm.expectRevert(AlphaVault.InsufficientShares.selector);
    vault.withdrawForTao(TOKEN1, shares + 1, 0);
}

function test_R3_RevertWhen_NoCloneForToken() public {
    uint256 fakeToken = (uint256(999) << 16) | uint256(NETUID1);
    vm.expectRevert(AlphaVault.NothingToWithdraw.selector);
    vault.withdrawForTao(fakeToken, 1, 0);
}

function test_R4_RevertWhen_NetuidInDissolutionQueue() public {
    uint256 shares = _depositForAlice(100 ether);
    _simulateDissolutionStarted(TOKEN1, 100);
    vm.prank(alice);
    vm.expectRevert(AlphaVault.SubnetInDissolutionBlackoutPeriod.selector);
    vault.withdrawForTao(TOKEN1, shares, 0);
}

function test_R5_RevertWhen_SubnetDissolved() public {
    uint256 shares = _depositForAlice(100 ether);
    _simulateNewNetworkRegistered(TOKEN1, 999, 0);
    vm.prank(alice);
    vm.expectRevert(AlphaVault.SubnetDissolved.selector);
    vault.withdrawForTao(TOKEN1, shares, 0);
}
```

- [ ] **Step 2: Run, confirm all pass**

Run: `forge test --match-contract WithdrawForTaoTest --match-test "test_R[1-5]" -vv`

Expected: 5 passes.

- [ ] **Step 3: Stop and let user review/commit**

Suggested commit message: `test: WithdrawForTao R1-R5 (input validation, dissolution)`.

---

## Task 9: WithdrawForTao R6-R9 (downstream reverts)

**Files:**
- Modify: `test/WithdrawForTao.t.sol`

- [ ] **Step 1: Add R6-R9 tests**

```solidity
function test_R6_RevertWhen_AllUnionHotkeysEmpty() public {
    uint256 shares = _depositForAlice(100 ether);

    bytes32 cloneCk = _subnetColdkey(NETUID1);
    MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, cloneCk, NETUID1, 0);
    MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, cloneCk, NETUID1, 0);
    MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, cloneCk, NETUID1, 0);

    vm.prank(alice);
    vm.expectRevert(AlphaVault.NothingToWithdraw.selector);
    vault.withdrawForTao(TOKEN1, shares, 0);
}

function test_R7_RevertWhen_AssetsRoundsToZero() public {
    _setRemoveStakeRate(1, 1);
    _simulateAlphaDeposit(alice, NETUID1, 1_000_000 ether);
    _processDeposit(alice, NETUID1);

    vm.prank(alice);
    vm.expectRevert(AlphaVault.ZeroAmount.selector);
    vault.withdrawForTao(TOKEN1, 1, 0);
}

function test_R8_RevertWhen_SlippageExceeded() public {
    _setRemoveStakeRate(1, 1);
    uint256 shares = _depositForAlice(100 ether);
    uint256 expected = _expectedTaoFor(100 ether);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(AlphaVault.SlippageExceeded.selector, expected, expected + 1));
    vault.withdrawForTao(TOKEN1, shares, expected + 1);
}

function test_R9_RevertBubblesUpFromSubtensorRemoveStake() public {
    _setRemoveStakeRate(1, 1);
    uint256 shares = _depositForAlice(100 ether);
    _setRemoveStakeReverts(true);

    vm.prank(alice);
    vm.expectRevert();
    vault.withdrawForTao(TOKEN1, shares, 0);

    assertEq(vault.balanceOf(alice, TOKEN1), shares);
}
```

- [ ] **Step 2: Run, confirm all pass**

Run: `forge test --match-contract WithdrawForTaoTest --match-test "test_R[6-9]" -vv`

Expected: 4 passes. R7 may need rate tuning if the chosen ratio rounds differently  -  adjust the deposit or shares value until the pro-rata math rounds to zero for exactly `shares = 1`. (Hint: with 1_000_000 ether of stake matched to the same shares supply, 1 share -> 1 unit, but virtual-share offset may protect. Inspect `_assetsFor` to compute.)

- [ ] **Step 3: Stop and let user review/commit**

Suggested commit message: `test: WithdrawForTao R6-R9 (downstream reverts)`.

---

## Task 10: WithdrawForTao R10 (alternative-exit when alpha rail blocked)

**Files:**
- Modify: `test/mocks/MockStaking.sol` (add toggle for `transferStake` revert)
- Modify: `test/AlphaVaultTestBase.sol` (helper to flip the toggle)
- Modify: `test/WithdrawForTao.t.sol`

- [ ] **Step 1: Add a `transferStake` revert toggle to `MockStaking`**

Inside `MockStaking`:

```solidity
bool public transferStakeReverts;

function setTransferStakeReverts(bool v) external {
    transferStakeReverts = v;
}
```

And at the start of `transferStake`:

```solidity
if (transferStakeReverts) {
    revert("MockStaking: transferStake reverted");
}
```

(Apply the same gate at the start of `moveStake` since `_sweepRotatedStake` calls it on the alpha rail.)

```solidity
bool public moveStakeReverts;

function setMoveStakeReverts(bool v) external {
    moveStakeReverts = v;
}
```

And at the start of `moveStake`:

```solidity
if (moveStakeReverts) {
    revert("MockStaking: moveStake reverted");
}
```

- [ ] **Step 2: Add helpers to `AlphaVaultTestBase`**

```solidity
function _simulateTransferToggleOn() internal {
    MockStaking(STAKING_PRECOMPILE).setTransferStakeReverts(true);
    MockStaking(STAKING_PRECOMPILE).setMoveStakeReverts(true);
}
```

- [ ] **Step 3: Add the R10 test**

```solidity
function test_R10_AlphaRailBlocked_TaoRailStillWorks() public {
    _setRemoveStakeRate(1, 1);
    uint256 shares = _depositForAlice(100 ether);

    _simulateTransferToggleOn();

    bytes32 dest = keccak256("dest");
    vm.prank(alice);
    vm.expectRevert();
    vault.withdraw(TOKEN1, shares, dest);

    uint256 balanceBefore = alice.balance;
    vm.prank(alice);
    vault.withdrawForTao(TOKEN1, shares, 0);
    assertEq(alice.balance - balanceBefore, 100 ether);
}
```

- [ ] **Step 4: Run, confirm pass**

Run: `forge test --match-test test_R10 -vv`

Expected: pass.

- [ ] **Step 5: Run full suite, confirm no regressions**

Run: `forge test`

Expected: green. (Existing tests do not flip the toggles, so they remain unaffected by the default-false values.)

- [ ] **Step 6: Stop and let user review/commit**

Suggested commit message: `test: WithdrawForTao R10 (alternative exit under TransferToggle)`.

---

## Task 11: WithdrawForTao A1-A3 (donation, receiver, reentrancy)

**Files:**
- Modify: `test/WithdrawForTao.t.sol`

- [ ] **Step 1: Add A1-A3 tests and helper contracts**

```solidity
contract RevertingReceiver {
    receive() external payable {
        revert("nope");
    }
}

contract ReentrantReceiver {
    AlphaVault target;
    uint256 tokenId;
    uint256 shares;

    function arm(AlphaVault t, uint256 tid, uint256 s) external {
        target = t;
        tokenId = tid;
        shares = s;
    }

    receive() external payable {
        target.withdrawForTao(tokenId, shares, 0);
    }
}

// In WithdrawForTaoTest:

function test_A1_DonationDoesNotInflateTaoOut() public {
    _setRemoveStakeRate(1, 1);
    uint256 shares = _depositForAlice(100 ether);

    address clone = vault.subnetClone(TOKEN1);
    _donateToClone(clone, 5 ether);

    uint256 balanceBefore = alice.balance;
    vm.prank(alice);
    vault.withdrawForTao(TOKEN1, shares, 0);

    assertEq(alice.balance - balanceBefore, 100 ether);
    assertEq(clone.balance, 5 ether);
}

function test_A2_RevertWhen_ReceiverRevertsOnReceive() public {
    _setRemoveStakeRate(1, 1);
    RevertingReceiver receiver = new RevertingReceiver();
    _simulateAlphaDeposit(address(receiver), NETUID1, 100 ether);
    _processDeposit(address(receiver), NETUID1);
    uint256 shares = vault.balanceOf(address(receiver), TOKEN1);

    vm.prank(address(receiver));
    vm.expectRevert();
    vault.withdrawForTao(TOKEN1, shares, 0);

    assertEq(vault.balanceOf(address(receiver), TOKEN1), shares);
}

function test_A3_RevertWhen_ReceiverReenters() public {
    _setRemoveStakeRate(1, 1);
    ReentrantReceiver receiver = new ReentrantReceiver();
    _simulateAlphaDeposit(address(receiver), NETUID1, 100 ether);
    _processDeposit(address(receiver), NETUID1);
    uint256 shares = vault.balanceOf(address(receiver), TOKEN1);
    receiver.arm(vault, TOKEN1, shares);

    vm.prank(address(receiver));
    vm.expectRevert();
    vault.withdrawForTao(TOKEN1, shares, 0);
}
```

- [ ] **Step 2: Run, confirm pass**

Run: `forge test --match-test "test_A[1-3]" -vv`

Expected: 3 passes.

- [ ] **Step 3: Stop and let user review/commit**

Suggested commit message: `test: WithdrawForTao A1-A3 (donation, receiver, reentrancy)`.

---

## Task 12: WithdrawForTao A4-A5 (multi-user, alpha-rail coexistence)

**Files:**
- Modify: `test/WithdrawForTao.t.sol`

- [ ] **Step 1: Add A4-A5 tests**

```solidity
function test_A4_TwoUsers_ProRataConsistent() public {
    _setRemoveStakeRate(1, 1);
    uint256 aliceShares = _depositForAlice(100 ether);

    _simulateAlphaDeposit(bob, NETUID1, 100 ether);
    _processDeposit(bob, NETUID1);
    uint256 bobShares = vault.balanceOf(bob, TOKEN1);

    uint256 aliceBalanceBefore = alice.balance;
    vm.prank(alice);
    vault.withdrawForTao(TOKEN1, aliceShares, 0);
    assertEq(alice.balance - aliceBalanceBefore, 100 ether);

    uint256 bobBalanceBefore = bob.balance;
    vm.prank(bob);
    vault.withdrawForTao(TOKEN1, bobShares, 0);
    assertEq(bob.balance - bobBalanceBefore, 100 ether);
}

function test_A5_AlphaRailStillWorksAfterTaoWithdraw() public {
    _setRemoveStakeRate(1, 1);
    uint256 aliceShares = _depositForAlice(100 ether);

    _simulateAlphaDeposit(bob, NETUID1, 100 ether);
    _processDeposit(bob, NETUID1);
    uint256 bobShares = vault.balanceOf(bob, TOKEN1);

    vm.prank(alice);
    vault.withdrawForTao(TOKEN1, aliceShares, 0);

    bytes32 bobDest = keccak256("bobDest");
    vm.prank(bob);
    vault.withdraw(TOKEN1, bobShares, bobDest);

    bytes32 cloneCk = _subnetColdkey(NETUID1);
    assertEq(_getStake(hotkey1, _subnetColdkey(NETUID1) == bobDest ? address(0) : address(0), NETUID1), 0);
    assertEq(vault.balanceOf(bob, TOKEN1), 0);
}
```

If the A5 assertion construction is awkward (the dest substrate coldkey is a bytes32, not an EVM address), simplify to: `assertEq(vault.balanceOf(bob, TOKEN1), 0)` only  -  the cross-coldkey transfer state is already covered by existing alpha-rail tests in `AlphaVault.t.sol`.

- [ ] **Step 2: Run, confirm pass**

Run: `forge test --match-test "test_A[4-5]" -vv`

Expected: 2 passes.

- [ ] **Step 3: Run full suite**

Run: `forge test`

Expected: all green.

- [ ] **Step 4: Stop and let user review/commit**

Suggested commit message: `test: WithdrawForTao A4-A5 (multi-user, alpha-rail coexistence)`.

---

## Task 13: Implement `reclaimMailboxAlphaAsTao` and MH1

**Files:**
- Modify: `src/AlphaVault.sol`
- Create: `test/ReclaimMailboxAlphaAsTao.t.sol`

- [ ] **Step 1: Write the MH1 test**

```solidity
// test/ReclaimMailboxAlphaAsTao.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract ReclaimMailboxAlphaAsTaoTest is AlphaVaultTestBase {
    function _seedMailboxAlpha(address user, uint256 netuid, bytes32 hotkey, uint256 amount) internal {
        address predicted = vault.getDepositAddress(user, netuid);
        bytes32 ck = _toSubstrate(predicted);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey, ck, netuid, amount);
    }

    function test_MH1_HappyPath_AlphaInMailboxConvertedToTao() public {
        _setRemoveStakeRate(1, 1);
        _seedMailboxAlpha(alice, NETUID1, hotkey1, 50 ether);

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.reclaimMailboxAlphaAsTao(NETUID1, hotkey1, 0);

        assertEq(alice.balance - before, 50 ether);
        address predicted = vault.getDepositAddress(alice, NETUID1);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, _toSubstrate(predicted), NETUID1), 0);
    }

    receive() external payable { }
}
```

- [ ] **Step 2: Run the test, confirm it fails**

Run: `forge test --match-contract ReclaimMailboxAlphaAsTaoTest -vv`

Expected: compilation error - `reclaimMailboxAlphaAsTao` not defined.

- [ ] **Step 3: Implement `reclaimMailboxAlphaAsTao`**

In `AlphaVault.sol`, next to `reclaimAlphaFromMailbox`:

```solidity
/// @notice Swap a user's stuck mailbox alpha for native TAO and send it to them.
/// @dev    Uses `IStaking.removeStake`, which is not gated by `TransferToggle`.
/// @param  netuid     Subnet id of the mailbox.
/// @param  hotkey     Hotkey under which the alpha sits in the mailbox.
/// @param  minTaoOut  Slippage floor; revert if realized TAO is less.
function reclaimMailboxAlphaAsTao(uint256 netuid, bytes32 hotkey, uint256 minTaoOut) external nonReentrant {
    if (netuid > type(uint16).max) {
        revert NetuidOutOfRange();
    }
    if (hotkey == bytes32(0)) {
        revert ZeroHotkey();
    }
    address predicted = getDepositAddress(msg.sender, netuid);
    bytes32 mailboxColdkey = _coldkeyOf(predicted);
    uint256 amount = IStaking(STAKING_PRECOMPILE).getStake(hotkey, mailboxColdkey, netuid);
    if (amount == 0) {
        revert ZeroAmount();
    }

    _ensureMailboxClone(msg.sender, netuid);
    uint256 balanceBefore = predicted.balance;
    DepositMailbox(payable(predicted)).sellAlphaForTao(hotkey, netuid, amount);

    uint256 taoOut = predicted.balance - balanceBefore;
    if (taoOut < minTaoOut) {
        revert SlippageExceeded(taoOut, minTaoOut);
    }
    DepositMailbox(payable(predicted)).withdrawTao(payable(msg.sender), taoOut);
    emit MailboxAlphaSoldForTao(msg.sender, netuid, hotkey, amount, taoOut);
}
```

- [ ] **Step 4: Run the test, confirm pass**

Run: `forge test --match-test test_MH1 -vv`

Expected: pass.

- [ ] **Step 5: Run full suite**

Run: `forge test`

Expected: all green.

- [ ] **Step 6: Stop and let user review/commit**

Suggested commit message: `feat: implement reclaimMailboxAlphaAsTao`.

---

## Task 14: ReclaimMailbox MH2-MH3 and MR1-MR5

**Files:**
- Modify: `test/ReclaimMailboxAlphaAsTao.t.sol`

- [ ] **Step 1: Add MH2-MH3 and MR1-MR5 tests**

```solidity
function test_MH2_MinTaoOutZero() public {
    _setRemoveStakeRate(1, 100);
    _seedMailboxAlpha(alice, NETUID1, hotkey1, 50 ether);

    vm.prank(alice);
    vault.reclaimMailboxAlphaAsTao(NETUID1, hotkey1, 0);
}

function test_MH3_TwoUsers_Isolated() public {
    _setRemoveStakeRate(1, 1);
    _seedMailboxAlpha(alice, NETUID1, hotkey1, 50 ether);
    _seedMailboxAlpha(bob, NETUID1, hotkey1, 70 ether);

    uint256 aliceBefore = alice.balance;
    vm.prank(alice);
    vault.reclaimMailboxAlphaAsTao(NETUID1, hotkey1, 0);
    assertEq(alice.balance - aliceBefore, 50 ether);

    address bobMailbox = vault.getDepositAddress(bob, NETUID1);
    assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, _toSubstrate(bobMailbox), NETUID1), 70 ether);
}

function test_MR1_RevertWhen_NetuidOutOfRange() public {
    vm.prank(alice);
    vm.expectRevert(AlphaVault.NetuidOutOfRange.selector);
    vault.reclaimMailboxAlphaAsTao(uint256(type(uint16).max) + 1, hotkey1, 0);
}

function test_MR2_RevertWhen_HotkeyZero() public {
    vm.prank(alice);
    vm.expectRevert(AlphaVault.ZeroHotkey.selector);
    vault.reclaimMailboxAlphaAsTao(NETUID1, bytes32(0), 0);
}

function test_MR3_RevertWhen_NoStake() public {
    vm.prank(alice);
    vm.expectRevert(AlphaVault.ZeroAmount.selector);
    vault.reclaimMailboxAlphaAsTao(NETUID1, hotkey1, 0);
}

function test_MR4_RevertWhen_SlippageExceeded() public {
    _setRemoveStakeRate(1, 1);
    _seedMailboxAlpha(alice, NETUID1, hotkey1, 50 ether);
    uint256 expected = _expectedTaoFor(50 ether);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(AlphaVault.SlippageExceeded.selector, expected, expected + 1));
    vault.reclaimMailboxAlphaAsTao(NETUID1, hotkey1, expected + 1);
}

function test_MR5_RevertBubblesUpFromSubtensorRemoveStake() public {
    _setRemoveStakeRate(1, 1);
    _seedMailboxAlpha(alice, NETUID1, hotkey1, 50 ether);
    _setRemoveStakeReverts(true);

    vm.prank(alice);
    vm.expectRevert();
    vault.reclaimMailboxAlphaAsTao(NETUID1, hotkey1, 0);

    address predicted = vault.getDepositAddress(alice, NETUID1);
    assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, _toSubstrate(predicted), NETUID1), 50 ether);
}
```

- [ ] **Step 2: Run, confirm pass**

Run: `forge test --match-contract ReclaimMailboxAlphaAsTaoTest -vv`

Expected: 7 new passes.

- [ ] **Step 3: Stop and let user review/commit**

Suggested commit message: `test: ReclaimMailbox MH2-MH3 and MR1-MR5`.

---

## Task 15: ReclaimMailbox MA1-MA3 (donation, receiver, reentrancy)

**Files:**
- Modify: `test/ReclaimMailboxAlphaAsTao.t.sol`

- [ ] **Step 1: Add MA1-MA3 tests**

```solidity
contract MailboxRevertingReceiver {
    receive() external payable {
        revert("nope");
    }
}

contract MailboxReentrantReceiver {
    AlphaVault target;
    uint256 netuid;
    bytes32 hotkey;

    function arm(AlphaVault t, uint256 n, bytes32 h) external {
        target = t;
        netuid = n;
        hotkey = h;
    }

    receive() external payable {
        target.reclaimMailboxAlphaAsTao(netuid, hotkey, 0);
    }
}

function test_MA1_PreExistingTaoInMailboxNotDoubleCounted() public {
    _setRemoveStakeRate(1, 1);
    _seedMailboxAlpha(alice, NETUID1, hotkey1, 50 ether);

    address mailbox = vault.getDepositAddress(alice, NETUID1);
    _donateToClone(mailbox, 3 ether);

    uint256 before = alice.balance;
    vm.prank(alice);
    vault.reclaimMailboxAlphaAsTao(NETUID1, hotkey1, 0);

    assertEq(alice.balance - before, 50 ether);
    assertEq(mailbox.balance, 3 ether);
}

function test_MA2_RevertWhen_ReceiverRevertsOnReceive() public {
    _setRemoveStakeRate(1, 1);
    MailboxRevertingReceiver receiver = new MailboxRevertingReceiver();
    _seedMailboxAlpha(address(receiver), NETUID1, hotkey1, 50 ether);

    vm.prank(address(receiver));
    vm.expectRevert();
    vault.reclaimMailboxAlphaAsTao(NETUID1, hotkey1, 0);

    address predicted = vault.getDepositAddress(address(receiver), NETUID1);
    assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, _toSubstrate(predicted), NETUID1), 50 ether);
}

function test_MA3_RevertWhen_ReceiverReenters() public {
    _setRemoveStakeRate(1, 1);
    MailboxReentrantReceiver receiver = new MailboxReentrantReceiver();
    _seedMailboxAlpha(address(receiver), NETUID1, hotkey1, 50 ether);
    receiver.arm(vault, NETUID1, hotkey1);

    vm.prank(address(receiver));
    vm.expectRevert();
    vault.reclaimMailboxAlphaAsTao(NETUID1, hotkey1, 0);
}
```

- [ ] **Step 2: Run, confirm pass**

Run: `forge test --match-test "test_MA" -vv`

Expected: 3 passes.

- [ ] **Step 3: Run the full suite for the final time**

Run: `forge test`

Expected: every test passes.

- [ ] **Step 4: Stop and let user review/commit**

Suggested commit message: `test: ReclaimMailbox MA1-MA3 (donation, receiver, reentrancy)`.

---

## Final acceptance

After Task 15:

- `forge build` clean.
- `forge test` green.
- Coverage of every row in the spec's test matrices: H1-H6, R1-R10, A1-A5, MH1-MH3, MR1-MR5, MA1-MA3.
- No `git commit` was run by the agent at any point  -  every commit was prompted to the user.

## Spec Coverage Self-Review

Mapping every spec section to a task that implements it.

| Spec item | Task |
|---|---|
| `IStaking.removeStake` signature | 2 |
| `MockStaking.removeStake` + rate + revert toggle | 2 |
| `CloneBase.sellAlphaForTao` | 3 |
| `SlippageExceeded`, events | 4 |
| `_drainCandidates` (union + dedup, no sort) | 4 |
| `AlphaVaultTestBase` refactor | 1 |
| Shared TAO-rail helpers in TestBase | 5 |
| `withdrawForTao` implementation | 6 |
| `reclaimMailboxAlphaAsTao` implementation | 13 |
| Vault path H1-H6 | 6, 7 |
| Vault path R1-R10 | 8, 9, 10 |
| Vault path A1-A5 | 11, 12 |
| Mailbox path MH1-MH3 | 13, 14 |
| Mailbox path MR1-MR5 | 14 |
| Mailbox path MA1-MA3 | 15 |
| Implementation Style enforcement | Plan preamble + every code sample |
