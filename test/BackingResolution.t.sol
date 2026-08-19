// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { ValidatorRegistry } from "src/ValidatorRegistry.sol";
import { IValidatorRegistry } from "src/interfaces/IValidatorRegistry.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// @dev Covers a validator swapping its hotkey out from under the position: which swaps the vault
///      follows on its own, and which losses it refuses to price around. Recovery from a refusal
///      lives in BackingRecovery.t.sol.
contract BackingResolutionTest is AlphaVaultTestBase {
    event BackingRecovered(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 found);
    event HotkeySwapFollowed(uint256 indexed tokenId, bytes32 indexed oldHotkey, bytes32 indexed newHotkey);
    event BackingWrittenDown(uint256 indexed tokenId, uint256 nonce, uint256 located);

    bytes32 internal hotkey5 = keccak256("hotkey5");
    bytes32 internal hotkey6 = keccak256("hotkey6");

    // -------------------- What the record remembers ------------------------------

    function test_Wrap_RecordsWhereEachValidatorsAlphaIs() public {
        _depositAndWrap(alice, NETUID1, 30 ether);

        AlphaVault.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots.length, 3, "one slot per attested validator");
        assertEq(slots[0].logical, hotkey1, "slot names the attested validator");
        assertEq(slots[0].active, hotkey1, "with nothing renamed the two agree");
        assertEq(slots[0].tracked, _getVaultStake(hotkey1, NETUID1), "tracked mirrors the staked alpha");
    }

    function test_Rename_MovesActiveAndLeavesLogicalAlone() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        vm.expectEmit(true, true, true, true, address(vault));
        emit HotkeySwapFollowed(TOKEN1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        AlphaVault.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].logical, hotkey1, "the registry still names the original validator");
        assertEq(slots[0].active, hotkey4, "the alpha is tracked at the successor");
        assertApproxEqAbs(vault.totalStake(TOKEN1), 30 ether, 0.01 ether, "backing whole across the rename");
    }

    /// @dev The record standing a hop ahead of the registry is the ordinary state after a rename,
    ///      and a second one must move it forward again rather than back to the key between.
    function test_RepeatedRename_NeverAimsAtTheRetiredKey() public {
        uint256 netuid = 5;
        _registerSubnet(netuid, hotkey1);
        _depositAndWrap(alice, netuid, 10 ether);
        uint256 tokenId = vault.currentTokenId(netuid);

        _simulateFollowedSwap(netuid, hotkey1, hotkey4);
        vault.rebalance(netuid);

        // The middle key is retired by the second rename, exactly as a global swap leaves it.
        _simulateFollowedSwap(netuid, hotkey4, hotkey5);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);

        assertTrue(vault.isBackingIntact(tokenId), "the quote reads the position as sound");
        vault.rebalance(netuid);

        AlphaVault.Slot[] memory slots = vault.recordedSlots(tokenId);
        assertEq(slots[0].logical, hotkey1, "the registry has not moved");
        assertEq(slots[0].active, hotkey5, "the alpha is tracked at the live key");
        assertApproxEqAbs(vault.totalStake(tokenId), 10 ether, 0.01 ether, "backing whole across both renames");
    }

    function test_RenamedValidator_AllRailsKeepWorking() public {
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
        assertTrue(vault.isBackingIntact(TOKEN1), "record sound throughout");
    }

    // -------------------- Fail closed on an unexplained shortfall ----------------

    function test_UnfollowableRename_FailsClosedOnEveryPath() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _depositAndWrap(bob, NETUID1, 30 ether);
        _buildRenameTrail(NETUID1, hotkey1, 2);

        assertFalse(vault.isBackingIntact(TOKEN1), "a trail the vault cannot walk is not accounted for");

        // Minting is the one direction an understated position can be exploited from, so it waits.
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.previewWrap(TOKEN1, 1 ether);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);
        _simulateAlphaDeposit(bob, NETUID1, 1 ether);
        vm.prank(bob);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.wrap(NETUID1, hotkey1);

        // Holders are not shut in by a loss they did not cause. Both rails pay out of what the
        // vault can locate, and the quote says the same number the exit pays.
        (uint256 quoted,) = vault.previewUnwrap(TOKEN1, shares / 2);
        assertGt(quoted, 0, "the exit is quoted, not refused");
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice));
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), quoted, "and pays exactly what it quoted");
        vm.prank(bob);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);
    }

    /// @dev A withdrawal re-reads the record from the chain, which would file the loss as an
    ///      ordinary balance change and reopen deposits at the lowered price. The slot the plan
    ///      could not account for keeps its expectation instead.
    function test_ExitDuringAShortfall_LeavesTheLossStanding() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        _buildRenameTrail(NETUID1, hotkey1, 2);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice));

        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, owed, "the exit did not write the loss off");
        assertFalse(vault.isBackingIntact(TOKEN1), "so the token still reports itself short");
        _simulateAlphaDeposit(bob, NETUID1, 1 ether);
        vm.prank(bob);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.wrap(NETUID1, hotkey1);
    }

    /// @dev Each slot answers for its own expectation, so growth elsewhere cannot cover a loss.
    function test_GrowthElsewhere_DoesNotCoverALoss() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 lost = _getVaultStake(hotkey1, NETUID1);
        _buildRenameTrail(NETUID1, hotkey1, 2);

        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE)
            .setStake(hotkey2, coldkey, NETUID1, _getVaultStake(hotkey2, NETUID1) + lost + 5 ether);

        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev One balance cannot back two positions, whether or not the attesters name the key.
    function test_ConvergentRenames_FailClosed() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 merged = _getVaultStake(hotkey1, NETUID1) + _getVaultStake(hotkey2, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, merged);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey2, NETUID1, hotkey4);

        assertFalse(vault.isBackingIntact(TOKEN1), "the quote sees the collision");
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    function test_ConvergentRenamesOntoAttestedKey_FailClosed() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 merged = _getVaultStake(hotkey1, NETUID1) + _getVaultStake(hotkey2, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, merged);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey2, NETUID1, hotkey4);
        // The successor is itself attested, so it already sits in the union and is counted there.
        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );

        assertFalse(vault.isBackingIntact(TOKEN1), "counted once is not claimed twice");
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.previewWrap(TOKEN1, 1 ether);
    }

    /// @dev A followed rename leaves the record naming A while its alpha sits under B. If the
    ///      attesters then name B in its own right, A's slot and B's slot resolve onto one balance
    ///      and the token would report twice the backing it holds. The set is refused instead, and
    ///      the attesters clear it by dropping one of the pair.
    function test_SetNamingBothEndsOfARename_FailsClosed() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey4, hotkey2), _weights(4000, 3000, 3000));

        vm.expectPartialRevert(AlphaVault.HotkeyClaimedTwice.selector);
        vault.rebalance(NETUID1);

        _setValidators(NETUID1, _hotkeys(hotkey4, hotkey2), _weights(6000, 4000));
        vault.rebalance(NETUID1);
        assertTrue(vault.isBackingIntact(TOKEN1), "dropping the retired name clears the collision");
    }

    /// @dev A rename can carry one slot's alpha onto a name the set still lists, when that name's
    ///      own slot has itself moved on. Nothing answers twice there, and refusing it would freeze
    ///      a healthy token, so the check reads the keys the slots resolve to rather than the names
    ///      the attesters wrote.
    function test_RenameOntoAStillListedName_StaysOperable() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey2, hotkey5);
        vault.rebalance(NETUID1);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey2);

        vault.rebalance(NETUID1);

        AlphaVault.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].active, hotkey2, "the first slot followed onto the freed name");
        assertEq(slots[1].active, hotkey5, "the second slot kept the key its own rename reached");
        assertTrue(vault.isBackingIntact(TOKEN1), "no balance answers for two slots");
    }

    // -------------------- Emptyings the chain does not explain -------------------

    /// @dev The chain's dust sweep records nothing at all. Reading that silence as proof of a sweep
    ///      would be unsound, because a rename leaves the same silence once the old key is
    ///      registered again and the chain drops the edge: an operator could rename away with the
    ///      alpha, re-register, and have the vault write the loss off and reprice the token beneath
    ///      it. So an emptying nothing explains stands, and the attesters settle what happened.
    function test_EdgeFreeEmptying_FailsClosed() public {
        uint256 netuid = 5;
        _registerSubnet(netuid, hotkey1);
        _depositAndWrap(alice, netuid, 1e7);
        uint256 tokenId = vault.currentTokenId(netuid);

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(netuid), netuid, 0);

        assertFalse(vault.isBackingIntact(tokenId), "nothing on chain accounts for the emptying");
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(netuid);
    }

    /// @dev The same silence with the alpha demonstrably alive under another key. The vault has no
    ///      way to tell this from the case above and does not guess between them.
    function test_RenameWithNoEdge_FailsClosed() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        assertFalse(vault.isBackingIntact(TOKEN1), "an unrecorded move is not accounted for");
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev An earlier value-based rule answered differently as the market moved. Nothing in the
    ///      decision reads a price, so neither the size of the loss nor the price of alpha touches
    ///      the verdict.
    function test_EdgeFreeEmptying_RefusesAtAnyPriceOrSize() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, coldkey, NETUID1, 0);
        _setAlphaPrice(NETUID1, 10e18);

        assertFalse(vault.isBackingIntact(TOKEN1), "a whole position is no better explained than dust");
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev A position the chain really did empty. The holder is never shut in - the exit retires
    ///      the shares against what is located, which is nothing - and deposits resume only once
    ///      the acknowledgement has stood unchallenged for its window.
    function test_SweptPosition_ReopensAfterAWriteDown() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, coldkey, NETUID1, 0);

        assertEq(vault.totalStake(TOKEN1), 0, "an emptied position reads an honest zero");
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));
        assertEq(vault.totalSupply(TOKEN1), 0, "the shares retire without waiting on anyone");

        _writeDown(TOKEN1, 0);
        vm.warp(vault.depositsOpenFrom(TOKEN1));
        _depositAndWrap(bob, NETUID1, 30 ether);
        assertGt(vault.balanceOf(bob, TOKEN1), 0, "the token recapitalizes after the window");
    }

    // -------------------- Sets that move under the record ------------------------

    /// @dev Weights follow the validator the registry named, wherever a rename has since carried
    ///      that validator's alpha, and reordering the set must not shuffle them.
    function test_ReorderedSet_KeepsWeightsWithTheirValidators() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        _setValidators(NETUID1, _hotkeys(hotkey3, hotkey1, hotkey2), _weights(5000, 3000, 2000));
        vault.rebalance(NETUID1);

        AlphaVault.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].logical, hotkey3, "slot order follows the attested set");
        assertEq(slots[1].logical, hotkey1, "the renamed validator kept its own weight slot");
        assertEq(slots[1].active, hotkey4, "and its alpha is still tracked at the successor");
        assertApproxEqAbs(vault.totalStake(TOKEN1), 30 ether, 0.01 ether, "nothing lost in the reorder");
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
        assertApproxEqAbs(vault.totalStake(TOKEN1), 30 ether, 0.01 ether, "backing whole after the roll");
    }

    // -------------------- Quiet changes never trip -------------------------------

    function test_Emissions_DoNotTrip() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateEmissions(NETUID1, 5 ether);
        vault.rebalance(NETUID1);
        assertGt(vault.totalStake(TOKEN1), 30 ether, "emission counted, no false trip");
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

        assertTrue(vault.isBackingIntact(TOKEN1), "the record settled through the whole sequence");
    }

    /// @dev A holder's own exit lowers the balances the record was anchored to. Left unrefreshed
    ///      the record would read the withdrawal back as a shortfall, and hold the successor of any
    ///      later rename to an expectation the position no longer owes.
    function test_Withdrawal_ReanchorsTheRecord() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice));

        AlphaVault.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            assertEq(slots[i].tracked, _getVaultStake(slots[i].active, NETUID1), "expectation matches the ledger");
        }
    }

    function test_RenameAfterWithdrawal_IsStillFollowed() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice));

        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        assertTrue(vault.isBackingIntact(TOKEN1), "an ordinary rename after an exit is still followable");
        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey4, "the record moved to the successor");
    }

    /// @dev The TAO rail sells whole slots first, so which validators still hold anything varies.
    ///      What has to hold either way is that the exit leaves nothing the next rename trips over.
    function test_RenameAfterTaoExit_StaysOperable() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);
        uint256 backingAfterExit = vault.totalStake(TOKEN1);

        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        assertTrue(vault.isBackingIntact(TOKEN1), "the TAO rail leaves a record the rename cannot trip");
        vault.rebalance(NETUID1);
        assertApproxEqAbs(vault.totalStake(TOKEN1), backingAfterExit, 0.01 ether, "backing whole across the rename");
    }

    function test_MoveRounding_DoesNotTrip() public {
        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(100);
        _depositAndWrap(alice, NETUID1, 30 ether);
        vault.rebalance(NETUID1);
        vault.rebalance(NETUID1);
        assertTrue(vault.isBackingIntact(TOKEN1), "rounding stays inside the slack");
    }

    function testFuzz_WideSet_FollowsARename(uint256 rawCount) public {
        uint256 count = bound(rawCount, 2, 64);
        uint256 netuid = 9;
        _setRegBlock(netuid, 400);
        bytes32[] memory hks = _setValidatorCount(netuid, count);

        _simulateAlphaDepositHotkey(alice, netuid, 64 ether, hks[0]);
        _wrapHotkey(alice, netuid, hks[0]);
        uint256 tokenId = vault.currentTokenId(netuid);

        bytes32 renamed = keccak256("wide-set-successor");
        _simulateFollowedSwap(netuid, hks[0], renamed);
        vault.rebalance(netuid);

        assertApproxEqAbs(vault.totalStake(tokenId), 64 ether, 0.01 ether, "backing whole across the wide set");
        assertTrue(vault.isBackingIntact(tokenId), "record sound after the follow");
    }

    // -------------------- Helpers -------------------------------------------------

    /// @dev Moves the clone's backing between hotkeys with no vault call and no lineage, standing
    ///      in for a rename this subnet recorded nothing for.
    function _simulateOffVaultSwap(uint256 netuid, bytes32 fromHotkey, bytes32 toHotkey) internal {
        bytes32 coldkey = _subnetColdkey(netuid);
        uint256 amount = _getStakeForColdkey(fromHotkey, coldkey, netuid);
        MockStaking(STAKING_PRECOMPILE).setStake(fromHotkey, coldkey, netuid, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(toHotkey, coldkey, netuid, amount);
    }

    /// @dev A rename as the chain records it: the stake moves and the lineage points at it.
    function _simulateFollowedSwap(uint256 netuid, bytes32 fromHotkey, bytes32 toHotkey) internal {
        _simulateOffVaultSwap(netuid, fromHotkey, toHotkey);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(fromHotkey, netuid, toHotkey);
    }

    /// @dev Chains `hops` renames, leaving the backing at the far tip and the vault able to walk
    ///      only the first edge.
    function _buildRenameTrail(uint256 netuid, bytes32 fromHotkey, uint256 hops) internal returns (bytes32 tip) {
        bytes32 previous = fromHotkey;
        for (uint256 i; i < hops; ++i) {
            tip = keccak256(abi.encode("trail-hop", fromHotkey, i));
            MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(previous, netuid, tip);
            previous = tip;
        }
        _simulateOffVaultSwap(netuid, fromHotkey, tip);
    }
}
