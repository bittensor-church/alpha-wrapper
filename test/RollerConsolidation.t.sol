// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// @dev Exercises the whole-balance consolidation "roller": rotated-out stake (including sub-floor
///      dust) is rolled onto the current set with pile-sized, non-decreasing hops (the seed is the
///      binding floor check), any failure reverts atomically, redemption gathers for a single exact
///      delivery, and the spot oracle gates no value (a zero read falls through to the chain).
contract RollerConsolidationTest is AlphaVaultTestBase {
    /// @dev Registers subnet 99, wraps a deposit for alice on hotkey4, shaves the position to
    ///      sub-floor dust, and rotates hotkey4 out so the dust is a rotated-out orphan.
    function _seedDustOnlyVault() private returns (uint256 tokenId) {
        _registerSubnet(99, hotkey4);
        _simulateAlphaDepositHotkey(alice, 99, 10 ether, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);
        tokenId = vault.currentTokenId(99);
        _setVaultStake(hotkey4, 99, MIN_STAKE_FLOOR - 1);
        _setValidators(99, _hotkeys(hotkey1), _weights(10_000));
    }

    /// @dev Headline: two hotkeys rotate out at once and the roller chains the whole pile through
    ///      both, emptying each orphan and refreshing the snapshot - no tracking, no forfeiture.
    function test_Roller_ConsolidatesMultipleRotatedOrphans() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 totalBefore = vault.totalStake(TOKEN1);

        // Drop hotkey2 and hotkey3 in one rotation; the roll carries the pile through both orphans.
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey4), _weights(5000, 5000));
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey2, NETUID1), 0, "first orphan consolidated");
        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "second orphan consolidated");
        assertEq(vault.totalStake(TOKEN1), totalBefore, "total conserved across the chained roll");
        bytes32[3] memory seen = vault.lastSeenHotkeys(TOKEN1);
        assertEq(seen[0], hotkey1);
        assertEq(seen[1], hotkey4);
        assertEq(seen[2], bytes32(0), "snapshot refreshed to the 2-validator current set");
    }

    /// @dev A rotated-out sub-floor orphan with no other above-floor backing is still consolidated,
    ///      because wrap flushes the fresh deposit BEFORE the sweep so it seeds the roll. A
    ///      sweep-first order would put the sub-floor amount on the wire and revert.
    function test_Wrap_ConsolidatesOrphanUsingFreshDeposit() public {
        uint256 tokenId = _seedDustOnlyVault();
        uint256 dust = MIN_STAKE_FLOOR - 1;

        uint256 bobDeposit = 5 ether;
        _simulateAlphaDepositHotkey(bob, 99, bobDeposit, hotkey1);
        uint256 previewedShares = vault.previewWrap(tokenId, bobDeposit);
        _wrapHotkey(bob, 99, hotkey1);

        assertEq(vault.balanceOf(bob, tokenId), previewedShares, "mint parity with the union-priced preview");
        assertEq(_getVaultStake(hotkey4, 99), 0, "dust orphan consolidated by the roll");
        assertEq(vault.totalStake(tokenId), bobDeposit + dust, "orphan folded into the current-set backing");
        bytes32[3] memory seen = vault.lastSeenHotkeys(tokenId);
        assertEq(seen[0], hotkey1, "snapshot refreshed to the current set");
    }

    /// @dev Full-set rotation where the RICHER orphan sits at a later snapshot index: the roll
    ///      seeds from it, and revisiting the seed's slot must not re-add its departed balance.
    function test_Roller_ConsolidatesWhenRicherOrphanSitsAtLaterIndex() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(3000, 7000));
        _depositAndWrap(alice, NETUID1, 10 ether);
        uint256 totalBefore = vault.totalStake(TOKEN1);

        // Rotate BOTH validators out; the 70%-weighted hotkey2 is the richest orphan at index 1.
        _setValidators(NETUID1, _hotkeys(hotkey4), _weights(10_000));
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "earlier orphan consolidated");
        assertEq(_getVaultStake(hotkey2, NETUID1), 0, "seed orphan consolidated");
        assertEq(_getVaultStake(hotkey4, NETUID1), totalBefore, "whole pile landed on the current set");
        assertEq(vault.totalStake(TOKEN1), totalBefore, "total conserved");
    }

    function test_Unwrap_SucceedsWhenPriceReadsZero() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        (uint256 previewedAssets,) = vault.previewUnwrap(TOKEN1, shares);
        _setAlphaPriceZero(NETUID1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));

        uint256 received = _userStakeAcrossHotkeys(alice, NETUID1);
        assertEq(received, previewedAssets, "zero oracle read falls through to the chain floor");
    }

    // All union balances sub-floor with a rotated-out orphan: no pile can clear the floor, so
    // consolidation is rejected up front while the TAO rail stays open.
    function test_RevertWhen_ConsolidatingDustOnlyVault() public {
        _seedDustOnlyVault();

        vm.expectRevert(AlphaVault.ConsolidationBelowFloor.selector);
        vault.rebalance(99);
    }

    // A dust-only vault rejects unwrap inside the sweep, before any chain call.
    function test_RevertWhen_UnwrappingDustOnlyVault() public {
        uint256 tokenId = _seedDustOnlyVault();

        uint256 shares = vault.balanceOf(alice, tokenId);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ConsolidationBelowFloor.selector);
        vault.unwrap(tokenId, shares, _toSubstrate(alice));
    }

    // At a zero price read the sweep cannot label the seed, so it falls through and the chain's
    // own full-precision floor rejects the roll with the raw error.
    function test_RevertWhen_ConsolidatingDustOnlyVaultAtZeroPrice() public {
        _seedDustOnlyVault();
        _setAlphaPriceZero(99);

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

        vm.recordLogs();
        vm.prank(alice);
        vault.unwrap(TOKEN1, burnShares, _toSubstrate(alice));

        uint256 received = _userStakeAcrossHotkeys(alice, NETUID1);
        assertEq(received, previewAssets, "delivery is exact and matches the preview");
        assertGe(_countRebalancedLogs(vm.getRecordedLogs()), 1, "gather and re-split emit Rebalanced");
        assertEq(vault.totalStake(TOKEN1), 30 ether - previewAssets, "only the delivered alpha left the vault");
    }

    /// @dev A consolidation move the chain rejects reverts the whole call: nothing moves, the
    ///      snapshot is not refreshed, and the orphan is never dropped.
    function test_RevertWhen_RollerMoveFails() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 totalBefore = vault.totalStake(TOKEN1);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        MockStaking(STAKING_PRECOMPILE).setMoveStakeReverts(true);

        vm.expectRevert(bytes("MockStaking: moveStake reverted"));
        vault.rebalance(NETUID1);

        assertEq(vault.totalStake(TOKEN1), totalBefore, "backing unchanged after the reverted roll");
        assertGt(_getVaultStake(hotkey3, NETUID1), 0, "orphan not dropped");
        bytes32[3] memory seen = vault.lastSeenHotkeys(TOKEN1);
        assertEq(seen[2], hotkey3, "snapshot still references the pre-rotation set");
    }

    /// @dev Oracle-soft wrap: when the spot price reads 0 the DepositTooSmall precheck is skipped
    ///      and the chain's own full-precision floor decides; an above-floor deposit is accepted.
    function test_Wrap_AcceptsDepositWhenPriceReadsZero() public {
        _setAlphaPriceZero(NETUID1);
        _depositAndWrap(alice, NETUID1, 30 ether);

        assertGt(vault.balanceOf(alice, TOKEN1), 0, "wrap succeeds when the oracle reads 0");
        assertEq(vault.totalStake(TOKEN1), 30 ether, "full deposit backs the shares");
    }

    /// @dev Oracle-soft unwrapForTao: at a zero price read the partial-tail floor check is skipped,
    ///      so only the exempt full-drain slot sells and the tail waits as bounded dust.
    function test_UnwrapForTao_TailWaitsWhenPriceReadsZero() public {
        _setRemoveStakeRate(1, 1);
        _depositAndWrap(alice, NETUID1, 100 ether);
        // hotkey1 full-drains (floor-exempt); the remainder on hotkey3 would be a partial slice.
        uint256 total = _setVaultStakes(NETUID1, 5e6, 0, 40 ether);
        uint256 shares = _sharesForExactAssets(TOKEN1, 5e6 + 1e6, total);

        _setAlphaPriceZero(NETUID1);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 5e6, "only the full-drain slot sold; partial tail waits");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "full drain sold");
        assertEq(_getVaultStake(hotkey3, NETUID1), 40 ether, "partial remainder left in the pool at price 0");
    }

    /// @dev A zero-price (sub-1e-9) vault still exits fully via floor-exempt full-balance sells.
    function test_UnwrapForTao_FullSlotExitWhenPriceReadsZero() public {
        _setRemoveStakeRate(1, 1);
        _setAlphaPriceZero(NETUID1);
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 100 ether, "full-slot sells exit even when the oracle reads 0");
        assertEq(vault.totalStake(TOKEN1), 0);
    }
}
