// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { VaultMath } from "src/libraries/VaultMath.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { ConsolidationBelowFloor } from "src/VaultErrors.sol";
import { CHAIN_MIN_STAKE, MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract RollerConsolidationTest is AlphaVaultTestBase {
    event Unwrapped(address indexed user, uint256 indexed tokenId, uint256 shares, uint256 alphaOut);

    function _seedDustOnlyVault() private returns (uint256 tokenId) {
        _registerSubnet(99, hotkey4);
        _simulateAlphaDepositHotkey(alice, 99, 10 ether, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);
        tokenId = vault.currentTokenId(99);
        _plantVaultStake(hotkey4, 99, CHAIN_MIN_STAKE - 1);
        _setValidators(99, _hotkeys(hotkey1), _weights(VaultMath.BPS_BASE));
    }

    function test_Rebalance_ConsolidatesMultipleRotatedOutSlots() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 totalBefore = lens.totalStake(TOKEN1);

        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey4), _weights(5000, 5000));
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey2, NETUID1), 0, "first rotated-out slot consolidated");
        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "second rotated-out slot consolidated");
        assertEq(lens.totalStake(TOKEN1), totalBefore, "total conserved across the chained roll");
        bytes32[] memory seen = _lastSeen(TOKEN1);
        assertEq(seen.length, 2, "remembered set refreshed to the 2-validator current set");
        assertEq(seen[0], hotkey1);
        assertEq(seen[1], hotkey4);
    }

    /// @dev Flushing before consolidation lets the fresh deposit carry otherwise-unmovable dust.
    function test_Wrap_ConsolidatesRotatedOutStakeUsingFreshDeposit() public {
        uint256 tokenId = _seedDustOnlyVault();
        uint256 dust = CHAIN_MIN_STAKE - 1;

        uint256 bobDeposit = 5 ether;
        _simulateAlphaDepositHotkey(bob, 99, bobDeposit, hotkey1);
        uint256 previewedShares = lens.previewWrap(tokenId, bobDeposit);
        _wrapHotkey(bob, 99, hotkey1);

        assertEq(vault.balanceOf(bob, tokenId), previewedShares, "mint parity with the union-priced preview");
        assertEq(_getVaultStake(hotkey4, 99), 0, "rotated-out dust consolidated by the roll");
        assertEq(lens.totalStake(tokenId), bobDeposit + dust, "rotated-out stake folded into the current-set backing");
        bytes32[] memory seen = _lastSeen(tokenId);
        assertEq(seen[0], hotkey1, "remembered set refreshed to the current set");
    }

    /// @dev Revisiting the richest slot after its pile has left would reuse a stale balance.
    function test_Rebalance_ConsolidatesWhenRicherRotatedOutSlotSitsAtLaterIndex() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(3000, 7000));
        _depositAndWrap(alice, NETUID1, 10 ether);
        uint256 totalBefore = lens.totalStake(TOKEN1);

        _setValidators(NETUID1, _hotkeys(hotkey4), _weights(VaultMath.BPS_BASE));
        vm.recordLogs();
        vault.rebalance(NETUID1);

        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0, "pure consolidation emits nothing");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "earlier rotated-out slot consolidated");
        assertEq(_getVaultStake(hotkey2, NETUID1), 0, "richest rotated-out slot consolidated");
        assertEq(_getVaultStake(hotkey4, NETUID1), totalBefore, "whole pile landed on the current set");
        assertEq(lens.totalStake(TOKEN1), totalBefore, "total conserved");
    }

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
        assertEq(lens.totalStake(TOKEN1), 30 ether, "total conserved");
    }

    /// @dev Short-credited moves require live balance reads; arithmetic sums over-ask the next hop.
    function test_Rebalance_FoldsDustAfterShortCreditedDrain() public {
        _setRegBlock(99, 300);
        _setValidators(99, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, 99, 30 ether, hotkey1);
        _wrapHotkey(alice, 99, hotkey1);
        uint256 tokenId = vault.currentTokenId(99);

        uint256 dust = CHAIN_MIN_STAKE - 1;
        _plantVaultStake(hotkey1, 99, 30 ether);
        _plantVaultStake(hotkey2, 99, dust);
        _setValidators(99, _hotkeys(hotkey4), _weights(VaultMath.BPS_BASE));
        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(1);

        vault.rebalance(99);

        assertEq(_getVaultStake(hotkey1, 99), 0, "drained validator emptied");
        assertEq(_getVaultStake(hotkey2, 99), 0, "dust folded off the second dropped validator");
        assertEq(lens.totalStake(tokenId), _getVaultStake(hotkey4, 99), "backing all sits on the current set");
        assertEq(_lastSeen(tokenId).length, 1, "nothing left to remember");
    }

    function test_Unwrap_SucceedsWhenPriceReadsZero() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        (uint256 previewedAssets,) = lens.previewUnwrap(TOKEN1, shares);
        _setAlphaPriceReadsZero(NETUID1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        uint256 received = _userStakeAcrossHotkeys(alice, NETUID1);
        assertEq(received, previewedAssets, "zero oracle read falls through to the chain floor");
    }

    function test_RevertWhen_ConsolidatingDustOnlyVault() public {
        _seedDustOnlyVault();

        vm.expectRevert(ConsolidationBelowFloor.selector);
        vault.rebalance(99);
    }

    function test_RevertWhen_UnwrappingDustOnlyVault() public {
        uint256 tokenId = _seedDustOnlyVault();

        uint256 shares = vault.balanceOf(alice, tokenId);
        vm.prank(alice);
        vm.expectRevert(ConsolidationBelowFloor.selector);
        vault.unwrap(tokenId, shares, _toSubstrate(alice), 0);
    }

    function test_UnwrapForTao_ExitsDustOnlyVault() public {
        uint256 tokenId = _seedDustOnlyVault();
        uint256 dust = CHAIN_MIN_STAKE - 1;

        uint256 shares = vault.balanceOf(alice, tokenId);
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(tokenId, shares, 0);

        assertEq(alice.balance - balanceBefore, dust, "full dust value recovered as TAO");
        assertEq(lens.totalStake(tokenId), 0, "nothing left behind");
    }

    function test_RevertWhen_ConsolidatingDustOnlyVaultAtZeroPrice() public {
        _seedDustOnlyVault();
        _setAlphaPriceReadsZero(99);

        vm.expectRevert(bytes("MockStaking: AmountTooLow"));
        vault.rebalance(99);
    }

    function test_Unwrap_GathersAcrossValidatorsForSingleDelivery() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _plantVaultStakes(NETUID1, 10 ether, 10 ether, 10 ether);

        uint256 burnShares = vault.balanceOf(alice, TOKEN1) * 60 / 100;
        (uint256 previewAssets,) = lens.previewUnwrap(TOKEN1, burnShares);
        assertGt(previewAssets, 10 ether, "request must exceed any single slot to force a gather");

        vm.prank(alice);
        vault.unwrap(TOKEN1, burnShares, _toSubstrate(alice), 0);

        uint256 received = _userStakeAcrossHotkeys(alice, NETUID1);
        assertEq(received, previewAssets, "delivery is exact and matches the preview");
        uint256 receivedOnGatherTarget = MockStaking(STAKING_PRECOMPILE).getStake(hotkey2, _toSubstrate(alice), NETUID1);
        assertEq(receivedOnGatherTarget, previewAssets, "the whole delivery arrives in one transfer");
        assertEq(lens.totalStake(TOKEN1), 30 ether - previewAssets, "only the delivered alpha left the vault");
    }

    function test_UnwrapEventReportsCappedAlphaPayoutAfterGatherRounding() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _plantVaultStakes(NETUID1, 10 ether, 10 ether, 10 ether);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(1);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        uint256 expectedAlphaOut = 30 ether - 2;
        vm.expectEmit(true, true, false, true, address(vault));
        emit Unwrapped(alice, TOKEN1, shares, expectedAlphaOut);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(_userStakeAcrossHotkeys(_toSubstrate(alice), NETUID1), expectedAlphaOut);
    }

    function test_RevertWhen_RollerMoveFails() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 totalBefore = lens.totalStake(TOKEN1);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        MockStaking(STAKING_PRECOMPILE).setMoveStakeReverts(true);

        vm.expectRevert(bytes("MockStaking: moveStake reverted"));
        vault.rebalance(NETUID1);

        assertEq(lens.totalStake(TOKEN1), totalBefore, "backing unchanged after the reverted roll");
        assertGt(_getVaultStake(hotkey3, NETUID1), 0, "rotated-out stake not dropped");
        bytes32[] memory seen = _lastSeen(TOKEN1);
        assertEq(seen[2], hotkey3, "remembered set still references the pre-rotation set");
    }

    function test_Wrap_AcceptsDepositWhenPriceReadsZero() public {
        _setAlphaPriceReadsZero(NETUID1);
        _depositAndWrap(alice, NETUID1, 30 ether);

        assertGt(vault.balanceOf(alice, TOKEN1), 0, "wrap succeeds when the oracle reads 0");
        assertEq(lens.totalStake(TOKEN1), 30 ether, "full deposit backs the shares");
    }

    function test_UnwrapForTao_TailWaitsWhenPriceReadsZero() public {
        _setRemoveStakeRate(1, 1);
        _depositAndWrap(alice, NETUID1, 100 ether);
        uint256 total = _plantVaultStakes(NETUID1, 5e6, 0, 40 ether);
        uint256 shares = _sharesForExactAssets(TOKEN1, 5e6 + 1e6, total);
        uint256 sharesBefore = vault.balanceOf(alice, TOKEN1);

        _setAlphaPriceReadsZero(NETUID1);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 5e6, "only the full-drain slot sold; partial tail waits");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "full drain sold");
        assertEq(_getVaultStake(hotkey3, NETUID1), 40 ether, "partial remainder left in the pool at price 0");
        (uint256 refundValue,) = lens.previewUnwrap(TOKEN1, vault.balanceOf(alice, TOKEN1) - (sharesBefore - shares));
        assertApproxEqAbs(refundValue, 1e6, 1, "the waiting tail came back as shares worth exactly it");
    }

    function test_UnwrapForTao_FullSlotExitWhenPriceReadsZero() public {
        _setRemoveStakeRate(1, 1);
        _setAlphaPriceReadsZero(NETUID1);
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 100 ether, "full-slot sells exit even when the oracle reads 0");
        assertEq(lens.totalStake(TOKEN1), 0);
    }
}
