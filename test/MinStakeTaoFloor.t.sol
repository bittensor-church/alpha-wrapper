// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Exercises the TAO-denominated min-stake floor: the wrap/withdraw labels, the best-effort
///      rebalance skip, exact-or-revert delivery, and the owner knob.
contract MinStakeTaoFloorTest is AlphaVaultTestBase {
    event MinStakeTaoFloorUpdated(uint256 oldValue, uint256 newValue);

    uint256 private constant PRICE_HALF = 0.5e18;

    function test_Wrap_RevertsDepositTooSmallBelowTaoFloor() public {
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, PRICE_HALF);

        // 3e6 alpha = 1.5e6 tao, below the 2e6 floor.
        _simulateAlphaDepositHotkey(alice, 99, 3e6, hotkey4);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.DepositTooSmall.selector);
        vault.wrap(alice, 99, hotkey4);
    }

    function test_Wrap_SucceedsAtTaoFloorBoundaryUnderLowPrice() public {
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, PRICE_HALF);

        // 4e6 alpha = 2e6 tao, exactly the floor.
        _simulateAlphaDepositHotkey(alice, 99, 4e6, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), 4e6);
        assertGt(vault.balanceOf(alice, vault.currentTokenId(99)), 0);
    }

    function test_Rebalance_SkipsSubFloorMove() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, NETUID1, 8e6, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        _setAlphaPrice(NETUID1, PRICE_HALF);
        // Target is 4e6 / 4e6; the corrective move of 2e6 alpha is only 1e6 tao, below the floor.
        _setVaultStake(hotkey1, NETUID1, 6e6);
        _setVaultStake(hotkey2, NETUID1, 2e6);

        vm.recordLogs();
        vault.rebalance(NETUID1);
        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0, "sub-floor move skipped pre-call");
        assertEq(_getVaultStake(hotkey1, NETUID1), 6e6);
        assertEq(_getVaultStake(hotkey2, NETUID1), 2e6);
    }

    // The floor is the only rejection the pre-check can rule out, so anything else is exceptional
    // and must bubble; catching it could not help, because a rejected precompile call has already
    // consumed the forwarded gas.
    function test_RevertWhen_RebalanceMoveFailsAboveFloor() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, NETUID1, 8e6, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        // The corrective move of 2e6 clears the floor, yet the chain rejects it; the fault bubbles.
        _setVaultStake(hotkey1, NETUID1, 6e6);
        _setVaultStake(hotkey2, NETUID1, 2e6);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeReverts(true);

        vm.expectRevert(bytes("MockStaking: moveStake reverted"));
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 6e6, "balances unchanged after the bubbled failure");
        assertEq(_getVaultStake(hotkey2, NETUID1), 2e6);
    }

    // The real precompile consumes all forwarded gas when it rejects a call, so a doomed rebalance
    // move must be skipped without ever being attempted; the whole wrap fits a fixed budget only then.
    function test_Wrap_SkipsSubFloorRebalanceWithinGasBudget() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        MockStaking(STAKING_PRECOMPILE).setConsumeAllGasOnFailure(true);
        _setAlphaPrice(NETUID1, PRICE_HALF);

        // 6e6 alpha = 3e6 tao clears the deposit floor; the 3e6-alpha split move is 1.5e6 tao and does not.
        _simulateAlphaDepositHotkey(alice, NETUID1, 6e6, hotkey1);
        vm.recordLogs();
        vm.prank(alice);
        vault.wrap{ gas: 1_500_000 }(alice, NETUID1, hotkey1);

        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0, "doomed move never attempted");
        assertGt(vault.balanceOf(alice, TOKEN1), 0, "wrap completed within the fixed gas budget");
    }

    // Every slot is individually below the floor while the request clears it: the gather's first
    // hop could never clear the chain's floor, so the redemption is rejected up front.
    function test_Unwrap_RevertsWithdrawTooSmallWhenAllSlotsSubFloor() public {
        _depositAndWrap(alice, NETUID1, 4_500_000);
        _setVaultStakes(NETUID1, 1_500_000, 1_500_000, 1_500_000);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.WithdrawTooSmall.selector);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));
    }

    function test_Unwrap_RevertsWithdrawTooSmallWhenRequestBelowFloor() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, NETUID1, 40e6, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        _setAlphaPrice(NETUID1, PRICE_HALF);
        uint256 burnShares = vault.balanceOf(alice, TOKEN1) * 5 / 100;

        vm.prank(alice);
        vm.expectRevert(AlphaVault.WithdrawTooSmall.selector);
        vault.unwrap(TOKEN1, burnShares, _toSubstrate(alice));
    }

    // Delivery is exact-or-revert: the gather target's transfer is bare, so a chain rejection
    // bubbles and the whole redemption rolls back with shares intact.
    function test_RevertWhen_DeliveryTransferFails() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, NETUID1, 40e6, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        // A full drain gathers onto one hotkey then delivers via transferStake; force it to fail.
        MockStaking(STAKING_PRECOMPILE).setTransferStakeReverts(true);

        uint256 sharesBefore = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vm.expectRevert(bytes("MockStaking: transferStake reverted"));
        vault.unwrap(TOKEN1, sharesBefore, _toSubstrate(alice));

        assertEq(vault.balanceOf(alice, TOKEN1), sharesBefore, "shares intact after bubbled failure");
    }

    // Above the floor delivery is exact: what previewUnwrap quotes is exactly what unwrap pays.
    function testFuzz_Unwrap_DeliversExactlyPreview(uint256 priceE18, uint256 deposit) public {
        priceE18 = bound(priceE18, 0.1e18, 100e18);
        uint256 floorAlpha = (2e6 * 1e18) / priceE18 + 1;
        // 4x the floor so every per-validator slot after the weight split clears the floor and seeds
        // an above-floor gather; delivery is then exact. Upper bound stays in u64-ish range.
        deposit = bound(deposit, 4 * floorAlpha, 1e15);

        _setAlphaPrice(NETUID1, priceE18);
        _depositAndWrap(alice, NETUID1, deposit);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 previewAlpha,) = vault.previewUnwrap(TOKEN1, shares);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));

        uint256 received = _userStakeAcrossHotkeys(alice, NETUID1);
        assertEq(received, previewAlpha, "delivery is exact - no shortfall above the floor");
    }

    function test_SetMinStakeTaoFloor_UpdatesValueAndEmits() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit MinStakeTaoFloorUpdated(2e6, 5e6);
        vault.setMinStakeTaoFloor(5e6);
        assertEq(vault.minStakeTaoFloor(), 5e6);
    }

    function test_RevertWhen_MinStakeTaoFloorAboveCap() public {
        vm.expectRevert(AlphaVault.MinStakeTaoFloorTooHigh.selector);
        vault.setMinStakeTaoFloor(100e6 + 1);
    }

    function test_SetMinStakeTaoFloor_AcceptsCapBoundary() public {
        vault.setMinStakeTaoFloor(100e6);
        assertEq(vault.minStakeTaoFloor(), 100e6);
    }

    // No lower clamp: the owner can follow the chain floor down (it has been as low as 5e5) and back
    // up past the old 16e6 cap (it has been as high as 20e6). Keeping the value at or above the
    // chain's live floor is an operational responsibility, not an on-chain invariant.
    function test_SetMinStakeTaoFloor_TracksChainFloorInBothDirections() public {
        vault.setMinStakeTaoFloor(5e5);
        assertEq(vault.minStakeTaoFloor(), 5e5, "can follow a chain-floor decrease below the deploy value");

        vault.setMinStakeTaoFloor(20e6);
        assertEq(vault.minStakeTaoFloor(), 20e6, "can follow a chain-floor increase past the old 16e6 cap");
    }

    // Within one price quantum of the floor the label cannot prove the chain will reject, so the
    // gather falls through bare and the chain's full-precision floor decides.
    function test_RevertWhen_GatherSeedWithinOneQuantumOfFloor() public {
        _setAlphaPrice(NETUID1, 1e9);
        _depositAndWrap(alice, NETUID1, 6e15);
        _setVaultStakes(NETUID1, 1_500_000_000_000_000, 1_500_000_000_000_000, 1_500_000_000_000_000);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vm.expectRevert(bytes("MockStaking: AmountTooLow"));
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));
    }

    function test_RevertWhen_NonOwnerSetsMinStakeTaoFloor() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setMinStakeTaoFloor(3e6);
    }

    function test_RevertWhen_WrapFlushFailsForNonFloorReason() public {
        _registerSubnet(99, hotkey4);
        _simulateAlphaDepositHotkey(alice, 99, 10e6, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setTransferStakeReverts(true);

        vm.prank(alice);
        vm.expectRevert(bytes("MockStaking: transferStake reverted"));
        vault.wrap(alice, 99, hotkey4);
    }
}
