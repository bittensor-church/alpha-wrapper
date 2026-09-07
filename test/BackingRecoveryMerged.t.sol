// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Vm } from "forge-std/Test.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import { BackingShortfall, RecoveryIncomplete } from "src/VaultErrors.sol";
import { IStaking, STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { MockStaking } from "./mocks/MockStaking.sol";

contract BackingRecoveryMergedTest is AlphaVaultTestBase {
    uint256 private constant DEPOSIT = 200e9;

    function test_RecoverStray_MergedBackingReopensExitInOneMove() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, DEPOSIT);
        uint256 merged = _mergeFirstTwoSlots();
        vault.syncBacking(TOKEN1);
        vm.recordLogs();
        vm.expectCall(
            STAKING_PRECOMPILE, abi.encodeCall(IStaking.moveStake, (hotkey4, hotkey1, NETUID1, NETUID1, merged)), 1
        );

        vault.recoverStray(TOKEN1, hotkey4);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 writeOff = keccak256("BackingWrittenOff(uint256,bytes32,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].emitter != address(vault) || logs[i].topics[0] != writeOff, "no fictional write-off");
        }
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].tracked, merged);
        assertEq(slots[1].tracked, 0);
        assertEq(_totalTracked(), DEPOSIT);
        assertEq(_getVaultStake(hotkey4, NETUID1), 0);
        assertEq(lens.totalStake(TOKEN1), DEPOSIT);
        assertEq(lens.frozenUntil(TOKEN1), 0);
        uint256 before = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, DEPOSIT);
        assertEq(alice.balance - before, DEPOSIT);
        assertEq(vault.balanceOf(alice, TOKEN1), 0);
    }

    function test_RecoverStray_MergedEmissionsAreCountedOnceWithoutStartingClocks() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        uint256 merged = _mergeFirstTwoSlots();
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, _subnetColdkey(NETUID1), NETUID1, merged + 2e9);

        vault.recoverStray(TOKEN1, hotkey4);

        assertEq(_totalTracked(), DEPOSIT + 2e9);
        assertEq(lens.totalStake(TOKEN1), DEPOSIT + 2e9);
        assertEq(lens.frozenUntil(TOKEN1), 0);
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].tracked, merged + 2e9);
        assertEq(slots[1].tracked, 0);
        assertEq(slots[1].shortSince, 0);
    }

    function test_RecoverStray_PartialRepairsKeepTheOriginalWriteOffDeadline() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(4000, 3500, 2500));
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _mergeFirstTwoSlots();
        _simulateOffVaultSwap(NETUID1, hotkey3, hotkey4);
        // Split the found backing across two sources; the last 20 alpha remains unlocated.
        MockStaking mock = MockStaking(STAKING_PRECOMPILE);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        mock.setStake(hotkey4, coldkey, NETUID1, 100e9);
        mock.setStake(hotkey5, coldkey, NETUID1, 80e9);
        _simulateHotkeyOwnerPresent(hotkey5);
        vault.syncBacking(TOKEN1);
        uint256 started = vault.recordedSlots(TOKEN1)[2].shortSince;
        uint256 deadline = started + RECOVERY_WINDOW;

        vm.warp(started + 1 hours);
        vault.recoverStray(TOKEN1, hotkey4);
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[1].tracked, 50e9);
        assertEq(slots[1].shortSince, started);
        assertEq(slots[2].shortSince, started);

        vm.warp(started + 2 hours);
        vault.recoverStray(TOKEN1, hotkey5);
        slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[1].shortSince, 0);
        assertEq(slots[2].tracked, 20e9);
        assertEq(slots[2].shortSince, started);
        assertEq(_totalTracked(), DEPOSIT);
        assertEq(lens.frozenUntil(TOKEN1), deadline);
        vm.expectPartialRevert(BackingShortfall.selector);
        lens.totalStake(TOKEN1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.expectPartialRevert(BackingShortfall.selector);
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        vm.warp(deadline);
        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, hotkey3, 20e9, 0);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 180e9);
        assertEq(_totalTracked(), 180e9);
    }

    function test_RecoverStray_TinyChosenShortageDoesNotBlockLargeSources() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        uint256 first = _getVaultStake(hotkey1, NETUID1);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey5);
        _simulateOffVaultSwap(NETUID1, hotkey2, hotkey4);
        // A top-up leaves the largest recorded slot short by less than the transfer minimum.
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, first - 2_000);
        vault.syncBacking(TOKEN1);
        uint256 started = vault.recordedSlots(TOKEN1)[1].shortSince;

        vault.recoverStray(TOKEN1, hotkey4);
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[1].tracked, 2_000);
        assertEq(slots[1].shortSince, started);
        vault.recoverStray(TOKEN1, hotkey5);

        assertEq(lens.totalStake(TOKEN1), DEPOSIT + first - 2_000);
        assertEq(lens.frozenUntil(TOKEN1), 0);
        assertEq(_getVaultStake(hotkey4, NETUID1), 0);
        assertEq(_getVaultStake(hotkey5, NETUID1), 0);
    }

    function test_RecoverStray_TinySiblingShortageLeavesNoUnrecoverableResidual() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        uint256 first = _getVaultStake(hotkey1, NETUID1);
        uint256 second = _getVaultStake(hotkey2, NETUID1);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        MockStaking mock = MockStaking(STAKING_PRECOMPILE);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        mock.setStake(hotkey2, coldkey, NETUID1, second - 2_000);
        mock.setStake(hotkey4, coldkey, NETUID1, first + 2_000);
        vault.syncBacking(TOKEN1);

        vault.recoverStray(TOKEN1, hotkey4);

        assertEq(_getVaultStake(hotkey4, NETUID1), 0);
        assertEq(vault.recordedSlots(TOKEN1)[1].tracked, second - 2_000);
        assertEq(lens.totalStake(TOKEN1), DEPOSIT);
        assertEq(_totalTracked(), DEPOSIT);
        assertEq(lens.frozenUntil(TOKEN1), 0);
    }

    function test_RecoverStray_UsesObservedSurplusWithoutSpendingSlack() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _mergeFirstTwoSlots();
        vault.syncBacking(TOKEN1);
        uint256 started = vault.recordedSlots(TOKEN1)[1].shortSince;
        uint256 loss = BACKING_SLACK_RAO + 1;
        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(loss);

        vault.recoverStray(TOKEN1, hotkey4);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[1].tracked, loss);
        assertEq(slots[1].shortSince, started);
        assertEq(_totalTracked(), DEPOSIT);
        assertEq(lens.locatedStake(TOKEN1), DEPOSIT - loss);
        vm.expectPartialRevert(BackingShortfall.selector);
        lens.totalStake(TOKEN1);
    }

    function test_RecoverStray_SlackSizedRemainderClearsItsClock() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _mergeFirstTwoSlots();
        vault.syncBacking(TOKEN1);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(BACKING_SLACK_RAO);

        vault.recoverStray(TOKEN1, hotkey4);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[1].tracked, BACKING_SLACK_RAO);
        assertEq(slots[1].shortSince, 0);
        assertEq(_totalTracked(), DEPOSIT);
        assertEq(lens.totalStake(TOKEN1), DEPOSIT - BACKING_SLACK_RAO);
        assertEq(lens.frozenUntil(TOKEN1), 0);
    }

    function test_RecoverStray_InsufficientDestinationRevertsTheWholeMove() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        uint256 first = _getVaultStake(hotkey1, NETUID1);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        vault.syncBacking(TOKEN1);
        bytes32 before = keccak256(abi.encode(vault.recordedSlots(TOKEN1)));
        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(BACKING_SLACK_RAO + 1);

        vm.expectRevert(RecoveryIncomplete.selector);
        vault.recoverStray(TOKEN1, hotkey4);

        assertEq(keccak256(abi.encode(vault.recordedSlots(TOKEN1))), before);
        assertEq(_getVaultStake(hotkey4, NETUID1), first);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
    }

    function test_RecoverStray_ReservesCoveredSuccessorAfterSurplusRunsOut() public {
        // NETUID1 is fixed to 1 in the base fixture.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 netuid = uint16(NETUID1);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(3000, 1000, 6000));
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        bytes32 hidden = keccak256("hidden-recovery");
        _simulateOffVaultSwap(NETUID1, hotkey1, hidden);
        _simulateOffVaultSwap(NETUID1, hotkey3, hotkey4);
        vault.syncBacking(TOKEN1);
        uint256 started = vault.recordedSlots(TOKEN1)[0].shortSince;
        uint256 deadline = started + RECOVERY_WINDOW;
        // Both old keys name X, but its 20 alpha initially covers only slot B.
        _simulatePerSubnetSwap(NETUID1, hotkey2, hotkey5);
        MockStaking mock = MockStaking(STAKING_PRECOMPILE);
        mock.setHotkeySuccessor(hotkey1, NETUID1, hotkey5);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        mock.setStake(hidden, coldkey, NETUID1, 20e9);
        mock.setStake(hotkey4, coldkey, NETUID1, 160e9);
        VaultReads.Backing memory before = VaultReads.resolveBacking(vault.recordedSlots(TOKEN1), coldkey, netuid);
        assertTrue(before.short[0]);
        assertFalse(before.short[1]);
        assertEq(before.keys[1], hotkey5);
        assertEq(vault.recordedSlots(TOKEN1)[1].active, hotkey2, "the followed key is not persisted yet");

        vm.warp(deadline - 1);
        vault.recoverStray(TOKEN1, hotkey4);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].tracked, 20e9);
        assertEq(slots[0].shortSince, started);
        assertEq(slots[1].active, hotkey5, "persist even after slot A consumed all surplus");
        assertEq(slots[1].tracked, 20e9);
        assertEq(slots[1].shortSince, 0);
        VaultReads.Backing memory after_ = VaultReads.resolveBacking(slots, coldkey, netuid);
        assertTrue(after_.short[0], "the remaining shortage stays on its original slot");
        assertFalse(after_.short[1], "recovery must not make a covered slot short");
        assertEq(_totalTracked(), DEPOSIT);
        assertEq(lens.frozenUntil(TOKEN1), deadline);

        vm.warp(deadline);
        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, hotkey1, 20e9, 0);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 180e9);
        vault.recoverStray(TOKEN1, hidden);
        assertEq(lens.totalStake(TOKEN1), DEPOSIT);
    }

    function _mergeFirstTwoSlots() private returns (uint256) {
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _simulateOffVaultSwap(NETUID1, hotkey2, hotkey4);
        return _getVaultStake(hotkey4, NETUID1);
    }

    function _totalTracked() private view returns (uint256 total) {
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            total += slots[i].tracked;
        }
    }
}
