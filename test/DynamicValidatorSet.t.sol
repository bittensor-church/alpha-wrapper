// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { CHAIN_MIN_STAKE } from "./mocks/MockStaking.sol";
import { MAX_VALIDATORS } from "src/ValidatorRegistry.sol";

contract DynamicValidatorSetTest is AlphaVaultTestBase {
    /// @dev The dropped balance clears the move floor, but dividing it across 63 deficits does not.
    uint256 private constant UNSPREADABLE_DEPOSIT = 1e9;

    function test_Wrap_SpreadsAcrossFullValidatorCap() public {
        bytes32[] memory hks = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _depositAndWrap(alice, NETUID1, 10 ether);

        _assertEvenSpread(hks, NETUID1, 10 ether);
        assertEq(lens.totalStake(TOKEN1), 10 ether);
    }

    function test_Wrap_StakesWholePositionOnSingleValidator() public {
        bytes32[] memory hks = _setValidatorCount(NETUID1, 1);
        _depositAndWrap(alice, NETUID1, 10 ether);

        assertEq(_getVaultStake(hks[0], NETUID1), 10 ether);
        assertEq(lens.totalStake(TOKEN1), 10 ether);
    }

    function test_Rebalance_ShrinkFromCapLeavesNoStaleTail() public {
        bytes32[] memory wide = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _depositAndWrap(alice, NETUID1, 10 ether);

        bytes32[] memory narrow = _setValidatorCount(NETUID1, 3);
        vault.rebalance(NETUID1);

        for (uint256 i = 3; i < MAX_VALIDATORS; ++i) {
            assertEq(_getVaultStake(wide[i], NETUID1), 0, "dropped validator still funded");
        }
        assertEq(lens.totalStake(TOKEN1), 10 ether, "total conserved across the shrink");
        assertEq(_lastSeen(TOKEN1).length, 3, "remembered set carries no stale tail");

        _assertEvenSpread(narrow, NETUID1, 10 ether);
    }

    function test_Rebalance_GrowToCapSpreadsAcrossFullSet() public {
        _setValidatorCount(NETUID1, 3);
        _depositAndWrap(alice, NETUID1, 10 ether);

        bytes32[] memory wide = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        vault.rebalance(NETUID1);

        _assertEvenSpread(wide, NETUID1, 10 ether);
        assertEq(lens.totalStake(TOKEN1), 10 ether);
        assertEq(_lastSeen(TOKEN1).length, MAX_VALIDATORS);
    }

    function test_Rebalance_DrainsDroppedBalanceTooSmallToSpread() public {
        bytes32[] memory wide = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _depositAndWrap(alice, NETUID1, UNSPREADABLE_DEPOSIT);

        uint256 dropped = _getVaultStake(wide[MAX_VALIDATORS - 1], NETUID1);
        assertGt(dropped, CHAIN_MIN_STAKE, "the dropped balance must be worth moving");
        assertLt(dropped / (MAX_VALIDATORS - 1), CHAIN_MIN_STAKE, "and impossible to spread");

        _setValidatorCount(NETUID1, MAX_VALIDATORS - 1);
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(wide[MAX_VALIDATORS - 1], NETUID1), 0, "dropped validator swept");
        assertEq(lens.totalStake(TOKEN1), UNSPREADABLE_DEPOSIT, "total conserved");
        assertEq(_lastSeen(TOKEN1).length, MAX_VALIDATORS - 1, "nothing left to remember");
    }

    function test_Rebalance_SweepsFullRotationAtTheCap() public {
        bytes32[] memory first = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _depositAndWrap(alice, NETUID1, 10 ether);

        bytes32[] memory second = _hotkeysFrom("second-wave", MAX_VALIDATORS);
        _setValidators(NETUID1, second, _evenWeights(MAX_VALIDATORS));

        assertEq(lens.totalStake(TOKEN1), 10 ether, "union read prices the whole position");

        vault.rebalance(NETUID1);

        for (uint256 i; i < MAX_VALIDATORS; ++i) {
            assertEq(_getVaultStake(first[i], NETUID1), 0, "old set fully swept");
        }
        assertEq(_vaultStakeAcross(second, NETUID1), 10 ether, "whole position landed on the new set");
        assertEq(_lastSeen(TOKEN1).length, MAX_VALIDATORS);
    }

    function test_UnwrapForTao_ExitsFullyRotatedPosition() public {
        _setValidatorCount(NETUID1, 3);
        _depositAndWrap(alice, NETUID1, 10 ether);

        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 10 ether, "rotated-out position sold in full");
        assertEq(lens.totalStake(TOKEN1), 0);
    }

    function test_Rebalance_DrainsRotationAtUnreadablePrice() public {
        bytes32[] memory wide = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _depositAndWrap(alice, NETUID1, 10 ether);
        _setAlphaPriceReadsZero(NETUID1);
        assertEq(_alphaPriceRead(NETUID1), 0, "the read must be unusable for this to mean anything");

        _setValidatorCount(NETUID1, MAX_VALIDATORS - 1);
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(wide[MAX_VALIDATORS - 1], NETUID1), 0, "dropped validator swept");
        assertEq(lens.totalStake(TOKEN1), 10 ether);
    }

    function test_Wrap_KeepsSmallPositionWholeWhenTargetsFallBelowFloor() public {
        bytes32[] memory hks = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        uint256 deposit = 4 * CHAIN_MIN_STAKE;
        assertLt(deposit / MAX_VALIDATORS, CHAIN_MIN_STAKE, "no per-slot target may be movable");

        _depositAndWrap(alice, NETUID1, deposit);

        assertEq(_getVaultStake(hks[0], NETUID1), deposit, "position stays where it landed");
        assertEq(lens.totalStake(TOKEN1), deposit, "and is fully priced");
    }

    // Keep every target above the chain floor so assertions can require exact placement.
    uint256 private constant MIN_SPREADABLE = 1 ether;
    uint256 private constant MAX_DEPOSIT = 1_000 ether;

    function testFuzz_Wrap_SpreadsAcrossAnyValidatorCount(uint256 count, uint256 amount) public {
        count = bound(count, 1, MAX_VALIDATORS);
        amount = bound(amount, MIN_SPREADABLE, MAX_DEPOSIT);

        bytes32[] memory hks = _setValidatorCount(NETUID1, count);
        _depositAndWrap(alice, NETUID1, amount);

        _assertEvenSpread(hks, NETUID1, amount);
        assertEq(lens.totalStake(TOKEN1), amount);
    }

    function testFuzz_Rebalance_RotationPreservesTotal(uint256 fromCount, uint256 toCount, uint256 amount) public {
        fromCount = bound(fromCount, 1, MAX_VALIDATORS);
        toCount = bound(toCount, 1, MAX_VALIDATORS);
        amount = bound(amount, MIN_SPREADABLE, MAX_DEPOSIT);

        _setValidatorCount(NETUID1, fromCount);
        _depositAndWrap(alice, NETUID1, amount);

        bytes32[] memory rotated = _hotkeysFrom("rotated", toCount);
        _setValidators(NETUID1, rotated, _evenWeights(toCount));

        vault.rebalance(NETUID1);

        assertEq(_vaultStakeAcross(rotated, NETUID1), amount, "whole position moved to the new set");
        assertEq(lens.totalStake(TOKEN1), amount);
        assertEq(_lastSeen(TOKEN1).length, toCount, "the remembered set follows the new one");
    }

    function testFuzz_Unwrap_DeliversPreviewAtAnyValidatorCount(uint256 count, uint256 amount, uint256 burnBps) public {
        count = bound(count, 1, MAX_VALIDATORS);
        amount = bound(amount, MIN_SPREADABLE, MAX_DEPOSIT);
        burnBps = bound(burnBps, 1, BPS_BASE);

        bytes32[] memory hks = _setValidatorCount(NETUID1, count);
        _depositAndWrap(alice, NETUID1, amount);

        uint256 shares = vault.balanceOf(alice, TOKEN1) * burnBps / BPS_BASE;
        (uint256 previewAlpha,) = lens.previewUnwrap(TOKEN1, shares);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(_stakeAcross(hks, _toSubstrate(alice), NETUID1), previewAlpha, "delivery matches the quote");
        assertEq(lens.totalStake(TOKEN1), amount - previewAlpha, "only the delivered alpha left the vault");
    }
}
