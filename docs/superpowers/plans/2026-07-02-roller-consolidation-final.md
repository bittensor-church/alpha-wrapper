# FINAL: Roller Consolidation Plan (supersedes 2026-07-02-dust-tracking-redesign.md and the sweep portion of 2026-07-02-floor-dust-classifier.md)

> **For agentic workers:** execute as one consolidated implementation. Baseline = the CURRENT WORKING TREE (uncommitted; contains the tracked-set redesign at 294+ green tests), NOT git HEAD. Some restored shapes (the bytes32[3] snapshot, 3-arg unwrap) exist at HEAD — consult `git show HEAD:<file>` when restoring them.

**Goal:** Converge the vault to its final, simplest safe shape: chain-enforced floors everywhere, an oracle that never gates value (labels and one skip only), strict-revert consolidation via whole-balance rolling ("roller"), exact-or-revert alpha-rail delivery, and the original 3-slot snapshot.

**Architecture in one paragraph:** The chain's stake floor binds only on the AMOUNT moved, so consolidation rolls the vault's whole pile through dusty hotkeys - every move contains the main position and is above the floor by construction, with no price read and no sizing math. Consolidation failures revert the transaction (atomicity closes the stranding hole that tracking used to close), so the snapshot returns to `bytes32[3]` and the tracked-set machinery is deleted. Redemption gathers the position onto one hotkey (same roller) and delivers with a SINGLE flush - exact or reverting, never partial - so `minAlphaOut`, slice-skipping, and preview filters are deleted. The spot oracle remains only for two typed-error labels and the unwrapForTao partial-tail skip; when it reads 0 (sub-1e-9 subnets), those sites fall through to the chain's own full-precision enforcement, so micro-priced subnets are fully functional. `unwrapForTao`'s loop is UNTOUCHED (charter-verified always-open exit).

## Verified chain ground truth (subtensor v3.4.7-422; treat as fact, do not re-derive)

- Same-subnet moveStake/transferStake floor: spot tao-value of the AMOUNT >= 2e6 rao, inclusive; NO full-balance exemption; NO remainder rule; swap-less, fee-less, lossless.
- removeStake: sim-based amount floor WITH full-balance exemption (why the unwrapForTao full-sell branch must never be gated).
- moveStake destination requires only `hotkey_account_exists` - rotated-out/unattested hotkeys are valid destinations.
- Stake-op rate limiter: one op per (ORIGIN hotkey, coldkey, netuid) per block, BUT same-subnet moves and within-subnet transfers NEVER set markers, and every marker-setting op keys on the CALLER's coldkey - no third party can mark the clone's triples, and the vault itself sets none. Multi-move single-tx rolling is unrestricted.
- getAlphaPrice at 0x808: spot x1e18; quantized through u64 at 1e9 scale, so subnets priced below 1e-9 TAO/alpha read as 0 while the CHAIN internally uses full precision (why oracle-0 must fall through to chain enforcement, not fail closed).

## Design rules (settled with the user - do not relitigate)

1. Consolidation failures REVERT the whole tx. No catch anywhere in the roller. `_rebalanceStep` keeps its try/catch (split optimization loses nothing) - the ONLY try/catch in AlphaVault. (unwrapForTao's partial sell is a bare pre-checked call per rule 4 and the R1 code block; an earlier draft of this sentence miscounted it as a second catch - the one-catch implementation is correct and user-blessed.)
2. The oracle never gates value. Price==0 => fall through (attempt and let the chain decide) or skip a partial tail. `PriceUnavailable` is deleted.
3. `minStakeTaoFloor` knob STAYS (user decision): owner-set, default 2e6, cap 16e6 (constant renamed `MAX_MIN_STAKE_TAO_FLOOR` now that the dust threshold is gone). Consumers: wrap's DepositTooSmall label, redeem's WithdrawTooSmall label, unwrapForTao's partial-tail skip.
4. unwrapForTao loop semantics unchanged (full sells bare; partial pre-checked; fresh price per check; NOW: price==0 => skip the partial instead of reverting).
5. Global constraints: NEVER git commit/add/push. ASCII-only on touched lines. WHY-only black-box comments. Self-descriptive names over comments. One statement per line. test_<Scenario>_<Outcome> naming (test_RevertWhen_<Condition>, testFuzz_ exceptions). vm.expectEmit. bound(). Zero warnings. Compile discipline: ALL edits -> forge fmt -> ONE `forge test 2>&1 | tee .superpowers/sdd/roller-test-output.txt`; batch fixes; max 3 cycles. Constants must be declared BEFORE any state variable whose type references them (Solidity cannot forward-reference constants in state array sizes - this bit us once already).

---

## R1: AlphaVault.sol

**Storage/track-keeping (restore the snapshot):**
- `mapping(uint256 => bytes32[MAX_TRACKED_HOTKEYS]) private _trackedHotkeys` -> `mapping(uint256 => bytes32[3]) private _lastSeenHotkeys` with its original doc ("validators the clone's stake was distributed across at the last state-mutating call; refreshed only after a clean consolidation"). External view `trackedHotkeys(uint256) returns (bytes32[8])` -> `lastSeenHotkeys(uint256) returns (bytes32[3])` (shape at `git show HEAD:src/AlphaVault.sol`).
- DELETE: `MAX_TRACKED_HOTKEYS`, `TrackedHotkeysFull`, `_trackCurrentHotkeys`, `_isTracked`, `_firstFreeSlot`, `cleanupDust` (entire function + its guards), `dustCleanupThreshold` + `setDustCleanupThreshold` + `DustThresholdTooHigh` + `DustCleanupThresholdUpdated`, `DustSold`, `DustPotRestaked`, `_restakeDustPot`, `_drainFromTrackedOrphans`, `PriceUnavailable`, `_alphaPriceE18` (the reverting helper - price reads become direct `IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid)` at the three consumer sites).
- RENAME: `MAX_TAO_FLOOR_SETTING` -> `MAX_MIN_STAKE_TAO_FLOOR` (still 16e6; only consumer is setMinStakeTaoFloor).
- `_totalStake` union arrays: `[MAX_TRACKED_HOTKEYS + 3]` -> `[6]` (3 lastSeen + 3 current, HEAD shape); unwrapForTao and previewUnwrap local array sizes follow.

**The roller (new, ~30 lines, replaces the sweep body):**
```solidity
    /// @dev Consolidate all stake off rotated-out hotkeys, then refresh the snapshot. Rolling the
    ///      whole pile keeps every move above the chain's floor without consulting a price: each
    ///      hop's amount contains the vault's largest position. Any failure reverts the call -
    ///      atomicity, not tracking, is what makes the refresh safe.
    function _sweepRotatedStake(uint256 tokenId, address clone, bytes32 coldkey, bytes32[3] memory currentSet) private {
        bytes32[3] storage lastSeen = _lastSeenHotkeys[tokenId];
        if (clone != address(0)) {
            uint16 netuid = _netuid(tokenId);
            (bytes32 rollerHotkey, uint256 rollerBalance) = _richestUnionHotkey(lastSeen, currentSet, coldkey, netuid);
            for (uint256 i; i < 3;) {
                bytes32 rotatedOut = lastSeen[i];
                if (rotatedOut != rollerHotkey && _isRotatedOut(rotatedOut, currentSet)) {
                    uint256 orphanBalance = IStaking(STAKING_PRECOMPILE).getStake(rotatedOut, coldkey, netuid);
                    if (orphanBalance > 0) {
                        SubnetClone(payable(clone)).moveStake(rollerHotkey, rotatedOut, netuid, rollerBalance);
                        emit Rebalanced(tokenId, rollerHotkey, rotatedOut, rollerBalance);
                        rollerHotkey = rotatedOut;
                        rollerBalance += orphanBalance;
                    }
                }
                unchecked {
                    ++i;
                }
            }
            if (_isRotatedOut(rollerHotkey, currentSet)) {
                SubnetClone(payable(clone)).moveStake(rollerHotkey, currentSet[0], netuid, rollerBalance);
                emit Rebalanced(tokenId, rollerHotkey, currentSet[0], rollerBalance);
            }
        }
        if (lastSeen[0] != currentSet[0]) lastSeen[0] = currentSet[0];
        if (lastSeen[1] != currentSet[1]) lastSeen[1] = currentSet[1];
        if (lastSeen[2] != currentSet[2]) lastSeen[2] = currentSet[2];
    }

    /// @dev The union's largest position seeds the roller; starting anywhere smaller could put a
    ///      sub-floor amount on the wire.
    function _richestUnionHotkey(
        bytes32[3] storage lastSeen,
        bytes32[3] memory currentSet,
        bytes32 coldkey,
        uint16 netuid
    ) private view returns (bytes32 richest, uint256 richestBalance) { ... scan currentSet then rotated-out lastSeen entries via getStake, return max ... }
```
Notes for the implementer: (a) when no rotated-out hotkey holds a balance, the loop does nothing and the roller start scan is the only cost - acceptable; if you prefer, early-exit the whole block when no orphan has balance (one pre-scan), keeping the common path at 3 getStake calls; (b) a rotated-out roller START that never entered the loop is landed on currentSet[0] by the final if; (c) moveStake amount 0 is a SubnetClone no-op - the roller must therefore skip moves when rollerBalance == 0 is impossible by construction only in non-dust vaults; for the dust-only vault the first move carries a sub-floor amount and the chain reverts the tx: ACCEPTED (wrap cannot hit it - see R1 wrap order - and redeem/rebalance reverting on a vault worth < 0.002 TAO is costless since unwrapForTao remains). Do NOT add a catch.

**wrap - reorder (sweep AFTER flush so the fresh deposit is the roller's pile):**
current order: sweep -> getStake deposit -> precheck -> flush -> rebalance -> mint
new order: getStake deposit -> label precheck -> flush -> sweep -> rebalance -> preStake = current-set total - totalDeposit -> mint.
Label precheck becomes oracle-soft:
```solidity
        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(nid);
        if (alphaPriceE18 != 0 && _isBelowMinStakeTaoFloor(totalDeposit, alphaPriceE18)) revert DepositTooSmall();
```
(price 0 => the flush itself enforces the chain's full-precision floor; raw chain error is acceptable there). Update wrap NatSpec accordingly.

**_redeem - gather + single flush (exact-or-revert delivery):**
Replace the `_drainAssets` slice loop + orphan pass with:
1. `_resolveValidators`, `_sweepRotatedStake` (post-sweep the union equals the current set), fetch current balances, `totalAlpha` = their sum; `assets = _assetsFor(...)`; ZeroAmount check; oracle-soft WithdrawTooSmall label: `if (alphaPriceE18 != 0 && _isBelowMinStakeTaoFloor(assets, alphaPriceE18)) revert WithdrawTooSmall();` (keep the existing why-comment pointing dust positions at unwrapForTao); burn.
2. Delivery: if `balances[0] >= assets` -> single `flush(userSubstrateColdkey, hotkeys[0], netuid, assets)`. Else gather first with the roller primitive across the CURRENT set (roll hotkeys[0]'s full balance through hotkeys[1], hotkeys[2] as needed until one hotkey holds >= assets - in practice rolling everything onto the last visited hotkey), then one flush from it. All moves and the flush are BARE (revert on failure). Extract the shared rolling step so sweep and gather use one primitive rather than two copies.
3. `_alignToWeights` re-splits; emit `Unwrapped(msg.sender, tokenId, shares, assets)` (delivery is exact; the `delivered` variable disappears).
4. `unwrap` signature: DROP `minAlphaOut` -> `unwrap(uint256 tokenId, uint256 shares, bytes32 userSubstrateColdkey)` (HEAD's 3-arg shape); delete the SlippageExceeded use on this path (SlippageExceeded stays for the TAO rails); update NatSpec (no under-delivery clause - delivery is exact or the tx reverts).

**previewUnwrap:** drop the sub-floor filter AND its price read: live path returns `_assetsFor(unionTotal, supply, shares)` directly (union via `_totalStake`). Parity with unwrap is now exact above the floor; NatSpec: one line - "reverts on execution rather than under-delivering; a sub-floor total is exit-able via unwrapForTao".

**unwrapForTao:** arrays back to [6]; partial branch becomes oracle-soft:
```solidity
                } else {
                    uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);
                    if (alphaPriceE18 != 0 && !_isBelowMinStakeTaoFloor(remaining, alphaPriceE18)) {
                        SubnetClone(payable(clone)).sellAlphaForTao(hotkeys[i], netuid, remaining);
                        remaining = 0;
                    }
                }
```
(price 0 => tail waits as bounded dust, minTaoOut guards; full-balance branch untouched). Everything else in the function unchanged.

## R2: SubnetClone / interfaces / mocks / base

- DELETE `SubnetClone.stakeTaoForAlpha`; DELETE `IStaking.addStake` if this branch added it and nothing else uses it; DELETE `IAlpha.getMovingAlphaPrice`.
- MockAlpha shrinks to: `setAlphaPrice(uint16, uint256)` + `getAlphaPrice` returning the stored price, defaulting to 1e18 when unset, and honoring an explicit stored 0 via one `_priceIsZero` flag setter `setAlphaPriceZero(uint16 netuid, bool)` (needed by the oracle-soft tests; the old unavailability flags are deleted).
- MockStaking: DELETE the addStake mock + `_setAddStakeRate` machinery (keep everything else, including the per-hotkey revert knobs and the floor semantics - they are what make the strict-revert and exit tests real).
- AlphaVaultTestBase: `_setPriceUnavailable`/`_setMovingPriceUnavailable` -> `_setAlphaPriceZero(uint256 netuid, bool)`; delete `_setAddStakeRate`; keep `_depositAndWrap`, `_userStakeAcrossHotkeys`, `_donateToClone` (still used by donation tests), `_isHotkeyTracked` -> adapt to lastSeenHotkeys[3] or replace with direct assertions.

## R3: Tests (test/CleanupDust.t.sol becomes test/RollerConsolidation.t.sol or folds into MinStakeTaoFloor.t.sol - implementer's judgment, one coherent home)

DELETE tests for deleted machinery: all cleanupDust tests, restake/pot tests, TrackedHotkeysFull, moving-price tests, keep-on-failure tests, orphan-drain tests, PriceUnavailable revert tests, minAlphaOut slippage tests.
REWRITE (behavior changed):
- Sweep failure tests: `setMoveStakeReverts(true)` + rotation now asserts the MUTATOR REVERTS (bubbled mock error) and lastSeenHotkeys/backing are unchanged (strict revert, orphan never dropped) - replaces keep-tracked assertions.
- Dust rotation: rotated-out sub-floor dust is CONSOLIDATED by the roller on the next mutator (assert orphan zeroed, total conserved on currentSet, snapshot refreshed) - replaces drop/keep tests. This is the headline behavior test.
- 3-arg unwrap everywhere (tests + gas tests); delivery-exactness: assertEq(received, previewAssets) replaces assertGe/dust-bound assertions; the fuzz shortfall test becomes an exact-parity fuzz (received == preview for all bounded price/deposit; keep bound() ranges).
NEW:
- test_Wrap_ConsolidatesOrphanUsingFreshDeposit (rotation + dust orphan + no other above-floor balance: wrap succeeds BECAUSE the flushed deposit seeds the roller; assert orphan zeroed and preStake counted it).
- test_Withdraw_GathersAcrossValidatorsForSingleDelivery (assets > any single slot: assert user received exactly assets, align re-split ran).
- test_RevertWhen_RollerMoveFails (mid-roll failure via per-direction mock knob if available, else global: whole tx reverts, nothing moved).
- test_Wrap_AcceptsDepositWhenPriceReadsZero + test_Withdraw_TailWaitsWhenPriceReadsZero (oracle-soft: wrap falls through to mock chain floor; unwrapForTao skips the partial, delivers full slots, minTaoOut still enforced).
- test_UnwrapForTao_FullSlotExitWhenPriceReadsZero (dust/zero-price vault exits via full-balance sells).
Update e2e: unwrap back to 3-arg (all call sites), Phase 17 (dust lifecycle) becomes "rotate with dust -> next wrap/rebalance consolidates automatically -> assert no orphan remains and totals conserved" (no cleanupDust, no keeper); Phase 16 floor-boundary stays; trackedHotkeys getter -> lastSeenHotkeys. bash -n only.

## R4: Verification (controller runs after implementation)

forge fmt/--check; ONE full suite; coverage --ir-minimum (the deleted functions remove the previous stack-pressure hot spots; if any new function trips the one-slot Yul issue, apply the established remedies: fewer locals / storage-pointer params / return-by-subtraction); snapshots regen + --check --tolerance 1; ASCII guard; then Fable gates: quality review + the user's denials-and-funds charter review (charter focus updates: atomic roller cannot strand or leak; exact delivery; oracle-soft paths cannot be manipulated because the oracle gates no value; rate-limiter immunity argument; dust-only-vault revert acceptability with unwrapForTao as the surviving rail).

## Acceptance criteria

1. `_lastSeenHotkeys` is bytes32[3]; refresh happens only in `_sweepRotatedStake` after a clean (or no-op) roll; no tracked-set machinery remains anywhere.
2. Zero try/catch in consolidation and delivery paths; the only catch in AlphaVault is `_rebalanceStep`'s move (unwrapForTao's partial sell is bare and pre-checked).
3. Alpha-rail delivery is exact: `unwrap` is 3-arg, emits assets, and either delivers assets in full or reverts; previewUnwrap live path == deliverable amount above the floor, with no price read.
4. The oracle gates no value: grep shows getAlphaPrice consumed only at wrap label, redeem label, unwrapForTao partial skip - each with an `!= 0` fall-through; PriceUnavailable does not exist.
5. minStakeTaoFloor: owner knob, default 2e6, cap MAX_MIN_STAKE_TAO_FLOOR = 16e6, exactly three consumers.
6. Full suite green in <= 3 compile cycles; coverage compiles under --ir-minimum; snapshots tolerance-1 clean; nothing committed.
