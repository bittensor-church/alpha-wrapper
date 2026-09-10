// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { BackingUnchanged, NothingToRecover, ShortfallOnFile } from "src/VaultErrors.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { MockStaking } from "./mocks/MockStaking.sol";

contract RecoveryDeadlineTest is AlphaVaultTestBase {
    function _twoLosses() private returns (bytes32 firstTip, bytes32 secondTip, uint256 deadline) {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(2000, 6000, 2000));
        _depositAndWrap(alice, NETUID1, 40 ether);
        firstTip = _buildSwapTrail(NETUID1, hotkey1, 2);
        secondTip = _buildSwapTrail(NETUID1, hotkey2, 2);
        vault.syncBacking(TOKEN1);
        deadline = lens.frozenUntil(TOKEN1);
        assertEq(_parkedStake(NETUID1), 8 ether);
        assertEq(lens.missingStake(TOKEN1), 32 ether);
    }

    function test_LateSwap_CannotHideBackingSecuredBeforeTheDeadline() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 lost = _getVaultStake(hotkey1, NETUID1);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);
        uint256 deadline = lens.frozenUntil(TOKEN1);
        assertEq(_parkedStake(NETUID1), 30 ether - lost);
        assertEq(_getVaultStake(hotkey2, NETUID1), 0);

        vm.warp(deadline - 1);
        bytes32 lateTip = _buildSwapTrail(NETUID1, hotkey2, 2);
        assertEq(_getVaultStake(lateTip, NETUID1), 0, "the late swap cannot take the secured balance");
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
        assertEq(lens.frozenUntil(TOKEN1), deadline);

        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, 30 ether, 30 ether - lost);
        vault.syncBacking(TOKEN1);
        assertEq(_parkedStake(NETUID1), 30 ether - lost);
        assertEq(lens.frozenUntil(TOKEN1), 0);
    }

    function test_PartialRecovery_AcceptsTheLargerSourceFirstWithoutAttribution() public {
        (bytes32 firstTip, bytes32 secondTip, uint256 deadline) = _twoLosses();
        vm.warp(deadline - 1);
        vault.recoverStray(TOKEN1, _hotkeys(secondTip, secondTip));
        assertEq(_parkedStake(NETUID1), 32 ether, "duplicates cannot credit a source twice");
        assertEq(lens.missingStake(TOKEN1), 8 ether);
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 40 ether);
        assertEq(_getVaultStake(secondTip, NETUID1), 0);
        assertEq(lens.frozenUntil(TOKEN1), deadline, "partial recovery cannot extend the window");
        vm.expectRevert(ShortfallOnFile.selector);
        lens.totalStake(TOKEN1);
        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, _hotkeys(secondTip));

        vault.recoverStray(TOKEN1, _hotkeys(firstTip));
        assertEq(_parkedStake(NETUID1), 40 ether);
        assertEq(lens.missingStake(TOKEN1), 0);
        assertEq(lens.frozenUntil(TOKEN1), 0);
        assertEq(vault.recordedSlots(TOKEN1).length, 1);
        assertTrue(lens.awaitingAttestation(TOKEN1));
    }

    function test_ReturnedBalance_IsSecuredBeforeItsHotkeyCanSwapAgain() public {
        (bytes32 firstTip, bytes32 secondTip, uint256 deadline) = _twoLosses();
        vm.warp(deadline - 2);
        _simulateOffVaultSwap(NETUID1, firstTip, hotkey1);
        assertEq(lens.locatedStake(TOKEN1), 16 ether, "the returned balance is counted once");
        vault.syncBacking(TOKEN1);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(_parkedStake(NETUID1), 16 ether);
        assertEq(lens.frozenUntil(TOKEN1), deadline);

        vm.warp(deadline - 1);
        _simulateOffVaultSwap(NETUID1, hotkey1, firstTip);
        assertEq(_getVaultStake(firstTip, NETUID1), 0, "a repeated swap cannot remove recovered alpha");
        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, 40 ether, 16 ether);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 16 ether);
        vault.recoverStray(TOKEN1, _hotkeys(secondTip));
        assertEq(lens.totalStake(TOKEN1), 40 ether, "late recovery still belongs to current holders");
    }

    function test_ReturnAtExpiry_IsCollectedBeforeWriteOff() public {
        (bytes32 firstTip, bytes32 secondTip, uint256 deadline) = _twoLosses();
        _simulateOffVaultSwap(NETUID1, firstTip, hotkey1);
        _simulateOffVaultSwap(NETUID1, secondTip, hotkey2);
        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingShortfallCleared(TOKEN1);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 40 ether);
        assertEq(_parkedStake(NETUID1), 40 ether);
        assertEq(lens.frozenUntil(TOKEN1), 0);
    }

    function test_PartialRecoveryBeforeDeclaration_SecuresBackingAndStartsOneClock() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 secondLost = _getVaultStake(hotkey2, NETUID1);
        bytes32 tip = _buildSwapTrail(NETUID1, hotkey1, 2);
        _buildSwapTrail(NETUID1, hotkey2, 2);
        vault.recoverStray(TOKEN1, _hotkeys(tip));
        assertEq(_parkedStake(NETUID1), 30 ether - secondLost);
        assertEq(lens.missingStake(TOKEN1), secondLost);
        assertEq(_getVaultStake(tip, NETUID1), 0);
        assertEq(lens.frozenUntil(TOKEN1), block.timestamp + vault.recoveryWindow());
    }

    function test_FailedParking_LeavesTheRecordAndClockUntouched() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 expectedFirst = vault.recordedSlots(TOKEN1)[0].tracked;
        _buildSwapTrail(NETUID1, hotkey1, 2);
        uint256 located = _getVaultStake(hotkey2, NETUID1) + _getVaultStake(hotkey3, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeReverts(true);
        vm.expectRevert(bytes("MockStaking: moveStake reverted"));
        vault.syncBacking(TOKEN1);
        (uint64 since,) = vault.recovery(TOKEN1);
        assertEq(since, 0);
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, expectedFirst);
        assertEq(_parkedStake(NETUID1), 0);
        assertEq(_getVaultStake(hotkey2, NETUID1) + _getVaultStake(hotkey3, NETUID1), located);
        vm.warp(block.timestamp + 1 days);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeReverts(false);
        vault.syncBacking(TOKEN1);
        assertEq(lens.frozenUntil(TOKEN1), block.timestamp + vault.recoveryWindow());
    }

    function test_FailedCollectionAtExpiry_PreservesReturnedBackingAndTheObligation() public {
        (bytes32 firstTip,, uint256 deadline) = _twoLosses();
        _simulateOffVaultSwap(NETUID1, firstTip, hotkey1);
        vm.warp(deadline);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeReverts(true);
        vm.expectRevert(bytes("MockStaking: moveStake reverted"));
        vault.syncBacking(TOKEN1);
        assertEq(_parkedStake(NETUID1), 8 ether);
        assertEq(_getVaultStake(hotkey1, NETUID1), 8 ether);
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 40 ether);
        assertEq(lens.frozenUntil(TOKEN1), deadline);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeReverts(false);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 16 ether);
    }

    function test_PartialRecovery_CannotCreditAnotherColdkeysStake() public {
        (,, uint256 deadline) = _twoLosses();
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey5, _toSubstrate(bob), NETUID1, 100 ether);
        _simulateHotkeyOwnerPresent(hotkey5);
        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, _hotkeys(hotkey5));
        assertEq(_parkedStake(NETUID1), 8 ether);
        assertEq(lens.missingStake(TOKEN1), 32 ether);
        assertEq(lens.frozenUntil(TOKEN1), deadline);
        assertEq(_getStakeForColdkey(hotkey5, _toSubstrate(bob), NETUID1), 100 ether);
    }

    function test_PartialRecovery_CreditsActualParkingBalanceAfterRounding() public {
        (,, uint256 deadline) = _twoLosses();
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey5, _subnetColdkey(NETUID1), NETUID1, 1 ether);
        _simulateHotkeyOwnerPresent(hotkey5);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(5);
        vault.recoverStray(TOKEN1, _hotkeys(hotkey5));
        assertEq(_parkedStake(NETUID1), 9 ether - 10, "two roller moves each lose five alpha units");
        assertEq(lens.missingStake(TOKEN1), 31 ether + 10);
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 40 ether);
        assertEq(lens.frozenUntil(TOKEN1), deadline);
    }

    function testFuzz_PartialRecovery_IsIndependentOfSourceOrder(uint256 rawSplit, bool largerFirst) public {
        (bytes32 firstTip, bytes32 secondTip, uint256 deadline) = _twoLosses();
        uint256 split = bound(rawSplit, 1001, 32 ether - 1001);
        MockStaking staking = MockStaking(STAKING_PRECOMPILE);
        staking.setStake(firstTip, _subnetColdkey(NETUID1), NETUID1, split);
        staking.setStake(secondTip, _subnetColdkey(NETUID1), NETUID1, 32 ether - split);
        bytes32 first = largerFirst ? secondTip : firstTip;
        bytes32 second = largerFirst ? firstTip : secondTip;
        vault.recoverStray(TOKEN1, _hotkeys(first));
        assertEq(lens.missingStake(TOKEN1), largerFirst ? split : 32 ether - split);
        assertEq(lens.frozenUntil(TOKEN1), deadline);
        vault.recoverStray(TOKEN1, _hotkeys(second));
        assertEq(lens.totalStake(TOKEN1), 40 ether);
    }

    function testFuzz_Recovery_ParksEveryOtherSlotBeforeStartingTheClock(uint256 rawIndex) public {
        uint256 netuid = 9;
        _setRegBlock(netuid, 400);
        bytes32[] memory hotkeys = _setValidatorCount(netuid, 64);
        _simulateAlphaDepositHotkey(alice, netuid, 64 ether, hotkeys[0]);
        _wrapHotkey(alice, netuid, hotkeys[0]);
        uint256 tokenId = vault.currentTokenId(netuid);
        uint256 index = bound(rawIndex, 0, 63);
        uint256 lost = _getVaultStake(hotkeys[index], netuid);
        _buildSwapTrail(netuid, hotkeys[index], 2);
        vault.syncBacking(tokenId);
        assertEq(_parkedStake(netuid), 64 ether - lost);
        assertEq(lens.missingStake(tokenId), lost);
        for (uint256 i; i < hotkeys.length; ++i) {
            assertEq(_getVaultStake(hotkeys[i], netuid), 0);
        }
    }
}
