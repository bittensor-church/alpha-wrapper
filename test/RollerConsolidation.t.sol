// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { CHAIN_MIN_STAKE, MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// @dev Exercises the whole-balance consolidation "roller": rotated-out stake (including sub-floor
///      dust) is rolled onto the current set with pile-sized, non-decreasing hops (the richest slot is the
///      binding floor check), any failure reverts atomically, an unwrap gathers for a single exact
///      delivery, and the spot oracle gates no value (a zero read falls through to the chain).
contract RollerConsolidationTest is AlphaVaultTestBase {
    event Unwrapped(address indexed user, uint256 indexed tokenId, uint256 shares, uint256 alphaOut);

    /// @dev Registers subnet 99, wraps a deposit for alice on hotkey4, shaves the position to
    ///      sub-floor dust, and rotates hotkey4 out so the dust sits on a rotated-out validator.
    function _seedDustOnlyVault() private returns (uint256 tokenId) {
        _registerSubnet(99, hotkey4);
        _simulateAlphaDepositHotkey(alice, 99, 10 ether, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);
        tokenId = vault.currentTokenId(99);
        _setVaultStake(hotkey4, 99, CHAIN_MIN_STAKE - 1);
        _setValidators(99, _hotkeys(hotkey1), _weights(10_000));
    }

    /// @dev Headline: two hotkeys rotate out at once and the roller chains the whole pile through
    ///      both, emptying each rotated-out slot and refreshing the remembered set - no tracking, no forfeiture.
    function test_Rebalance_ConsolidatesMultipleRotatedOutSlots() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 totalBefore = vault.totalStake(TOKEN1);

        // Drop hotkey2 and hotkey3 in one rotation; the roll carries the pile through both rotated-out slots.
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey4), _weights(5000, 5000));
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey2, NETUID1), 0, "first rotated-out slot consolidated");
        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "second rotated-out slot consolidated");
        assertEq(vault.totalStake(TOKEN1), totalBefore, "total conserved across the chained roll");
        bytes32[] memory seen = vault.lastSeenHotkeys(TOKEN1);
        assertEq(seen.length, 2, "remembered set refreshed to the 2-validator current set");
        assertEq(seen[0], hotkey1);
        assertEq(seen[1], hotkey4);
    }

    /// @dev Rotated-out sub-floor stake with no other above-floor backing is still consolidated,
    ///      because wrap flushes the fresh deposit BEFORE the consolidation so the roll can start from it. A
    ///      consolidation-first order would put the sub-floor amount on the wire and revert.
    function test_Wrap_ConsolidatesRotatedOutStakeUsingFreshDeposit() public {
        uint256 tokenId = _seedDustOnlyVault();
        uint256 dust = CHAIN_MIN_STAKE - 1;

        uint256 bobDeposit = 5 ether;
        _simulateAlphaDepositHotkey(bob, 99, bobDeposit, hotkey1);
        uint256 previewedShares = vault.previewWrap(tokenId, bobDeposit);
        _wrapHotkey(bob, 99, hotkey1);

        assertEq(vault.balanceOf(bob, tokenId), previewedShares, "mint parity with the union-priced preview");
        assertEq(_getVaultStake(hotkey4, 99), 0, "rotated-out dust consolidated by the roll");
        assertEq(vault.totalStake(tokenId), bobDeposit + dust, "rotated-out stake folded into the current-set backing");
        bytes32[] memory seen = vault.lastSeenHotkeys(tokenId);
        assertEq(seen[0], hotkey1, "remembered set refreshed to the current set");
    }

    /// @dev Full-set rotation where the RICHER rotated-out slot sits at a later remembered-set index: the roll
    ///      starts from it, and revisiting the richest slot must not re-add its departed balance.
    function test_Rebalance_ConsolidatesWhenRicherRotatedOutSlotSitsAtLaterIndex() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(3000, 7000));
        _depositAndWrap(alice, NETUID1, 10 ether);
        uint256 totalBefore = vault.totalStake(TOKEN1);

        // Rotate BOTH validators out; the 70%-weighted hotkey2 is the richest rotated-out slot at index 1.
        _setValidators(NETUID1, _hotkeys(hotkey4), _weights(10_000));
        vm.recordLogs();
        vault.rebalance(NETUID1);

        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0, "pure consolidation emits nothing");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "earlier rotated-out slot consolidated");
        assertEq(_getVaultStake(hotkey2, NETUID1), 0, "richest rotated-out slot consolidated");
        assertEq(_getVaultStake(hotkey4, NETUID1), totalBefore, "whole pile landed on the current set");
        assertEq(vault.totalStake(TOKEN1), totalBefore, "total conserved");
    }

    /// @dev A funded rotated-out slot is consolidated by rolling the union-richest pile through it: the pile
    ///      hops onto the rotated-out slot, returns carrying its balance, and the re-split restores targets.
    ///      Only the alignment move logs; the roll hops are silent.
    function test_Rebalance_RollsPileThroughFundedRotatedOutSlot() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        uint256 target = _weighted(30 ether, 5000);

        vm.recordLogs();
        vault.rebalance(NETUID1);

        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 1, "roll hops are silent; only the alignment logs");

        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "rotated-out slot consolidated by the roll");
        assertEq(_getVaultStake(hotkey1, NETUID1), target);
        assertEq(_getVaultStake(hotkey2, NETUID1), target);
        assertEq(vault.totalStake(TOKEN1), 30 ether, "total conserved");
    }

    function test_Unwrap_SucceedsWhenPriceReadsZero() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        (uint256 previewedAssets,) = vault.previewUnwrap(TOKEN1, shares);
        _setAlphaPriceReadsZero(NETUID1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));

        uint256 received = _userStakeAcrossHotkeys(alice, NETUID1);
        assertEq(received, previewedAssets, "zero oracle read falls through to the chain floor");
    }

    // All union balances sub-floor with rotated-out stake: no pile can clear the floor, so the drain
    // leaves the dust where it is. Blocking the call instead would let a few unmovable RAO wedge
    // every later deposit and withdrawal, so the dust stays remembered and stays in the backing.
    function test_Rebalance_LeavesUnmovableDustTracked() public {
        uint256 tokenId = _seedDustOnlyVault();
        uint256 dust = CHAIN_MIN_STAKE - 1;

        vault.rebalance(99);

        assertEq(_getVaultStake(hotkey4, 99), dust, "unmovable dust stays put");
        assertEq(vault.totalStake(tokenId), dust, "and stays inside the reported backing");
        bytes32[] memory seen = vault.lastSeenHotkeys(tokenId);
        assertEq(seen.length, 2, "the funded rotated-out slot stays remembered");
        assertEq(seen[0], hotkey1);
        assertEq(seen[1], hotkey4);
    }

    // The alpha rail refuses a delivery the chain's floor would reject; the TAO rail below exits it.
    function test_RevertWhen_UnwrappingDustOnlyVault() public {
        uint256 tokenId = _seedDustOnlyVault();

        uint256 shares = vault.balanceOf(alice, tokenId);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.WithdrawTooSmall.selector);
        vault.unwrap(tokenId, shares, _toSubstrate(alice));
    }

    // The rail ConsolidationBelowFloor points at: the same dust-only vault exits in full via the
    // floor-exempt full-balance sell.
    function test_UnwrapForTao_ExitsDustOnlyVault() public {
        uint256 tokenId = _seedDustOnlyVault();
        uint256 dust = CHAIN_MIN_STAKE - 1;

        uint256 shares = vault.balanceOf(alice, tokenId);
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(tokenId, shares, 0);

        assertEq(alice.balance - balanceBefore, dust, "full dust value recovered as TAO");
        assertEq(vault.totalStake(tokenId), 0, "nothing left behind");
    }

    // At a zero price read the consolidation cannot label the richest balance, so it falls through and the chain's
    // own full-precision floor rejects the roll with the raw error.
    function test_RevertWhen_ConsolidatingDustOnlyVaultAtZeroPrice() public {
        _seedDustOnlyVault();
        _setAlphaPriceReadsZero(99);

        vm.expectRevert(bytes("MockStaking: AmountTooLow"));
        vault.rebalance(99);
    }

    /// @dev A request larger than any single slot is delivered by gathering the current-set pile
    ///      onto one hotkey (each hop carries the whole pile) and then a single exact transfer.
    function test_Unwrap_GathersAcrossValidatorsForSingleDelivery() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        // Even 10/10/10 split so no single slot covers a >1/3 request.
        _setVaultStakes(NETUID1, 10 ether, 10 ether, 10 ether);

        uint256 burnShares = vault.balanceOf(alice, TOKEN1) * 60 / 100;
        (uint256 previewAssets,) = vault.previewUnwrap(TOKEN1, burnShares);
        assertGt(previewAssets, 10 ether, "request must exceed any single slot to force a gather");

        vm.prank(alice);
        vault.unwrap(TOKEN1, burnShares, _toSubstrate(alice));

        uint256 received = _userStakeAcrossHotkeys(alice, NETUID1);
        assertEq(received, previewAssets, "delivery is exact and matches the preview");
        uint256 receivedOnGatherTarget = MockStaking(STAKING_PRECOMPILE).getStake(hotkey2, _toSubstrate(alice), NETUID1);
        assertEq(receivedOnGatherTarget, previewAssets, "the whole delivery arrives in one transfer");
        assertEq(vault.totalStake(TOKEN1), 30 ether - previewAssets, "only the delivered alpha left the vault");
    }

    /// @dev The event reports the capped alpha payout when gather hops round the backing below the
    ///      nominal full-burn entitlement.
    function test_UnwrapEventReportsCappedAlphaPayoutAfterGatherRounding() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _setVaultStakes(NETUID1, 10 ether, 10 ether, 10 ether);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(1);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        uint256 expectedAlphaOut = 30 ether - 2;
        vm.expectEmit(true, true, false, true, address(vault));
        emit Unwrapped(alice, TOKEN1, shares, expectedAlphaOut);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));

        assertEq(_userStakeAcrossHotkeys(_toSubstrate(alice), NETUID1), expectedAlphaOut);
    }

    /// @dev A consolidation move the chain rejects reverts the whole call: nothing moves, the
    ///      remembered set is not refreshed, and the rotated-out stake is never dropped.
    function test_RevertWhen_RollerMoveFails() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 totalBefore = vault.totalStake(TOKEN1);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        MockStaking(STAKING_PRECOMPILE).setMoveStakeReverts(true);

        vm.expectRevert(bytes("MockStaking: moveStake reverted"));
        vault.rebalance(NETUID1);

        assertEq(vault.totalStake(TOKEN1), totalBefore, "backing unchanged after the reverted roll");
        assertGt(_getVaultStake(hotkey3, NETUID1), 0, "rotated-out stake not dropped");
        bytes32[] memory seen = vault.lastSeenHotkeys(TOKEN1);
        assertEq(seen[2], hotkey3, "remembered set still references the pre-rotation set");
    }

    /// @dev Oracle-soft wrap: when the spot price reads 0 the DepositTooSmall precheck is skipped
    ///      and the chain's own full-precision floor decides; an above-floor deposit is accepted.
    function test_Wrap_AcceptsDepositWhenPriceReadsZero() public {
        _setAlphaPriceReadsZero(NETUID1);
        _depositAndWrap(alice, NETUID1, 30 ether);

        assertGt(vault.balanceOf(alice, TOKEN1), 0, "wrap succeeds when the oracle reads 0");
        assertEq(vault.totalStake(TOKEN1), 30 ether, "full deposit backs the shares");
    }

    /// @dev Oracle-soft unwrapForTao: at a zero price read the partial-tail floor check is skipped,
    ///      so only the exempt full-drain slot sells and the tail comes back to the caller as shares.
    function test_UnwrapForTao_TailWaitsWhenPriceReadsZero() public {
        _setRemoveStakeRate(1, 1);
        _depositAndWrap(alice, NETUID1, 100 ether);
        // hotkey1 full-drains (floor-exempt); the remainder on hotkey3 would be a partial slice.
        uint256 total = _setVaultStakes(NETUID1, 5e6, 0, 40 ether);
        uint256 shares = _sharesForExactAssets(TOKEN1, 5e6 + 1e6, total);
        uint256 sharesBefore = vault.balanceOf(alice, TOKEN1);

        _setAlphaPriceReadsZero(NETUID1);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 5e6, "only the full-drain slot sold; partial tail waits");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "full drain sold");
        assertEq(_getVaultStake(hotkey3, NETUID1), 40 ether, "partial remainder left in the pool at price 0");
        (uint256 refundValue,) = vault.previewUnwrap(TOKEN1, vault.balanceOf(alice, TOKEN1) - (sharesBefore - shares));
        assertApproxEqAbs(refundValue, 1e6, 1, "the waiting tail came back as shares worth exactly it");
    }

    /// @dev A zero-price (sub-1e-9) vault still exits fully via floor-exempt full-balance sells.
    function test_UnwrapForTao_FullSlotExitWhenPriceReadsZero() public {
        _setRemoveStakeRate(1, 1);
        _setAlphaPriceReadsZero(NETUID1);
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 100 ether, "full-slot sells exit even when the oracle reads 0");
        assertEq(vault.totalStake(TOKEN1), 0);
    }
}
