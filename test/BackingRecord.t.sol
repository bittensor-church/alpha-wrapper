// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { VaultMath } from "src/libraries/VaultMath.sol";
import { MAX_VALIDATORS } from "src/ValidatorRegistry.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import { AttestedHotkeyRetired, SwappedHotkeyStillAttested, ZeroAmount } from "src/VaultErrors.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract BackingRecordTest is AlphaVaultTestBase {
    function test_Wrap_RecordsWhereEachValidatorsAlphaIs() public {
        _depositAndWrap(alice, NETUID1, 30 ether);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots.length, 3, "one slot per attested validator");
        assertEq(slots[0].logical, hotkey1, "the slot names the attested validator");
        assertEq(slots[0].active, hotkey1, "with nothing swapped the two agree");
        assertEq(slots[0].tracked, _getVaultStake(hotkey1, NETUID1), "the expectation mirrors the staked alpha");
        assertEq(lens.frozenUntil(TOKEN1), 0, "and no clock is running");
    }

    function test_IntactSlot_NeverReadsASuccessor() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey5);

        vault.rebalance(NETUID1);

        assertTrue(lens.isBackingIntact(TOKEN1), "the slot answered from its own balance");
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey1, "and nothing moved the record");
    }

    function test_DirectSwap_MovesActiveAndLeavesLogicalAlone() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "the quote resolves the swap before any write");
        vault.rebalance(NETUID1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].logical, hotkey1, "the registry still names the original validator");
        assertEq(slots[0].active, hotkey4, "the alpha is tracked at the successor");
        assertEq(lens.totalStake(TOKEN1), 30 ether, "backing whole across the swap");
    }

    function test_RepeatedSwaps_AdvanceOneHopPerCall() public {
        uint256 netuid = 5;
        _registerSubnet(netuid, hotkey1);
        _depositAndWrap(alice, netuid, 10 ether);
        uint256 tokenId = vault.currentTokenId(netuid);

        _simulateFollowedSwap(netuid, hotkey1, hotkey4);
        vault.rebalance(netuid);

        _simulateFollowedSwap(netuid, hotkey4, hotkey5);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);

        assertTrue(lens.isBackingIntact(tokenId), "the quote reads the position as sound");
        vault.rebalance(netuid);

        VaultReads.Slot[] memory slots = vault.recordedSlots(tokenId);
        assertEq(slots[0].logical, hotkey1, "the registry has not moved");
        assertEq(slots[0].active, hotkey5, "the alpha is tracked at the live key");
        assertEq(lens.lastSeenHotkeys(tokenId)[0], hotkey5, "the lens reports the same key");
        assertEq(lens.totalStake(tokenId), 10 ether, "backing whole across both swaps");
    }

    function test_SwappedValidator_AllRailsKeepWorking() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 shares = _depositAndWrap(bob, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        _simulateAlphaDepositHotkey(alice, NETUID1, 10 ether, hotkey4);
        vm.expectRevert(ZeroAmount.selector);
        _wrapHotkey(alice, NETUID1, hotkey1);
        vm.prank(alice);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey4, _toSubstrate(alice));
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 ether, hotkey2);
        _wrapHotkey(alice, NETUID1, hotkey2);
        vm.prank(bob);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(bob), 0);
        vm.prank(bob);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing staked toward the retired key");
        assertTrue(lens.isBackingIntact(TOKEN1), "record sound throughout");
    }

    function test_ReorderedSet_KeepsWeightsWithTheirValidators() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        // Per-subnet swapping retains the old owner, allowing the reordered attestation.
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        _setValidators(NETUID1, _hotkeys(hotkey3, hotkey1, hotkey2), _weights(5000, 3000, 2000));
        vault.rebalance(NETUID1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].logical, hotkey3, "slot order follows the attested set");
        assertEq(slots[1].logical, hotkey1, "the swapped validator kept its own weight slot");
        assertEq(slots[1].active, hotkey4, "and its alpha is still tracked at the successor");
        assertEq(lens.totalStake(TOKEN1), 30 ether, "nothing lost in the reorder");
    }

    function test_DroppedValidator_HasItsAlphaRolledOntoTheNewSet() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        _setValidators(NETUID1, _hotkeys(hotkey2, hotkey3), _weights(5000, 5000));
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "the successor was drained");
        assertEq(vault.recordedSlots(TOKEN1).length, 2, "the record matches the new set");
        assertEq(lens.totalStake(TOKEN1), 30 ether, "backing whole after the roll");
    }

    function test_SetNamingTheSuccessor_CountsTheBalanceOnce() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vault.rebalance(NETUID1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].logical, hotkey4, "the attested name took over the slot");
        assertEq(slots[0].active, hotkey4, "answering for its own key");
        assertEq(lens.totalStake(TOKEN1), 30 ether, "and nothing is counted twice");
    }

    function test_SetNamingASwappedKeyAndItsSuccessor_RefusesCheaply() public {
        _setAlphaPrice(NETUID1, 1e18);
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        // Install the set before the swap removes ownership; ownerless entries cannot be newly attested.
        _setValidators(
            NETUID1, _hotkeys(hotkey1, hotkey4, hotkey2), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        vm.expectRevert(SwappedHotkeyStillAttested.selector);
        vault.rebalance(NETUID1);
        vm.expectRevert(SwappedHotkeyStillAttested.selector);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);

        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vault.rebalance(NETUID1);
        assertTrue(lens.isBackingIntact(TOKEN1), "dropping the stale name resumes service");
    }

    function _positionWithADrainedSwap() private {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        _drainTheFirstSlot(alice, NETUID1);
    }

    function test_RebalanceAfterADrainedSwap_StakesTheShareAtTheSuccessor() public {
        _positionWithADrainedSwap();

        vault.rebalance(NETUID1);

        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey4, "the slot answers under the successor");
        assertGt(_getVaultStake(hotkey4, NETUID1), 0, "which is where its share went");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "and nothing was aimed at the retired name");
    }

    function test_UnwrapAfterADrainedSwap_StakesTheShareAtTheSuccessor() public {
        _positionWithADrainedSwap();

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey4, "the slot answers under the successor");
        assertGt(_getVaultStake(hotkey4, NETUID1), 0, "which is where its share went");
        assertGt(_userStakeAcrossHotkeys(alice, NETUID1), 0, "and the exit delivered");
        assertTrue(lens.isBackingIntact(TOKEN1), "with the record accounting for what is left");
    }

    function test_WrapAfterADrainedSwap_StakesTheShareAtTheSuccessor() public {
        _positionWithADrainedSwap();

        _simulateAlphaDepositHotkey(bob, NETUID1, 6 ether, hotkey2);
        _wrapHotkey(bob, NETUID1, hotkey2);

        assertGt(vault.balanceOf(bob, TOKEN1), 0, "the deposit landed");
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey4, "the slot answers under the successor");
        assertGt(_getVaultStake(hotkey4, NETUID1), 0, "which is where its share went");
    }

    function test_ValidatorSwappingBeforeItIsFunded_StakesItsShareAtTheSuccessor() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey5);

        vault.rebalance(NETUID1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[2].logical, hotkey4, "the record names the attested validator");
        assertEq(slots[2].active, hotkey5, "while its share sits at the successor");
        assertGt(_getVaultStake(hotkey5, NETUID1), 0, "which is where the rebalance staked it");
        assertEq(lens.totalStake(TOKEN1), 30 ether, "backing whole across the swap");
    }

    function test_PerSubnetSwapAfterADrain_StakesTheShareAtTheAttestedName() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        _drainTheFirstSlot(alice, NETUID1);

        vault.rebalance(NETUID1);

        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey1, "the slot answers under its own name again");
        assertGt(_getVaultStake(hotkey1, NETUID1), 0, "which is where its share went");
    }

    function test_RetiredNameWithNoSuccessor_RefusesEveryAlphaRail() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        vault.rebalance(NETUID1);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        _simulateAlphaDepositHotkey(bob, NETUID1, 6 ether, hotkey2);
        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        _wrapHotkey(bob, NETUID1, hotkey2);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);
    }

    function test_RetiredNameWithARetiredSuccessor_RefusesTheRebalance() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey5);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey5, true);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        vault.rebalance(NETUID1);
    }

    function _positionWithTwoFollowedSwapsThenADrain() private {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey5);
        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey5, "the record followed both swaps");
        _drainTheFirstSlot(alice, NETUID1);
    }

    /// @dev The logical name's edge still points to the first successor, not the latest recorded key.
    function test_RebalanceAfterTwoFollowedSwapsAndADrain_StakesTheShareAtTheRecordedKey() public {
        _positionWithTwoFollowedSwapsThenADrain();

        vault.rebalance(NETUID1);

        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey5, "the slot stays on the key it was found under");
        assertGt(_getVaultStake(hotkey5, NETUID1), 0, "which is where its share went");
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "and nothing was aimed at the retired successor");
        assertTrue(lens.isBackingIntact(TOKEN1), "with the record accounting for everything");
    }

    function test_UnwrapAfterTwoFollowedSwapsAndADrain_StakesTheShareAtTheRecordedKey() public {
        _positionWithTwoFollowedSwapsThenADrain();

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey5, "the slot stays on the key it was found under");
        assertGt(_getVaultStake(hotkey5, NETUID1), 0, "which is where its share went");
        assertGt(_userStakeAcrossHotkeys(alice, NETUID1), 0, "and the exit delivered");
        assertTrue(lens.isBackingIntact(TOKEN1), "with the record accounting for what is left");
    }

    function test_FullUnwrapBesideARetiredEntry_PaysFromTheHeldKeys() public {
        _setValidators(NETUID1, _hotkeys(hotkey2), _weights(VaultMath.BPS_BASE));
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _setValidators(NETUID1, _hotkeys(hotkey4, hotkey2), _weights(5000, 5000));
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey5);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey5, true);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(vault.balanceOf(alice, TOKEN1), 0, "the whole position was burned");
        assertApproxEqAbs(_userStakeAcrossHotkeys(alice, NETUID1), 30 ether, 1e12, "and paid out as staked alpha");
        assertEq(_getVaultStake(hotkey2, NETUID1), 0, "leaving nothing behind");
    }

    function test_FullUnwrapRollingStakeOntoARetiredEntry_Refuses() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _setValidators(NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(3334, 3333, 3333));
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);
        assertEq(vault.balanceOf(alice, TOKEN1), 0, "the TAO exit stays open");
    }

    function test_SetNamingADrainedSwapAndItsSuccessor_StillRefuses() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey4, hotkey2), _weights(3334, 3333, 3333));
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);
        _drainTheFirstSlot(alice, NETUID1);

        vm.expectRevert(SwappedHotkeyStillAttested.selector);
        vault.rebalance(NETUID1);
    }

    function test_SetNamingADrainedSwapBesideItsLiveName_StillRefuses() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey4, hotkey2), _weights(3334, 3333, 3333));
        _drainTheFirstSlot(alice, NETUID1);

        vm.expectRevert(SwappedHotkeyStillAttested.selector);
        vault.rebalance(NETUID1);

        _setValidators(NETUID1, _hotkeys(hotkey4, hotkey2), _weights(5000, 5000));
        vault.rebalance(NETUID1);
        assertTrue(lens.isBackingIntact(TOKEN1), "dropping the old name resumes service");
    }

    function testFuzz_DrainedSwap_LeavesEverySlotOnItsOwnKey(uint256 rawCount) public {
        uint256 count = bound(rawCount, 2, 8);
        uint256 netuid = 11;
        _setRegBlock(netuid, 500);
        bytes32[] memory hks = _setValidatorCount(netuid, count);
        _simulateAlphaDepositHotkey(alice, netuid, 30 ether, hks[0]);
        _wrapHotkey(alice, netuid, hks[0]);
        uint256 tokenId = vault.currentTokenId(netuid);

        bytes32 successor = keccak256("drained-swap-successor");
        _simulateFollowedSwap(netuid, hks[0], successor);
        vault.rebalance(netuid);
        _drainTheFirstSlot(alice, netuid);

        vault.rebalance(netuid);

        VaultReads.Slot[] memory slots = vault.recordedSlots(tokenId);
        for (uint256 i; i < slots.length; ++i) {
            for (uint256 j = i + 1; j < slots.length; ++j) {
                assertTrue(slots[i].active != slots[j].active, "no two slots answer for one key");
            }
        }
        uint256 underTheRecord = _vaultStakeAcross(_lastSeen(tokenId), netuid);
        assertEq(underTheRecord, lens.totalStake(tokenId), "the record's keys hold the whole position");
        assertEq(
            underTheRecord,
            _vaultStakeAcross(hks, netuid) + _getVaultStake(successor, netuid),
            "and nothing of it was left outside them"
        );
    }

    function test_Emissions_DoNotTrip() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateEmissions(NETUID1, 5 ether);
        vault.rebalance(NETUID1);
        assertGt(lens.totalStake(TOKEN1), 30 ether, "emission counted, no false trip");
    }

    function test_OperationSequence_NeverTrips() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 60 ether);
        vault.rebalance(NETUID1);
        _depositAndWrap(bob, NETUID1, 25 ether);
        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares / 3, _toSubstrate(alice), 0);
        vault.rebalance(NETUID1);
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, aliceShares / 3, 0);
        vault.rebalance(NETUID1);

        assertTrue(lens.isBackingIntact(TOKEN1), "the record settled through the whole sequence");
    }

    function test_Withdrawal_ReanchorsTheRecord() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            assertEq(slots[i].tracked, _getVaultStake(slots[i].active, NETUID1), "expectation matches the ledger");
        }
    }

    function test_SwapAfterWithdrawal_IsStillFollowed() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);

        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "an ordinary swap after an exit is still followable");
        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey4, "the record moved to the successor");
    }

    function test_SwapAfterTaoExit_StaysOperable() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);
        uint256 backingAfterExit = lens.totalStake(TOKEN1);

        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "the TAO rail leaves a record the swap cannot trip");
        vault.rebalance(NETUID1);
        assertEq(lens.totalStake(TOKEN1), backingAfterExit, "backing whole across the swap");
    }

    function test_MoveRounding_DoesNotTrip() public {
        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(100);
        _depositAndWrap(alice, NETUID1, 30 ether);
        vault.rebalance(NETUID1);
        vault.rebalance(NETUID1);
        assertTrue(lens.isBackingIntact(TOKEN1), "rounding stays inside the slack");
    }

    function testFuzz_WideSet_FollowsASwap(uint256 rawCount) public {
        uint256 count = bound(rawCount, 2, MAX_VALIDATORS);
        uint256 netuid = 9;
        _setRegBlock(netuid, 400);
        bytes32[] memory hks = _setValidatorCount(netuid, count);

        _simulateAlphaDepositHotkey(alice, netuid, MAX_VALIDATORS * 1 ether, hks[0]);
        _wrapHotkey(alice, netuid, hks[0]);
        uint256 tokenId = vault.currentTokenId(netuid);

        bytes32 swapped = keccak256("wide-set-successor");
        _simulateFollowedSwap(netuid, hks[0], swapped);
        vault.rebalance(netuid);

        assertEq(lens.totalStake(tokenId), MAX_VALIDATORS * 1 ether, "backing whole across the wide set");
        assertTrue(lens.isBackingIntact(tokenId), "record sound after the follow");
    }
}
