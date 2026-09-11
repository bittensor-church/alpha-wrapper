// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { VaultMath } from "src/libraries/VaultMath.sol";
import { MAX_VALIDATORS } from "src/ValidatorRegistry.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { BackingNotSecured, BackingUnchanged, NothingToRecover, ShortfallOnFile } from "src/VaultErrors.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { MockStaking, CHAIN_MIN_STAKE } from "./mocks/MockStaking.sol";

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
        vault.recoverStray(TOKEN1, secondTip);
        assertEq(_parkedStake(NETUID1), 32 ether, "the larger source is credited without attribution");
        assertEq(lens.missingStake(TOKEN1), 8 ether);
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 40 ether);
        assertEq(_getVaultStake(secondTip, NETUID1), 0);
        assertEq(lens.frozenUntil(TOKEN1), deadline, "partial recovery cannot extend the window");
        vm.expectRevert(ShortfallOnFile.selector);
        lens.totalStake(TOKEN1);
        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, secondTip);

        vault.recoverStray(TOKEN1, firstTip);
        assertEq(_parkedStake(NETUID1), 40 ether);
        assertEq(lens.missingStake(TOKEN1), 0);
        assertEq(lens.frozenUntil(TOKEN1), deadline, "only sync finalizes recovery");
        assertFalse(lens.isBackingIntact(TOKEN1));
        vault.syncBacking(TOKEN1);
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
        vault.recoverStray(TOKEN1, secondTip);
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

    function test_PartialRecoveryAfterSync_PreservesItsClock() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 secondLost = _getVaultStake(hotkey2, NETUID1);
        bytes32 tip = _buildSwapTrail(NETUID1, hotkey1, 2);
        _buildSwapTrail(NETUID1, hotkey2, 2);
        vault.syncBacking(TOKEN1);
        vault.recoverStray(TOKEN1, tip);
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
        vault.recoverStray(TOKEN1, hotkey5);
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
        vault.recoverStray(TOKEN1, hotkey5);
        assertEq(_parkedStake(NETUID1), 9 ether - 10, "two roller moves each lose five alpha units");
        assertEq(lens.missingStake(TOKEN1), 31 ether + 10);
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 40 ether);
        assertEq(lens.frozenUntil(TOKEN1), deadline);
    }

    function testFuzz_PartialRecovery_IsIndependentOfSourceOrder(uint256 rawSplit, bool secondSourceFirst) public {
        (bytes32 firstTip, bytes32 secondTip, uint256 deadline) = _twoLosses();
        uint256 minShortfall = BACKING_SLACK_RAO + 1;
        uint256 split = bound(rawSplit, minShortfall, 32 ether - minShortfall);
        MockStaking staking = MockStaking(STAKING_PRECOMPILE);
        staking.setStake(firstTip, _subnetColdkey(NETUID1), NETUID1, split);
        staking.setStake(secondTip, _subnetColdkey(NETUID1), NETUID1, 32 ether - split);
        bytes32 first = secondSourceFirst ? secondTip : firstTip;
        bytes32 second = secondSourceFirst ? firstTip : secondTip;
        vault.recoverStray(TOKEN1, first);
        assertEq(lens.missingStake(TOKEN1), secondSourceFirst ? split : 32 ether - split);
        assertEq(lens.frozenUntil(TOKEN1), deadline);
        vault.recoverStray(TOKEN1, second);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 40 ether);
    }

    function testFuzz_Recovery_ParksEveryOtherSlotBeforeStartingTheClock(uint256 rawIndex) public {
        uint256 netuid = 9;
        _setRegBlock(netuid, 400);
        bytes32[] memory hotkeys = _setValidatorCount(netuid, MAX_VALIDATORS);
        _simulateAlphaDepositHotkey(alice, netuid, MAX_VALIDATORS * 1 ether, hotkeys[0]);
        _wrapHotkey(alice, netuid, hotkeys[0]);
        uint256 tokenId = vault.currentTokenId(netuid);
        uint256 index = bound(rawIndex, 0, MAX_VALIDATORS - 1);
        uint256 lost = _getVaultStake(hotkeys[index], netuid);
        _buildSwapTrail(netuid, hotkeys[index], 2);
        vault.syncBacking(tokenId);
        assertEq(_parkedStake(netuid), MAX_VALIDATORS * 1 ether - lost);
        assertEq(lens.missingStake(tokenId), lost);
        for (uint256 i; i < hotkeys.length; ++i) {
            assertEq(_getVaultStake(hotkeys[i], netuid), 0);
        }
    }

    function test_FinalSync_CollectsKnownReturnsEvenWhenParkingAlreadyCoversTheObligation() public {
        (bytes32 first, bytes32 second, uint256 deadline) = _twoLosses();
        _simulateOffVaultSwap(NETUID1, first, hotkey1);
        MockStaking(STAKING_PRECOMPILE).setStake(second, _subnetColdkey(NETUID1), NETUID1, 32 ether);
        bytes32 record = keccak256(abi.encode(vault.recordedSlots(TOKEN1)));

        vault.recoverStray(TOKEN1, second);
        assertEq(_parkedStake(NETUID1), 40 ether);
        assertEq(_getVaultStake(hotkey1, NETUID1), 8 ether, "only the supplied source moved");
        assertEq(keccak256(abi.encode(vault.recordedSlots(TOKEN1))), record);
        assertEq(lens.frozenUntil(TOKEN1), deadline);
        assertFalse(lens.isBackingIntact(TOKEN1), "sync must finalize the record");

        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 48 ether, "no returned backing was dropped at completion");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(vault.recordedSlots(TOKEN1).length, 1);
        assertEq(lens.frozenUntil(TOKEN1), 0);
        assertTrue(lens.awaitingAttestation(TOKEN1));
    }

    function test_RecoverStray_AcceptsAReturnAtAKnownCollectionKey() public {
        (bytes32 first,, uint256 deadline) = _twoLosses();
        _simulateOffVaultSwap(NETUID1, first, hotkey1);
        vault.recoverStray(TOKEN1, hotkey1);
        assertEq(_parkedStake(NETUID1), 16 ether);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(lens.missingStake(TOKEN1), 24 ether);
        assertEq(lens.frozenUntil(TOKEN1), deadline);
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 40 ether);
    }

    function test_RecoverStray_AfterExpiryStillLetsSyncClearFullCoverage() public {
        (bytes32 first, bytes32 second, uint256 deadline) = _twoLosses();
        vm.warp(deadline);
        vault.recoverStray(TOKEN1, first);
        vault.recoverStray(TOKEN1, second);
        assertEq(lens.frozenUntil(TOKEN1), deadline);
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 40 ether);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingShortfallCleared(TOKEN1);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 40 ether);
        assertEq(lens.frozenUntil(TOKEN1), 0);
    }

    function test_RecoverStray_RejectsZeroAndParkingWithoutChangingRecovery() public {
        (,, uint256 deadline) = _twoLosses();
        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, bytes32(0));
        bytes32 parking = vault.parkingHotkey();
        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, parking);
        assertEq(_parkedStake(NETUID1), 8 ether);
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 40 ether);
        assertEq(lens.frozenUntil(TOKEN1), deadline);
    }

    function test_RecoverStray_CanAnnexUntrackedParkingStakeToLiveBacking() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 parking = vault.parkingHotkey();
        MockStaking(STAKING_PRECOMPILE).setStake(parking, _subnetColdkey(NETUID1), NETUID1, 3 ether);
        vault.recoverStray(TOKEN1, parking);
        assertEq(lens.totalStake(TOKEN1), 33 ether);
        assertEq(_parkedStake(NETUID1), 0);
        assertEq(lens.frozenUntil(TOKEN1), 0);
        assertFalse(lens.awaitingAttestation(TOKEN1));
    }

    function test_MovableSourceFirst_EnablesNineSeparateDustRecoveries() public {
        uint256 expected = 30 * CHAIN_MIN_STAKE;
        uint256 dust = CHAIN_MIN_STAKE / 2;
        uint256 dustSources = 9;
        _depositAndWrap(alice, NETUID1, expected);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        _buildSwapTrail(NETUID1, hotkey2, 2);
        _buildSwapTrail(NETUID1, hotkey3, 2);
        vault.syncBacking(TOKEN1);
        uint256 deadline = lens.frozenUntil(TOKEN1);
        MockStaking staking = MockStaking(STAKING_PRECOMPILE);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        for (uint256 i; i < dustSources; ++i) {
            bytes32 source = keccak256(abi.encode("dust source", i));
            _simulateHotkeyOwnerPresent(source);
            staking.setStake(source, coldkey, NETUID1, dust);
            vm.expectRevert(NothingToRecover.selector);
            vault.recoverStray(TOKEN1, source);
            assertEq(_getVaultStake(source, NETUID1), dust);
        }
        _simulateHotkeyOwnerPresent(hotkey4);
        staking.setStake(hotkey4, coldkey, NETUID1, CHAIN_MIN_STAKE);
        vault.recoverStray(TOKEN1, hotkey4);
        for (uint256 i; i < dustSources; ++i) {
            bytes32 source = keccak256(abi.encode("dust source", i));
            vault.recoverStray(TOKEN1, source);
            assertEq(_getVaultStake(source, NETUID1), 0);
        }
        uint256 collected = CHAIN_MIN_STAKE + dustSources * dust;
        assertEq(_parkedStake(NETUID1), collected);
        assertEq(lens.missingStake(TOKEN1), expected - collected);
        assertEq(lens.frozenUntil(TOKEN1), deadline);
        vm.warp(deadline);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), collected, "all ten collected balances survive write-off");
    }

    function test_IncompleteParking_CannotStartTheClockAndCanBeRetried() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 lost = _getVaultStake(hotkey1, NETUID1);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        bytes32 record = keccak256(abi.encode(vault.recordedSlots(TOKEN1)));
        uint256 second = _getVaultStake(hotkey2, NETUID1);
        uint256 third = _getVaultStake(hotkey3, NETUID1);
        MockStaking staking = MockStaking(STAKING_PRECOMPILE);
        staking.setMoveStakeResidual(BACKING_SLACK_RAO + 1);
        vm.expectRevert(BackingNotSecured.selector);
        vault.syncBacking(TOKEN1);
        (uint64 since,) = vault.recovery(TOKEN1);
        assertEq(since, 0);
        assertEq(keccak256(abi.encode(vault.recordedSlots(TOKEN1))), record);
        assertEq(_parkedStake(NETUID1), 0);
        assertEq(_getVaultStake(hotkey2, NETUID1), second);
        assertEq(_getVaultStake(hotkey3, NETUID1), third);

        staking.setMoveStakeResidual(0);
        vault.syncBacking(TOKEN1);
        assertEq(_parkedStake(NETUID1), 30 ether - lost);
        assertEq(lens.missingStake(TOKEN1), lost);
        assertEq(lens.frozenUntil(TOKEN1), block.timestamp + vault.recoveryWindow());
    }

    function test_IncompleteCollectionAtExpiry_CannotWriteOffLocatedBackingAndCanBeRetried() public {
        (bytes32 first,, uint256 deadline) = _twoLosses();
        _simulateOffVaultSwap(NETUID1, first, hotkey1);
        bytes32 record = keccak256(abi.encode(vault.recordedSlots(TOKEN1)));
        vm.warp(deadline);
        MockStaking staking = MockStaking(STAKING_PRECOMPILE);
        staking.setMoveStakeResidual(BACKING_SLACK_RAO + 1);
        vm.expectRevert(BackingNotSecured.selector);
        vault.syncBacking(TOKEN1);
        assertEq(keccak256(abi.encode(vault.recordedSlots(TOKEN1))), record);
        assertEq(lens.frozenUntil(TOKEN1), deadline);
        assertEq(_parkedStake(NETUID1), 8 ether);
        assertEq(_getVaultStake(hotkey1, NETUID1), 8 ether);

        staking.setMoveStakeResidual(0);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 16 ether);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(lens.frozenUntil(TOKEN1), 0);
    }

    function testFuzz_Declaration_ParksTheComplementOfAnyNonemptyLostSubset(uint256 rawCount, uint256 rawMask) public {
        uint256 netuid = 9;
        _setRegBlock(netuid, 400);
        uint256 count = bound(rawCount, 1, MAX_VALIDATORS);
        bytes32[] memory keys = _setValidatorCount(netuid, count);
        uint256 expected = count * 1 ether;
        _simulateAlphaDepositHotkey(alice, netuid, expected, keys[0]);
        _wrapHotkey(alice, netuid, keys[0]);
        uint256 tokenId = vault.currentTokenId(netuid);
        uint256 lostMask = bound(rawMask, 1, (uint256(1) << count) - 1);
        uint256 lost;
        for (uint256 i; i < count; ++i) {
            if (lostMask & (uint256(1) << i) != 0) {
                lost += _getVaultStake(keys[i], netuid);
                _buildSwapTrail(netuid, keys[i], 2);
            }
        }
        vault.syncBacking(tokenId);
        assertEq(_parkedStake(netuid), expected - lost);
        assertEq(lens.missingStake(tokenId), lost);
        assertEq(vault.recordedSlots(tokenId)[0].tracked, expected);
        assertEq(vault.recordedSlots(tokenId).length, count + 1, "no duplicate or empty collection entries");
        for (uint256 i; i < count; ++i) {
            assertEq(_getVaultStake(keys[i], netuid), 0);
        }

        vm.warp(lens.frozenUntil(tokenId));
        vault.syncBacking(tokenId);
        assertEq(lens.totalStake(tokenId), expected - lost, "expiry preserves every located balance");
        assertEq(lens.frozenUntil(tokenId), 0);
    }

    function testFuzz_MergedSlots_FinalizeAtDeclarationForAnySplit(uint256 rawWeight) public {
        uint16 firstWeight = uint16(bound(rawWeight, 1, VaultMath.BPS_BASE - 1));
        bytes32[] memory keys = new bytes32[](2);
        keys[0] = hotkey1;
        keys[1] = hotkey2;
        uint16[] memory weights = new uint16[](2);
        weights[0] = firstWeight;
        weights[1] = uint16(VaultMath.BPS_BASE) - firstWeight;
        _setValidators(NETUID1, keys, weights);
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _simulateOffVaultSwap(NETUID1, hotkey2, hotkey4);
        MockStaking staking = MockStaking(STAKING_PRECOMPILE);
        staking.setHotkeySuccessor(hotkey1, NETUID1, hotkey4);
        staking.setHotkeySuccessor(hotkey2, NETUID1, hotkey4);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 30 ether);
        assertEq(_parkedStake(NETUID1), 30 ether);
        assertEq(lens.missingStake(TOKEN1), 0);
        assertEq(lens.frozenUntil(TOKEN1), 0);
        assertEq(vault.recordedSlots(TOKEN1).length, 1);
        assertTrue(lens.awaitingAttestation(TOKEN1));
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(_getVaultStake(hotkey2, NETUID1), 0);
        assertEq(_getVaultStake(hotkey4, NETUID1), 0);
    }
}
