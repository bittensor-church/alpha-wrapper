// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import { SwappedHotkeyStillAttested } from "src/VaultErrors.sol";
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

        _simulateAlphaDepositHotkey(alice, NETUID1, 10 ether, hotkey4);
        _wrapHotkey(alice, NETUID1, hotkey1);
        vm.prank(bob);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(bob));
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
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
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
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        _setValidators(
            NETUID1, _hotkeys(hotkey1, hotkey4, hotkey2), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );

        vm.expectRevert(SwappedHotkeyStillAttested.selector);
        vault.rebalance(NETUID1);
        vm.expectRevert(SwappedHotkeyStillAttested.selector);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice));

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);

        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vault.rebalance(NETUID1);
        assertTrue(lens.isBackingIntact(TOKEN1), "dropping the stale name resumes service");
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
        vault.unwrap(TOKEN1, aliceShares / 3, _toSubstrate(alice));
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
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice));

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            assertEq(slots[i].tracked, _getVaultStake(slots[i].active, NETUID1), "expectation matches the ledger");
        }
    }

    function test_SwapAfterWithdrawal_IsStillFollowed() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice));

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
