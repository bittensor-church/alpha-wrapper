// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { NothingToRecover } from "src/VaultErrors.sol";
import { MockStaking, CHAIN_MIN_STAKE } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract RecoverySourceTest is AlphaVaultTestBase {
    function _twoMissing() private returns (bytes32 first, bytes32 second, uint256 deadline) {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(2000, 6000, 2000));
        _depositAndWrap(alice, NETUID1, 40 ether);
        first = _buildSwapTrail(NETUID1, hotkey1, 2);
        second = _buildSwapTrail(NETUID1, hotkey2, 2);
        vault.syncBacking(TOKEN1);
        deadline = lens.frozenUntil(TOKEN1);
    }

    function test_FinalSync_CollectsKnownReturnsEvenWhenParkingAlreadyCoversTheObligation() public {
        (bytes32 first, bytes32 second, uint256 deadline) = _twoMissing();
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
        (bytes32 first,, uint256 deadline) = _twoMissing();
        _simulateOffVaultSwap(NETUID1, first, hotkey1);
        vault.recoverStray(TOKEN1, hotkey1);
        assertEq(_parkedStake(NETUID1), 16 ether);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(lens.missingStake(TOKEN1), 24 ether);
        assertEq(lens.frozenUntil(TOKEN1), deadline);
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 40 ether);
    }

    function test_RecoverStray_AfterExpiryStillLetsSyncClearFullCoverage() public {
        (bytes32 first, bytes32 second, uint256 deadline) = _twoMissing();
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
        (,, uint256 deadline) = _twoMissing();
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
}
