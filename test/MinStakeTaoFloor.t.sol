// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Vm } from "forge-std/Test.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// @dev Exercises the TAO-denominated min-stake floor
contract MinStakeTaoFloorTest is AlphaVaultTestBase {
    event Withdrawn(address indexed user, uint256 indexed tokenId, uint256 shares, uint256 assets);

    uint256 private constant PRICE_HALF = 0.5e18;

    function _assetsFor(uint256 shares, uint256 totalAlpha, uint256 supply) private pure returns (uint256) {
        return (shares * (totalAlpha + 1)) / (supply + 1e9);
    }

    function _setStake(bytes32 hotkey, uint256 netuid, uint256 amount) private {
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey, _subnetColdkey(netuid), netuid, amount);
    }

    function test_ProcessDeposit_RevertsDepositTooSmall_WhenBelowTaoFloor() public {
        _setValidators(99, _hotkeys(hotkey4), _weights(10_000));
        _setRegBlock(99, 300);
        _setAlphaPrice(99, PRICE_HALF);

        // 3e6 alpha = 1.5e6 tao, below the 2e6 floor.
        _simulateAlphaDepositHotkey(alice, 99, 3e6, hotkey4);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.DepositTooSmall.selector);
        vault.processDeposit(alice, 99, hotkey4);
    }

    function test_ProcessDeposit_Succeeds_AtTaoFloorBoundaryUnderLowPrice() public {
        _setValidators(99, _hotkeys(hotkey4), _weights(10_000));
        _setRegBlock(99, 300);
        _setAlphaPrice(99, PRICE_HALF);

        // 4e6 alpha = 2e6 tao, exactly the floor.
        _simulateAlphaDepositHotkey(alice, 99, 4e6, hotkey4);
        _processDepositHotkey(alice, 99, hotkey4);

        bytes32 cloneCk = _toSubstrate(vault.subnetClone(vault.currentTokenId(99)));
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey4, cloneCk, 99), 4e6);
        assertGt(vault.balanceOf(alice, vault.currentTokenId(99)), 0);
    }

    function test_Rebalance_SkipsSubFloorMove() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, NETUID1, 8e6, hotkey1);
        _processDepositHotkey(alice, NETUID1, hotkey1);

        _setAlphaPrice(NETUID1, PRICE_HALF);
        // Target is 4e6 / 4e6; the corrective move of 2e6 alpha is only 1e6 tao, below the floor.
        _setStake(hotkey1, NETUID1, 6e6);
        _setStake(hotkey2, NETUID1, 2e6);

        vm.recordLogs();
        vault.rebalance(NETUID1);
        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0, "sub-floor move skipped, not attempted");
        assertEq(_getVaultStake(hotkey1, NETUID1), 6e6);
        assertEq(_getVaultStake(hotkey2, NETUID1), 2e6);
    }

    function test_Rebalance_DropsRotatedOutSubFloorDust() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _processDeposit(alice, NETUID1);

        _setAlphaPrice(NETUID1, PRICE_HALF);
        // 3e6 alpha clears the old alpha threshold but is 1.5e6 tao, below the floor.
        _setStake(hotkey3, NETUID1, 3e6);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));

        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey3, NETUID1), 3e6, "non-transferable orphan dropped, not reverted");
        assertEq(vault.lastSeenHotkeys(TOKEN1)[2], hotkey4, "snapshot refreshed to current set");
    }

    function test_Withdraw_SkipsSubFloorValidator_DeliversInFullFromNext() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, NETUID1, 40e6, hotkey1);
        _processDepositHotkey(alice, NETUID1, hotkey1);

        _setAlphaPrice(NETUID1, PRICE_HALF);
        // hotkey1 holds 1e6 alpha = 0.5e6 tao, below the 2e6 floor; hotkey2 covers the request.
        _setStake(hotkey1, NETUID1, 1e6);
        _setStake(hotkey2, NETUID1, 40e6);

        uint256 burnShares = vault.balanceOf(alice, TOKEN1) / 2;
        (uint256 expectedAssets,) = vault.previewWithdraw(TOKEN1, burnShares);

        vm.prank(alice);
        vault.withdraw(TOKEN1, burnShares, _toSubstrate(alice), 0);

        uint256 received = _getStake(hotkey1, alice, NETUID1) + _getStake(hotkey2, alice, NETUID1);
        assertEq(received, expectedAssets, "skip-to-next delivers the full previewed amount");
        assertEq(_getStake(hotkey1, alice, NETUID1), 0, "nothing transferable from the sub-floor slot");
    }

    function test_Withdraw_UnderDeliversBoundedDust_OnSubFloorFinalRemainder() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, NETUID1, 20e6, hotkey1);
        _processDepositHotkey(alice, NETUID1, hotkey1);

        _setAlphaPrice(NETUID1, PRICE_HALF);
        // Balanced 10e6 / 10e6. Burning 55% targets 11e6 of assets; hotkey1 yields 10e6 and the
        // 1e6 final remainder (0.5e6 tao) is non-transferable, so the caller absorbs it.
        uint256 supply = vault.totalSupply(TOKEN1);
        uint256 burnShares = vault.balanceOf(alice, TOKEN1) * 55 / 100;
        assertEq(_assetsFor(burnShares, 20e6, supply), 11e6, "intended assets");

        vm.expectEmit(true, true, false, true, address(vault));
        emit Withdrawn(alice, TOKEN1, burnShares, 10e6);

        vm.prank(alice);
        vault.withdraw(TOKEN1, burnShares, _toSubstrate(alice), 0);

        assertEq(_getStake(hotkey1, alice, NETUID1) + _getStake(hotkey2, alice, NETUID1), 10e6, "delivered capped");
        assertEq(vault.totalStake(TOKEN1), 10e6, "the 1e6 under-delivered dust stays in the vault");
    }

    function test_Withdraw_RevertsSlippage_WhenDeliveredBelowMinAlphaOut() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, NETUID1, 20e6, hotkey1);
        _processDepositHotkey(alice, NETUID1, hotkey1);

        _setAlphaPrice(NETUID1, PRICE_HALF);
        // Balanced 10e6 / 10e6; burning 55% targets 11e6 but only 10e6 is transferable.
        uint256 burnShares = vault.balanceOf(alice, TOKEN1) * 55 / 100;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AlphaVault.SlippageExceeded.selector, 10e6));
        vault.withdraw(TOKEN1, burnShares, _toSubstrate(alice), 11e6);

        vm.prank(alice);
        vault.withdraw(TOKEN1, burnShares, _toSubstrate(alice), 10e6);
        assertEq(_getStake(hotkey1, alice, NETUID1) + _getStake(hotkey2, alice, NETUID1), 10e6, "delivers at floor");
    }

    function test_Withdraw_RevertsWithdrawTooSmall_WhenEntireRequestBelowFloor() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, NETUID1, 40e6, hotkey1);
        _processDepositHotkey(alice, NETUID1, hotkey1);

        _setAlphaPrice(NETUID1, PRICE_HALF);
        uint256 burnShares = vault.balanceOf(alice, TOKEN1) * 5 / 100;

        vm.prank(alice);
        vm.expectRevert(AlphaVault.WithdrawTooSmall.selector);
        vault.withdraw(TOKEN1, burnShares, _toSubstrate(alice), 0);
    }
}
