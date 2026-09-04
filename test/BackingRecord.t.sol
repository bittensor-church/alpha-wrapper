// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import { AttestedHotkeyRetired, SwappedHotkeyStillAttested, ZeroAmount } from "src/VaultErrors.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// @dev Covers the record itself as the world moves around it: the one hotkey swap it resolves on
///      its own, attested sets that reorder, grow and shrink, and the ordinary operations that must
///      never read as a loss.
contract BackingRecordTest is AlphaVaultTestBase {
    // -------------------- What the record remembers ------------------------------

    function test_Wrap_RecordsWhereEachValidatorsAlphaIs() public {
        _depositAndWrap(alice, NETUID1, 30 ether);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots.length, 3, "one slot per attested validator");
        assertEq(slots[0].logical, hotkey1, "the slot names the attested validator");
        assertEq(slots[0].active, hotkey1, "with nothing swapped the two agree");
        assertEq(slots[0].tracked, _getVaultStake(hotkey1, NETUID1), "the expectation mirrors the staked alpha");
        assertEq(slots[0].shortSince, 0, "and no clock is running");
    }

    /// @dev An intact slot is settled on its own balance, with no successor edge consulted at all.
    function test_IntactSlot_NeverReadsASuccessor() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        // An edge pointing at a key holding nothing: read, it would resolve to a shortfall.
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
        assertApproxEqAbs(lens.totalStake(TOKEN1), 30 ether, 0.01 ether, "backing whole across the swap");
    }

    /// @dev The record standing a hop ahead of the registry is the ordinary state after a swap, and
    ///      a second one must move it forward again rather than back to the key in between.
    function test_RepeatedSwaps_AdvanceOneHopPerCall() public {
        uint256 netuid = 5;
        _registerSubnet(netuid, hotkey1);
        _depositAndWrap(alice, netuid, 10 ether);
        uint256 tokenId = vault.currentTokenId(netuid);

        _simulateFollowedSwap(netuid, hotkey1, hotkey4);
        vault.rebalance(netuid);

        // The middle key is retired by the second swap, exactly as a global swap leaves it.
        _simulateFollowedSwap(netuid, hotkey4, hotkey5);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);

        assertTrue(lens.isBackingIntact(tokenId), "the quote reads the position as sound");
        vault.rebalance(netuid);

        VaultReads.Slot[] memory slots = vault.recordedSlots(tokenId);
        assertEq(slots[0].logical, hotkey1, "the registry has not moved");
        assertEq(slots[0].active, hotkey5, "the alpha is tracked at the live key");
        assertEq(lens.lastSeenHotkeys(tokenId)[0], hotkey5, "the lens reports the same key");
        assertApproxEqAbs(lens.totalStake(tokenId), 10 ether, 0.01 ether, "backing whole across both swaps");
    }

    function test_SwappedValidator_AllRailsKeepWorking() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 shares = _depositAndWrap(bob, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        // A deposit that followed the swap to the new key is the owner's to redirect: reclaim,
        // stake toward a key still in the attested set, wrap.
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

    // -------------------- Sets that move under the record ------------------------

    /// @dev Weights follow the validator the registry named, wherever a swap has since carried that
    ///      validator's alpha, and reordering the set must not shuffle them.
    function test_ReorderedSet_KeepsWeightsWithTheirValidators() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        // A swap the attesters can keep naming the old validator across, which is what makes the
        // reordered set below attestable at all.
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        _setValidators(NETUID1, _hotkeys(hotkey3, hotkey1, hotkey2), _weights(5000, 3000, 2000));
        vault.rebalance(NETUID1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].logical, hotkey3, "slot order follows the attested set");
        assertEq(slots[1].logical, hotkey1, "the swapped validator kept its own weight slot");
        assertEq(slots[1].active, hotkey4, "and its alpha is still tracked at the successor");
        assertApproxEqAbs(lens.totalStake(TOKEN1), 30 ether, 0.01 ether, "nothing lost in the reorder");
    }

    function test_DroppedValidator_HasItsAlphaRolledOntoTheNewSet() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        // hotkey1 leaves the set; its alpha is sitting at hotkey4 and must come back.
        _setValidators(NETUID1, _hotkeys(hotkey2, hotkey3), _weights(5000, 5000));
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "the successor was drained");
        assertEq(vault.recordedSlots(TOKEN1).length, 2, "the record matches the new set");
        assertApproxEqAbs(lens.totalStake(TOKEN1), 30 ether, 0.01 ether, "backing whole after the roll");
    }

    /// @dev When the attesters replace a validator with the very key its alpha was swapped to, that
    ///      key answers for its own attested entry and the balance is counted exactly once.
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
        assertApproxEqAbs(lens.totalStake(TOKEN1), 30 ether, 0.01 ether, "and nothing is counted twice");
    }

    /// @dev A set naming both a swapped-away key and its successor cannot be served: the old name
    ///      refuses every stake operation, so the rails refuse cheaply until the attesters drop
    ///      it. The TAO exit reads no attested set and stays open.
    function test_SetNamingASwappedKeyAndItsSuccessor_RefusesCheaply() public {
        _setAlphaPrice(NETUID1, 1e18);
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        // The set lands while the old name is still a key the chain owns; the swap that empties it
        // of an owner comes after, which is the only order the registry admits.
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

    // -------------------- Where an entry holding nothing is staked ---------------

    /// @dev The position with its first validator swapped away, followed, and then sold out of:
    ///      the slot holds nothing and its attested name is one the chain now refuses.
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

    /// @dev A validator attested between two calls can swap before any of the position reaches it,
    ///      leaving the record no slot to answer from and the attested name unusable.
    function test_ValidatorSwappingBeforeItIsFunded_StakesItsShareAtTheSuccessor() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey5);

        vault.rebalance(NETUID1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[2].logical, hotkey4, "the record names the attested validator");
        assertEq(slots[2].active, hotkey5, "while its share sits at the successor");
        assertGt(_getVaultStake(hotkey5, NETUID1), 0, "which is where the rebalance staked it");
        assertApproxEqAbs(lens.totalStake(TOKEN1), 30 ether, 0.01 ether, "backing whole across the swap");
    }

    /// @dev A swap confined to one subnet leaves the old name a key the chain still answers for, so
    ///      the validator's share goes on being staked under the name the attesters wrote down.
    function test_PerSubnetSwapAfterADrain_StakesTheShareAtTheAttestedName() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        _drainTheFirstSlot(alice, NETUID1);

        vault.rebalance(NETUID1);

        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey1, "the slot answers under its own name again");
        assertGt(_getVaultStake(hotkey1, NETUID1), 0, "which is where its share went");
    }

    /// @dev A name the chain has no owner for and no successor for has nowhere to send its
    ///      validator's share. The rails say so by name rather than forward a move the chain would
    ///      reject at the cost of the whole forwarded budget. The TAO exit reads no attested set
    ///      and stays open.
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

    /// @dev One hop is all the vault reads, so that hop has to land on a key the chain will accept.
    function test_RetiredNameWithARetiredSuccessor_RefusesTheRebalance() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey5);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey5, true);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        vault.rebalance(NETUID1);
    }

    /// @dev Selling the slot out does not make a set listing a retired name beside its successor
    ///      servable: the retired name has nowhere to go but the key its neighbour was given.
    function test_SetNamingADrainedSwapAndItsSuccessor_StillRefuses() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey4, hotkey2), _weights(3334, 3333, 3333));
        // The validator retires the old key across every subnet once the attesters have signed.
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);
        _drainTheFirstSlot(alice, NETUID1);

        vm.expectRevert(SwappedHotkeyStillAttested.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev The same holds while the old key is still one the chain answers for: an emptied slot
    ///      keeps the key it resolved to for as long as its validator stays attested, so the
    ///      successor's own entry has nowhere to sit until the attesters drop the old name.
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

    /// @dev However wide the set, re-serving a drained swap leaves every slot on a key of its own
    ///      and the whole position under the keys the record names.
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

    // -------------------- Quiet changes never trip -------------------------------

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

    /// @dev A holder's own exit lowers the balances the record was anchored to. Left unrefreshed the
    ///      record would read the withdrawal back as a shortfall, and hold the successor of any
    ///      later swap to an expectation the position no longer owes.
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

    /// @dev The TAO rail sells whole slots first, so which validators still hold anything varies.
    ///      What has to hold either way is that the exit leaves nothing the next swap trips over.
    function test_SwapAfterTaoExit_StaysOperable() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);
        uint256 backingAfterExit = lens.totalStake(TOKEN1);

        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "the TAO rail leaves a record the swap cannot trip");
        vault.rebalance(NETUID1);
        assertApproxEqAbs(lens.totalStake(TOKEN1), backingAfterExit, 0.01 ether, "backing whole across the swap");
    }

    function test_MoveRounding_DoesNotTrip() public {
        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(100);
        _depositAndWrap(alice, NETUID1, 30 ether);
        vault.rebalance(NETUID1);
        vault.rebalance(NETUID1);
        assertTrue(lens.isBackingIntact(TOKEN1), "rounding stays inside the slack");
    }

    function testFuzz_WideSet_FollowsASwap(uint256 rawCount) public {
        uint256 count = bound(rawCount, 2, 64);
        uint256 netuid = 9;
        _setRegBlock(netuid, 400);
        bytes32[] memory hks = _setValidatorCount(netuid, count);

        _simulateAlphaDepositHotkey(alice, netuid, 64 ether, hks[0]);
        _wrapHotkey(alice, netuid, hks[0]);
        uint256 tokenId = vault.currentTokenId(netuid);

        bytes32 swapped = keccak256("wide-set-successor");
        _simulateFollowedSwap(netuid, hks[0], swapped);
        vault.rebalance(netuid);

        assertApproxEqAbs(lens.totalStake(tokenId), 64 ether, 0.01 ether, "backing whole across the wide set");
        assertTrue(lens.isBackingIntact(tokenId), "record sound after the follow");
    }
}
