# Dust Tracking Redesign Implementation Plan (supersedes the sweep portion of 2026-07-02-floor-dust-classifier.md)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Replace the sweep's "classify-then-drop" semantics with "tolerate-and-track": stake that cannot be consolidated stays tracked (counted, priced, deliverable), and forfeiture happens only through a permissionless, dual-oracle-gated, hard-capped `cleanupDust`. Unify the redemption basis so both exit rails price and deliver from the same tracked union.

**Architecture:** `_lastSeenHotkeys` (bytes32[3] snapshot) becomes `_trackedHotkeys` (bytes32[8] set): current validators are added on every mutator; rotated-out members are removed only when their balance hits zero (successful sweep-move, sold via unwrapForTao, or drained to a redeemer) or via `cleanupDust`. The sweep is a bare try/catch consolidation attempt with NO price oracle. Oracles (spot `getAlphaPrice` + EMA `getMovingAlphaPrice`, both 1e18-scaled at the EVM boundary) are used only on exit-path dust pre-checks (unchanged) and in `cleanupDust`'s forfeiture gate. `_redeem` prices off the full `_totalStake` union and drains current-set-first, then tracked orphans.

**Tech Stack:** Solidity ^0.8.20 via-IR, Foundry, precompiles 0x805 (StakingV2, raw rao) / 0x808 (alpha prices, x1e18).

## Ground truth (verified against subtensor tag v3.4.7-422; do not re-derive)

- Same-subnet transfer/move floor: `spot_price * alpha >= DefaultMinStake (2e6 rao)`, inclusive, NO full-balance exemption. Exact complement of `(alpha * priceE18) / 1e18 < floor`.
- removeStake floors on sim output (spot minus fee) WITH full-balance exemption. The full-balance sell branch in unwrapForTao must NEVER be floor-gated (it is the only exit for sub-floor positions).
- `getAlphaPrice(uint16)` and `getMovingAlphaPrice(uint16)` at 0x808 both return the price scaled 1e18 (internal 1e9 fixed-point truncated to u64, then x1e9 EVM balance conversion). Consequence: subnets priced below 1e-9 TAO/alpha read as price 0 from BOTH oracles — any consumer must treat 0 as "oracle unavailable", never as a real price.
- Stake amounts everywhere raw rao. Chain errors become plain reverts; Solidity try/catch works.

## Why this design (decisions already made with the user — do not relitigate)

1. Sweep failures must never brick user paths AND never silently strand stake. Keep-on-failure in a tracked set achieves both; the previous classify-then-drop forced a choice.
2. `cleanupDust` is PERMISSIONLESS: the gate is objective (both oracles below a hard-capped threshold), so admin liveness is not a dependency. Caller controls only timing.
2b. THE VAULT NEVER FORFEITS. Cleanup first tries to consolidate (moveStake), and when the chain rejects that it SELLS the dust via the floor-exempt full-balance removeStake; the TAO accrues in the subnet clone and is restaked into the current set once the pot clears the chain's add-stake floor. Value re-enters share pricing as alpha for all holders on both rails; the oracle never enters mint/redeem pricing; whatever sits in the pot at dissolution is paid out by the existing dissolved path. The dual-oracle gate's purpose is preventing sales into a manipulated or crashed pool, not bounding forfeiture.
3. Exit paths keep their dust pre-checks and bubble semantics from the classifier change (a revert there costs a retry, never a loss). Blanket try/catch on exits is forbidden (re-creates silent under-delivery).
4. `_rebalanceStep` keeps its try/catch untouched (failed split-optimization loses nothing).
5. Both owner knobs (`minStakeTaoFloor`, `dustCleanupThreshold`) are capped at 16e6 rao (8x the chain's 2e6 default): enough headroom to track plausible chain changes, small enough that no owner/caller combination can ever misclassify or forfeit more than true dust. The old 1e9 cap is replaced.

## Global Constraints

- **NEVER run `git commit`, `git add`, or `git push`. The user commits.**
- ASCII only in written/edited source. Comments: WHY only, black-box chain wording, no subtensor-internal names/formulas. Self-descriptive names preferred over comments (user directive: a comment compensating for a weak name is a naming defect).
- One statement per line. Custom errors PascalCase. Test names `test_<Scenario>_<Outcome>` (two segments; exceptions `test_RevertWhen_<Condition>`, `testFuzz_...`). `vm.expectEmit` for events. `bound()` in fuzz. Zero warnings. `forge fmt`.
- Compile discipline: ALL edits first, `forge fmt` (no compile), then ONE `forge test 2>&1 | tee .superpowers/sdd/redesign-test-output.txt`; batch fixes, max 3 cycles.
- Scope: this plan only. Out of scope: `Unwrapped`/`UnwrappedForTao` event semantics, dissolved-path zero-guard, zero-coldkey check, taoOut raw-delta note, pre-existing conventions debt.

## Current state (working tree, all green 275/275)

The floor-classifier change is fully applied: `_isBelowFloor(alpha, priceE18)` used in wrap (line ~177), `_sweepRotatedStake` (~709-731), `_drainAssets` (~314), `previewUnwrap` (~533), unwrapForTao partial branch (~261); `minStakeTaoFloor` (default 2e6, cap `MAX_MIN_STAKE_TAO_FLOOR = 1e9`), `IAlpha`/`MockAlpha`/mock wiring done. THIS PLAN MODIFIES THAT STATE — read src/AlphaVault.sol fully before editing.

---

### Task R1: Contract redesign (tracked set, bare sweep, cleanupDust, unified redemption basis, renames)

**Files:**
- Modify: `src/AlphaVault.sol`, `src/interfaces/IAlpha.sol`, `src/interfaces/IStaking.sol` (add `addStake` if absent), `src/SubnetClone.sol` (add `stakeTaoForAlpha` passthrough)

**Interfaces produced (later tasks rely on exact names):**
- `IAlpha.getMovingAlphaPrice(uint16 netuid) external view returns (uint256)` (added; validate selector against `#[precompile::public("getMovingAlphaPrice(uint16)")]` at the pinned tag first — STOP if absent).
- `_trackedHotkeys` : `mapping(uint256 => bytes32[8]) private`; external view `trackedHotkeys(uint256 tokenId) returns (bytes32[8] memory)` (replaces `lastSeenHotkeys`).
- `MAX_TRACKED_HOTKEYS = 8` (private constant), error `TrackedHotkeysFull()`.
- `dustCleanupThreshold` (public uint256, default 2e6, constructor-init), `setDustCleanupThreshold(uint256)` onlyOwner, error `DustThresholdTooHigh()`, event `DustCleanupThresholdUpdated(uint256 oldValue, uint256 newValue)`.
- Shared cap: `uint256 private constant MAX_TAO_FLOOR_SETTING = 16e6;` — used by BOTH `setMinStakeTaoFloor` and `setDustCleanupThreshold`. Delete `MAX_MIN_STAKE_TAO_FLOOR = 1e9`. (`MinStakeTaoFloorTooHigh` stays for the floor setter.)
- `cleanupDust(uint256 tokenId) external nonReentrant`, events `DustSold(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 alphaAmount, uint256 taoOut)` and `DustPotRestaked(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 taoAmount)`. There is NO forfeiture event because there is no forfeiture path.
- `SubnetClone.stakeTaoForAlpha(bytes32 hotkey, uint256 netuid, uint256 taoAmount) external onlyWrapper` — passthrough to the staking precompile's addStake, funded from the clone's own balance (exact call shape per the Step 1 validation).
- `_alphaPriceE18(uint16 netuid) private view returns (uint256)` — reads spot, reverts `PriceUnavailable()` on 0. ALL spot reads route through it (wrap, _drainAssets, previewUnwrap, unwrapForTao partial checks, cleanupDust).
- Rename: `_isBelowFloor` -> `_isBelowMinStakeTaoFloor(uint256 alphaAmount, uint256 alphaPriceE18)`; all `priceE18` locals -> `alphaPriceE18`.

- [ ] **Step 1: Validate `getMovingAlphaPrice` at the pinned tag**

```bash
git -C ~/Projects/subtensor show v3.4.7-422:precompiles/src/alpha.rs | grep -n -A 10 'getMovingAlphaPrice'
git -C ~/Projects/subtensor show v3.4.7-422:precompiles/src/staking.rs | sed -n '83,160p'
```
Expected: (a) selector `getMovingAlphaPrice(uint16)`, body reading `get_moving_alpha_price`, x1e9 then `into_evm_balance` (x1e9) like getAlphaPrice => 1e18-scaled; (b) in the StakingPrecompileV2 block (INDEX 2053), the `addStake` entry: record its exact selector and whether the TAO amount is a rao-denominated parameter drawn from the caller's balance or msg.value-funded (and any unit conversion applied to it). Write `SubnetClone.stakeTaoForAlpha` to match that exact shape, mirroring how `sellAlphaForTao` wraps removeStake. STOP and report if either differs from these expectations or is ambiguous.

- [ ] **Step 2: IAlpha addition**

```solidity
    /// @notice Moving-average alpha price for a subnet in TAO, scaled by 1e18.
    function getMovingAlphaPrice(uint16 netuid) external view returns (uint256);
```

- [ ] **Step 3: Storage + admin surface in AlphaVault**

Replace the `_lastSeenHotkeys` declaration (keep the section placement):
```solidity
    /// @dev Every hotkey the clone may still hold stake under: the validators seen as current on
    ///      the last state-mutating call, plus rotated-out hotkeys whose stake could not be
    ///      consolidated yet. Members leave only at zero balance or via cleanupDust.
    mapping(uint256 => bytes32[8]) private _trackedHotkeys;
```
Constants: add `uint256 private constant MAX_TRACKED_HOTKEYS = 8;` and `uint256 private constant MAX_TAO_FLOOR_SETTING = 16e6;`, delete `MAX_MIN_STAKE_TAO_FLOOR`.
Errors: add `TrackedHotkeysFull();`, `DustThresholdTooHigh();`, `PriceUnavailable();`.
Events: add `DustCleanupThresholdUpdated(uint256 oldValue, uint256 newValue);`, `DustSold(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 alphaAmount, uint256 taoOut);`, `DustPotRestaked(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 taoAmount);`.
Constructor: add `dustCleanupThreshold = 2e6;`.
Setters (Admin section): `setMinStakeTaoFloor` now checks `newValue > MAX_TAO_FLOOR_SETTING`; add:
```solidity
    function setDustCleanupThreshold(uint256 newValue) external onlyOwner {
        if (newValue > MAX_TAO_FLOOR_SETTING) revert DustThresholdTooHigh();
        uint256 old = dustCleanupThreshold;
        dustCleanupThreshold = newValue;
        emit DustCleanupThresholdUpdated(old, newValue);
    }
```
Replace external view `lastSeenHotkeys` with `trackedHotkeys(uint256 tokenId) external view returns (bytes32[8] memory)`.

- [ ] **Step 4: Price helper + rename**

```solidity
    /// @dev A zero price means the oracle cannot represent this subnet's price (it is quantized
    ///      at the EVM boundary); classifying against it could misprice arbitrarily, so fail closed.
    function _alphaPriceE18(uint16 netuid) private view returns (uint256 alphaPriceE18) {
        alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);
        if (alphaPriceE18 == 0) revert PriceUnavailable();
    }
```
Rename `_isBelowFloor` to `_isBelowMinStakeTaoFloor(uint256 alphaAmount, uint256 alphaPriceE18)` (drop the restating NatSpec sentence; keep one invariant line: "Applies to transfers, moves, and partial unstakes. Full-balance unstakes are exempt on the chain and must never be gated by this check - they are the only exit for sub-floor positions."). Update every call site to the new names and route every direct `IAlpha(...).getAlphaPrice(...)` through `_alphaPriceE18`.

- [ ] **Step 5: Rewrite the sweep (bare try/catch, keep-on-failure, set maintenance; NO oracle)**

Replace `_sweepRotatedStake` entirely:
```solidity
    /// @dev Consolidate stake off rotated-out hotkeys and refresh membership. Failures are
    ///      tolerated: an unconsolidatable balance stays tracked (counted, priced, sellable)
    ///      and is retried on the next call; only cleanupDust may forfeit it.
    function _sweepRotatedStake(uint256 tokenId, address clone, bytes32 coldkey, bytes32[3] memory currentSet)
        private
    {
        bytes32[8] storage tracked = _trackedHotkeys[tokenId];
        if (clone != address(0)) {
            uint16 netuid = _netuid(tokenId);
            IStaking staking = IStaking(STAKING_PRECOMPILE);
            for (uint256 i; i < MAX_TRACKED_HOTKEYS;) {
                bytes32 hk = tracked[i];
                if (_isRotatedOut(hk, currentSet)) {
                    uint256 bal = staking.getStake(hk, coldkey, netuid);
                    if (bal == 0) {
                        tracked[i] = bytes32(0);
                    } else {
                        try SubnetClone(payable(clone)).moveStake(hk, currentSet[0], netuid, bal) {
                            emit Rebalanced(tokenId, hk, currentSet[0], bal);
                            tracked[i] = bytes32(0);
                        } catch { }
                    }
                }
                unchecked {
                    ++i;
                }
            }
        }
        _trackCurrentHotkeys(tracked, currentSet);
    }

    function _trackCurrentHotkeys(bytes32[8] storage tracked, bytes32[3] memory currentSet) private {
        for (uint256 c; c < 3;) {
            bytes32 hk = currentSet[c];
            if (hk != bytes32(0) && !_isTracked(tracked, hk)) {
                uint256 free = _firstFreeSlot(tracked);
                if (free == MAX_TRACKED_HOTKEYS) revert TrackedHotkeysFull();
                tracked[free] = hk;
            }
            unchecked {
                ++c;
            }
        }
    }

    function _isTracked(bytes32[8] storage tracked, bytes32 hk) private view returns (bool) {
        for (uint256 i; i < MAX_TRACKED_HOTKEYS;) {
            if (tracked[i] == hk) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function _firstFreeSlot(bytes32[8] storage tracked) private view returns (uint256) {
        for (uint256 i; i < MAX_TRACKED_HOTKEYS;) {
            if (tracked[i] == bytes32(0)) return i;
            unchecked {
                ++i;
            }
        }
        return MAX_TRACKED_HOTKEYS;
    }
```
Note: a rotated-out member that is still current-set-absent but holds balance keeps its slot across calls (the whole point). `TrackedHotkeysFull` requires 6+ simultaneously stuck orphans — name it in the error NatSpec as the deliberate fail-closed backstop.

- [ ] **Step 6: `_totalStake` over the tracked union**

Rework `_totalStake(tokenId, netuid)` to return `(bytes32[11] memory hotkeys, uint256[11] memory balances, uint256 total)`: first loop the 8 tracked slots (skip zero), then the registry's current 3 skipping any already tracked (same dedup direction as today). unwrapForTao's local arrays and its loop bound change from 6 to 11. `totalStake()` public view unchanged in behavior.

- [ ] **Step 7: Unified redemption basis + orphan drain**

In `_redeem`: replace the current-set-only pricing (`_fetchBalances` + `_sumBalances` for `totalAlpha`) with the union total: after `_sweepRotatedStake`, call `(,, uint256 totalAlpha) = _totalStake(tokenId, netuid);` for pricing; keep `_fetchBalances` for the current-set `balances` used by drain pass 1 and `_alignToWeights`. After pass 1, if `remaining > 0`, run pass 2 over tracked rotated-out hotkeys:
```solidity
        uint256 delivered = _drainAssets(hotkeys, balances, validatorCount, clone, netuid, userSubstrateColdkey, assets);
        if (delivered < assets) {
            delivered += _drainFromTrackedOrphans(
                tokenId, clone, netuid, userSubstrateColdkey, assets - delivered, alphaPriceE18
            );
        }
```
```solidity
    /// @dev Second drain pass: deliver the remainder from rotated-out tracked hotkeys directly.
    ///      Same slice rules as the current-set pass; a cleared hotkey leaves the set.
    function _drainFromTrackedOrphans(
        uint256 tokenId,
        address clone,
        uint16 netuid,
        bytes32 userColdkey,
        uint256 remaining,
        uint256 alphaPriceE18
    ) private returns (uint256 delivered) {
        bytes32[8] storage tracked = _trackedHotkeys[tokenId];
        (bytes32[3] memory currentSet,) = validatorRegistry.getValidators(netuid);
        IStaking staking = IStaking(STAKING_PRECOMPILE);
        bytes32 coldkey = _coldkeyOf(clone);
        for (uint256 i; i < MAX_TRACKED_HOTKEYS && remaining > 0;) {
            bytes32 hk = tracked[i];
            if (_isRotatedOut(hk, currentSet)) {
                uint256 balance = staking.getStake(hk, coldkey, netuid);
                uint256 takeAmount = remaining > balance ? balance : remaining;
                if (takeAmount > 0 && !_isBelowMinStakeTaoFloor(takeAmount, alphaPriceE18)) {
                    SubnetClone(payable(clone)).flush(userColdkey, hk, netuid, takeAmount);
                    remaining -= takeAmount;
                    delivered += takeAmount;
                    if (takeAmount == balance) tracked[i] = bytes32(0);
                }
            }
            unchecked {
                ++i;
            }
        }
    }
```
`_redeem` reads the price once (`uint256 alphaPriceE18 = _alphaPriceE18(netuid);`) and threads it to both passes; change `_drainAssets` to accept `alphaPriceE18` as a parameter instead of reading it (transfers are swap-less; one read is exact).

- [ ] **Step 8: `previewUnwrap` via `_totalStake`, uniform sub-floor slice filter**

Replace previewUnwrap's hand-rolled union (the `_fetchBalances` sum + rotated-out loop) with:
```solidity
        (, uint256[11] memory balances, uint256 totalAlpha) = ... // via a bounded local using _totalStake
```
then subtract every `balances[i]` that is nonzero and `_isBelowMinStakeTaoFloor(balances[i], alphaPriceE18)` (undeliverable whole slices, any hotkey). Keep `_resolveValidators` up front for the NoValidatorFound revert. NatSpec keeps the "may fall short by floor-bounded dust" line (the final-tail case remains).

- [ ] **Step 9: `cleanupDust` (permissionless, sell-and-restake — never forfeits)**

Place after `rebalance` in the contract:
```solidity
    /// @notice Convert tracked rotated-out dust into productive stake. A balance qualifying as
    ///         dust under BOTH the spot and the moving-average price is first consolidated by a
    ///         move; when the chain rejects that, it is sold for TAO in full (full-balance sells
    ///         are exempt from the chain's floor), and the clone's accumulated TAO pot is
    ///         restaked into the current set once it is large enough for the chain to accept.
    ///         Permissionless: the gate is objective and the threshold hard-capped, so a caller
    ///         controls only timing; the dual-oracle gate prevents selling into a briefly
    ///         manipulated price. Nothing is ever forfeited - a balance that can neither move
    ///         nor sell stays tracked and is retried later.
    function cleanupDust(uint256 tokenId) external nonReentrant {
        address clone = subnetClone[tokenId];
        if (clone == address(0)) revert NothingToUnwrap();
        uint16 netuid = _netuid(tokenId);
        (bytes32[3] memory currentSet,) = validatorRegistry.getValidators(netuid);
        // With no attested validators the tracked balances are the holders' only exit collateral.
        if (currentSet[0] == bytes32(0)) revert NoValidatorFound();

        uint256 spotAlphaPriceE18 = _alphaPriceE18(netuid);
        uint256 movingAlphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getMovingAlphaPrice(netuid);
        if (movingAlphaPriceE18 == 0) revert PriceUnavailable();

        bytes32[8] storage tracked = _trackedHotkeys[tokenId];
        bytes32 coldkey = _coldkeyOf(clone);
        IStaking staking = IStaking(STAKING_PRECOMPILE);
        uint256 threshold = dustCleanupThreshold;
        for (uint256 i; i < MAX_TRACKED_HOTKEYS;) {
            bytes32 hk = tracked[i];
            if (_isRotatedOut(hk, currentSet)) {
                uint256 bal = staking.getStake(hk, coldkey, netuid);
                if (bal == 0) {
                    tracked[i] = bytes32(0);
                } else if (
                    (bal * spotAlphaPriceE18) / 1e18 < threshold && (bal * movingAlphaPriceE18) / 1e18 < threshold
                ) {
                    try SubnetClone(payable(clone)).moveStake(hk, currentSet[0], netuid, bal) {
                        emit Rebalanced(tokenId, hk, currentSet[0], bal);
                        tracked[i] = bytes32(0);
                    } catch {
                        uint256 taoBefore = clone.balance;
                        try SubnetClone(payable(clone)).sellAlphaForTao(hk, netuid, bal) {
                            emit DustSold(tokenId, hk, bal, clone.balance - taoBefore);
                            tracked[i] = bytes32(0);
                        } catch { }
                    }
                }
            }
            unchecked {
                ++i;
            }
        }

        _restakeDustPot(tokenId, clone, netuid, currentSet[0]);
    }

    /// @dev The pot re-enters share pricing as alpha only once the chain accepts the add; a
    ///      too-small pot simply waits for more dust. On a live subnet the clone's TAO balance
    ///      is exclusively dust-sale proceeds: unwrapForTao pays out its full delta in the same
    ///      transaction and dissolution refunds only exist for tokenIds whose registry is empty,
    ///      which cleanupDust refuses to touch.
    function _restakeDustPot(uint256 tokenId, address clone, uint16 netuid, bytes32 destinationHotkey) private {
        uint256 pot = clone.balance;
        if (pot == 0) return;
        try SubnetClone(payable(clone)).stakeTaoForAlpha(destinationHotkey, netuid, pot) {
            emit DustPotRestaked(tokenId, destinationHotkey, pot);
        } catch { }
    }
```

- [ ] **Step 10: wrap/unwrapForTao touch-ups**

wrap: `if (_isBelowMinStakeTaoFloor(totalDeposit, _alphaPriceE18(nid))) revert DepositTooSmall();` (helper routing + rename only). unwrapForTao: loop bound 11, partial check becomes `!_isBelowMinStakeTaoFloor(remaining, _alphaPriceE18(netuid))` (fresh read per check stays). Update all NatSpec touched by behavior changes (sweep tolerance, redeem union basis + orphan pass, tracked-set field docs, trackedHotkeys view). `_rebalanceStep`: add one line above its try: `// Best-effort by design: a failed split-optimization loses nothing; do not migrate this to the pre-check pattern.`

### Task R2: Mocks and test base

**Files:** `test/mocks/MockAlpha.sol`, `test/mocks/MockStaking.sol`, `test/AlphaVaultTestBase.sol`

- [ ] MockAlpha: rename `setPrice` -> `setAlphaPrice`, `_priceE18` -> `_alphaPriceE18`; add moving price + explicit-zero support:
```solidity
contract MockAlpha {
    mapping(uint16 => uint256) private _alphaPriceE18;
    mapping(uint16 => uint256) private _movingAlphaPriceE18;
    mapping(uint16 => bool) private _priceUnavailable;

    function setAlphaPrice(uint16 netuid, uint256 alphaPriceE18) external {
        _alphaPriceE18[netuid] = alphaPriceE18;
    }

    function setMovingAlphaPrice(uint16 netuid, uint256 movingAlphaPriceE18) external {
        _movingAlphaPriceE18[netuid] = movingAlphaPriceE18;
    }

    function setPriceUnavailable(uint16 netuid, bool unavailable) external {
        _priceUnavailable[netuid] = unavailable;
    }

    function getAlphaPrice(uint16 netuid) external view returns (uint256) {
        if (_priceUnavailable[netuid]) return 0;
        uint256 price = _alphaPriceE18[netuid];
        return price == 0 ? 1e18 : price;
    }

    function getMovingAlphaPrice(uint16 netuid) external view returns (uint256) {
        if (_priceUnavailable[netuid]) return 0;
        uint256 price = _movingAlphaPriceE18[netuid];
        return price == 0 ? 1e18 : price;
    }
}
```
- [ ] MockStaking: delete `alphaPrice`/`setAlphaPrice`; `_belowMinStake` reads the single source: `uint256 alphaPriceE18 = MockAlpha(ALPHA_PRECOMPILE).getAlphaPrice(uint16(netuid));` (import MockAlpha + ALPHA_PRECOMPILE; keep the black-box comment). This makes classifier/mock desync structurally impossible.
- [ ] Base: `_setAlphaPrice(netuid, alphaPriceE18)` now writes MockAlpha only (spot); add `_setMovingAlphaPrice(uint256 netuid, uint256 movingAlphaPriceE18)`. Hoist into the base (from file-local copies): `_depositForAlice`-equivalent `_depositAndWrap(address user, uint256 netuid, uint256 amount) returns (uint256 shares)`, and `_userStakeAcrossHotkeys(address user, uint256 netuid) returns (uint256)` summing hotkey1..4 for the user's substrate coldkey. Update `lastSeenHotkeys` consumers to `trackedHotkeys`.

### Task R3: Tests

**Files:** `test/MinStakeTaoFloor.t.sol`, `test/AlphaVault.t.sol`, `test/UnwrapForTao.t.sol` (+ any file referencing `lastSeenHotkeys`)

Rewrites of tests whose asserted behavior changed:
- [ ] `test_RevertWhen_AboveFloorOrphanSweepFails` -> `test_Sweep_KeepsUnmovableOrphanTracked`: same arrange (rotate hotkey3 out with 10e6, `setMoveStakeReverts(true)`), now assert `rebalance(NETUID1)` SUCCEEDS, hotkey3 is still in `trackedHotkeys(TOKEN1)`, and `totalStake(TOKEN1)` is unchanged.
- [ ] `test_Rebalance_DropsRotatedOutSubFloorDust` -> `test_Sweep_KeepsSubFloorDustTracked`: dust orphan stays tracked and counted after rebalance (chain rejects the move; catch keeps it).
- [ ] Update the preview parity test for the union basis (orphan excluded only while sub-floor; an above-floor kept orphan is now INCLUDED in preview and deliverable via the orphan drain pass).
New tests (each self-descriptive per the naming directive; use named locals like `aboveFloorOrphanBalance`, `subFloorDust = MIN_STAKE_FLOOR - 1`, not magic numbers):
- [ ] `test_CleanupDust_SellsUnmovableDustForTao` (chain rejects the move, full-balance sell succeeds: expectEmit DustSold with the realized taoOut; slot cleared; caller is a random non-owner address — pins permissionlessness; requires `_setRemoveStakeRate` configured).
- [ ] `test_CleanupDust_RestakesPotWhenLargeEnough` (accumulated pot above the mock's add floor -> expectEmit DustPotRestaked; clone balance 0; totalStake grew by the restaked amount; MockStaking needs an addStake mock honoring the chain's minimum — add it in R2 with the same MIN_STAKE floor and a settable tao-to-alpha rate).
- [ ] `test_CleanupDust_KeepsPotWhenBelowAddFloor` (tiny pot stays in the clone, no revert, no event).
- [ ] `test_CleanupDust_MovesRescuableBalanceInsteadOfSelling` (move succeeds under the gate -> Rebalanced emitted, value stays alpha).
- [ ] `test_CleanupDust_KeepsDustTrackedWhenSellFails` (per-hotkey removeStake revert -> slot NOT cleared, nothing emitted for it — the no-forfeiture property).
- [ ] `test_CleanupDust_IgnoresOrphanWhenMovingAverageAboveThreshold` (spot crashed, EMA high -> orphan untouched; the manipulation-resistance property).
- [ ] `test_RevertWhen_CleanupDustPriceUnavailable` (setPriceUnavailable -> PriceUnavailable).
- [ ] `test_RevertWhen_CleanupDustWithoutValidators` (registry empty for netuid -> NoValidatorFound).
- [ ] `test_SetDustCleanupThreshold_UpdatesValueAndEmits` + `test_RevertWhen_DustThresholdAboveCap` (16e6 + 1) + `test_RevertWhen_NonOwnerSetsDustThreshold`; adjust the existing floor-cap test to 16e6 + 1.
- [ ] `test_RevertWhen_TrackedHotkeysFull` (fill 8 slots via forced failed sweeps across rotations, next new current hotkey -> TrackedHotkeysFull).
- [ ] `test_Withdraw_DeliversFromTrackedOrphanWhenCurrentSetShort` (current set drained below the request; orphan pass delivers the remainder; orphan slot cleared when fully drained).
- [ ] `test_RevertWhen_PriceUnavailableOnWrap` and `test_RevertWhen_PriceUnavailableOnWithdraw` (setPriceUnavailable -> both mutators fail closed instead of misclassifying).
- [ ] `test_RevertWhen_PartialSellBelowSimFloor` (the sim/spot band, now expressible: `_setRemoveStakeRate(999, 1000)` with spot 1e18 and a partial remainder just above 2e6 spot -> mock's rate-based floor rejects -> whole unwrapForTao reverts, shares intact). Assert the revert data and shares.
- [ ] Fuzz `testFuzz_Withdraw_ShortfallBoundedByFloor`: unchanged property, rebound if helper names changed.
- [ ] Sweep the suite for `lastSeenHotkeys` and 6-slot assumptions; update.

### Task R4: e2e phases

**Files:** `scripts/localnet-e2e.sh`

- [ ] Phase 14 update: rotation now asserts the orphan is swept on the real chain as before (move succeeds there); add assertion that `trackedHotkeys` no longer contains the rotated hotkey afterwards (selector change from lastSeenHotkeys).
- [ ] New phase "floor boundary": read `getAlphaPrice` via `cast call`, compute `boundaryAlpha = ceil(2e6 * 1e18 / price)`; stake `boundaryAlpha - 1` into a fresh mailbox -> wrap must revert DepositTooSmall; stake to `boundaryAlpha` -> wrap succeeds. This is the real-chain check the unit mocks cannot provide (classifier vs chain fixed-point at the boundary).
- [ ] New phase "dust orphan lifecycle": park sub-floor dust under a soon-rotated hotkey, rotate registry, run rebalance -> assert tx succeeds and `trackedHotkeys` still contains the hotkey (kept); then `cleanupDust(tokenId)` from a NON-owner key -> assert DustSold emitted, hotkey gone, and the clone's TAO pot either restaked (DustPotRestaked + totalStake grew) or retained below the add floor - assert whichever the real amounts produce, explicitly.
- [ ] `bash -n scripts/localnet-e2e.sh` after edits. Note in the report that full e2e validation runs in CI (or locally if the localnet docker is up).

### Task R5: Verification pipeline

- [ ] `forge fmt` + `forge fmt --check`; `forge build` zero warnings; full `forge test` green (expect the R3 count); ASCII guard on added lines; `FORGE_SNAPSHOT_CHECK=false forge snapshot` + `FORGE_SNAPSHOT_CHECK=false forge test` then `forge snapshot --check --tolerance 1`; `forge coverage --ir-minimum --report summary` (report changed-file numbers; every new branch named if uncovered); code-review finder pass; final report. **No commits.**
- [ ] **Final in-depth review (user-mandated charter): Fable, clean context** (spec = this plan + diff package + raw test output; no implementer narratives), with two explicit lenses:
  - **Denial prevention:** enumerate EVERY revert path reachable from each user entry point (wrap, unwrap, unwrapForTao, rebalance, cleanupDust, reclaim paths) and classify each as user-error / bounded-transient-with-automatic-retry / recoverable-with-named-recovery-route. Any path that can permanently brick deposits or BOTH exit rails is a Critical finding. Specifically probe: TrackedHotkeysFull reachability and relief; PriceUnavailable blast radius per path; whether cleanupDust's gates or a hostile registry can be used to block users; the exit rail that must survive each failure mode.
  - **Funds preservation:** verify the "vault never forfeits" invariant end to end: every alpha/TAO flow conserves holder value modulo documented dust latency and swap fees; the sell-and-restake round trip cannot leak value to the caller or a third party; the TAO pot cannot be commingled with dissolution refunds or unwrapForTao deltas; permissionless cleanupDust cannot extract, misdirect, or force a sale into a manipulated price beyond the dual-oracle bound; both rails redeem against the same union basis with no same-shares-different-value gap beyond documented dust.

## Acceptance criteria

1. Sweep contains NO price/oracle read and NO revert path besides TrackedHotkeysFull; a failed consolidation keeps the hotkey tracked and the tx succeeds.
2. `totalStake`, `sharePrice`, `previewUnwrap`, `unwrapForTao`, and `_redeem` all price off the same tracked-union total; the alpha rail can deliver from tracked orphans.
3. The vault NEVER forfeits. `cleanupDust` is permissionless, requires BOTH oracles below `dustCleanupThreshold` (<= 16e6), reverts on any zero price or empty validator set, attempts a rescue move first, sells unmovable dust in full (floor-exempt) with `DustSold`, keeps anything that can neither move nor sell tracked for retry, and restakes the clone's TAO pot (`DustPotRestaked`) once the chain accepts it.
4. Both owner knobs capped at 16e6; zero spot price fails closed (PriceUnavailable) on wrap/redeem/preview/unwrapForTao-partial paths.
5. Exit paths keep pre-check + bubble semantics; `_rebalanceStep` try/catch untouched; full-balance sells never floor-gated.
6. The sim/spot band and permissionless-cleanup properties are pinned by the named tests; nothing asserts via a mock that mirrors the classifier (MockStaking reads MockAlpha - single price source).
7. fmt/build/test/snapshot/coverage clean; nothing committed.
