// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { stdError } from "forge-std/Test.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import {
    BackingShortfall,
    BackingUnchanged,
    NothingToRecover,
    NothingToUnwrap,
    RecoveryBelowFloor,
    SubnetInDissolutionBlackoutPeriod
} from "src/VaultErrors.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// @dev Covers getting a position back once the vault has lost sight of its alpha: a watcher
///      pointing it at the key that holds it, and a loss nobody can find running out its window and
///      being socialized.
contract BackingRecoveryTest is AlphaVaultTestBase {
    // -------------------- Starting the clock -------------------------------------

    /// @dev Nobody has to be transacting for the clock to start. Every rail that would notice a loss
    ///      refuses, and a revert leaves no record behind, so a token nothing else touches would sit
    ///      shut for good if this needed anyone's permission.
    function test_SyncBacking_StartsTheWindowWithoutAQuorum() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        _buildSwapTrail(NETUID1, hotkey1, 2);

        assertEq(lens.frozenUntil(TOKEN1), type(uint256).max, "a loss with no clock reports no opening");
        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingShortfallDeclared(TOKEN1, hotkey1, owed, 0);
        vm.prank(bob);
        vault.syncBacking(TOKEN1);

        assertEq(lens.frozenUntil(TOKEN1), block.timestamp + VaultReads.RECOVERY_WINDOW, "the window runs from here");
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, owed, "the slot still knows what it is owed");
        assertFalse(lens.isBackingIntact(TOKEN1), "and still reports itself short");
    }

    /// @dev The clock starts once per loss and is never restarted, or anyone could hold a token shut
    ///      indefinitely by re-declaring the same loss every couple of hours.
    function test_SyncBacking_CannotPushTheDeadlineOut() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);
        uint256 deadline = lens.frozenUntil(TOKEN1);

        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
        assertEq(lens.frozenUntil(TOKEN1), deadline, "the deadline did not move");
    }

    function test_RevertWhen_SyncingATokenThatAccountsForItself() public {
        _depositAndWrap(alice, NETUID1, 30 ether);

        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
    }

    function test_RevertWhen_SyncingATokenWithNoPosition() public {
        vm.expectRevert(NothingToUnwrap.selector);
        vault.syncBacking(TOKEN1);
    }

    /// @dev A dissolved position's alpha legitimately became TAO, so its emptied slots are not a
    ///      loss and must not be filed as one.
    function test_RevertWhen_SyncingARetiredTokenId() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _setRegBlock(NETUID1, 999);

        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
    }

    /// @dev A slot whose backing went missing must not keep the record pointed at the key it went
    ///      missing from: a write-off there would leave holders' alpha staked under a key the
    ///      attesters never named, and a retired one would refuse every move aimed at it.
    function test_WriteOff_ReturnsAShortSlotToItsAttestedValidator() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey4, "the record followed the swap");

        // The successor is then emptied with nothing on chain explaining it, and left unusable.
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, _subnetColdkey(NETUID1), NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);
        _runOutRecoveryWindow(TOKEN1);

        vault.rebalance(NETUID1);

        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey1, "the slot answers to its validator again");
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "and nothing was staked toward the dead key");
        assertTrue(lens.isBackingIntact(TOKEN1), "the token is ordinary again");

        uint256 quarter = vault.balanceOf(alice, TOKEN1) / 4;
        vm.prank(alice);
        vault.unwrap(TOKEN1, quarter, _toSubstrate(alice));
    }

    /// @dev Starting a clock persists followed swaps and settles nothing else, so it takes the same
    ///      guards as every other rail that writes to the record.
    function test_RevertWhen_SyncingWhileTheSubnetIsDissolving() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        _setDissolving(NETUID1, true);

        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        vault.syncBacking(TOKEN1);
    }

    /// @dev A loss that repairs itself must not leave its spent clock behind, or the next identical
    ///      loss would inherit an expired deadline and be written off with no window at all.
    function test_LossRepairingItself_SpendsItsClock() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        bytes32 tip = _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);

        _simulateOffVaultSwap(NETUID1, tip, hotkey1);
        vault.syncBacking(TOKEN1);
        assertEq(lens.frozenUntil(TOKEN1), 0, "the window it was granted is spent");
        assertEq(vault.recordedSlots(TOKEN1)[0].shortSince, 0, "no clock left running");

        vm.warp(block.timestamp + 2 * VaultReads.RECOVERY_WINDOW);
        assertEq(_getVaultStake(hotkey1, NETUID1), owed, "the recurrence is identical to the first loss");
        _buildSwapTrail(NETUID1, hotkey1, 2);

        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
        assertEq(lens.frozenUntil(TOKEN1), type(uint256).max, "the recurrence starts from no clock at all");
    }

    // -------------------- Recovery by naming where the alpha went ----------------

    /// @dev Recovery needs nobody's signature. The alpha sits under the vault's own coldkey, so
    ///      moving it between the vault's own keys can only bring backing back into view - which is
    ///      why anyone may do it, the moment they find it.
    function test_RecoverStray_ClearsTheShortfallWithoutAQuorum() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        vault.syncBacking(TOKEN1);
        assertFalse(lens.isBackingIntact(TOKEN1), "the loss is visible first");

        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingRecovered(TOKEN1, hotkey1, owed);
        vm.prank(bob);
        vault.recoverStray(TOKEN1, 0, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "the found alpha accounts for the loss");
        assertEq(lens.frozenUntil(TOKEN1), 0, "finding it ends the window");
        assertApproxEqAbs(lens.totalStake(TOKEN1), 30 ether, 0.01 ether, "backing whole after recovery");
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey1, "and the alpha is back where the slot expects it");
    }

    /// @dev The second hop is never read, so a deeper trail is the watcher's to resolve: they name
    ///      the key at the far end and the alpha comes home.
    function test_RecoverStray_ResolvesATwoHopTrail() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 tip = _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, 0, tip);

        assertTrue(lens.isBackingIntact(TOKEN1), "the watcher-supplied source accounts for the loss");
        assertApproxEqAbs(lens.totalStake(TOKEN1), 30 ether, 0.01 ether, "backing whole again");
    }

    /// @dev A swap that keeps its stake leaves the alpha under a hotkey nobody owns, which the chain
    ///      refuses to move. The vault takes no ownership of its own: an unrelated account claims
    ///      the abandoned key - free, and carrying no claim on the stake under it - and the same
    ///      recovery then goes through.
    function test_RecoverStray_WaitsForAnOutsiderToClaimTheAbandonedKey() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);
        vault.syncBacking(TOKEN1);

        vm.expectRevert();
        vm.prank(bob);
        vault.recoverStray(TOKEN1, 0, hotkey4);

        // An account with no part in the vault, the subnet or the swap takes the key on.
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, false);
        vm.prank(bob);
        vault.recoverStray(TOKEN1, 0, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "the exit reopens without the vault owning anything");
        uint256 quarter = vault.balanceOf(alice, TOKEN1) / 4;
        vm.prank(alice);
        vault.unwrap(TOKEN1, quarter, _toSubstrate(alice));
    }

    /// @dev Recovery adds to a fixed target, so fragments can come home one at a time. None of them
    ///      touches the deadline, and the slot is whole only once its key covers what it was owed.
    function test_RecoverStray_RestoresASlotInFragments() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, owed / 3);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey5, coldkey, NETUID1, owed - owed / 3);
        vault.syncBacking(TOKEN1);
        uint256 deadline = lens.frozenUntil(TOKEN1);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, 0, hotkey4);
        assertFalse(lens.isBackingIntact(TOKEN1), "a fragment is not the whole expectation");
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, owed, "and the target it is measured against stands");
        assertEq(lens.frozenUntil(TOKEN1), deadline, "the deadline did not move");

        vm.prank(bob);
        vault.recoverStray(TOKEN1, 0, hotkey5);
        assertTrue(lens.isBackingIntact(TOKEN1), "the second fragment completes it");
        assertEq(lens.frozenUntil(TOKEN1), 0, "and the window ends");
        assertEq(_getVaultStake(hotkey1, NETUID1), owed, "with everything under the key the slot expects");
    }

    /// @dev Alpha the chain would refuse to move is not recovered and is socialized with the rest
    ///      of the loss. The refusal is cheap: a chain-side rejection would burn the whole call.
    function test_RevertWhen_TheStrayIsTooSmallForTheChainToMove() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, 1);
        vault.syncBacking(TOKEN1);

        vm.expectRevert(RecoveryBelowFloor.selector);
        vm.prank(bob);
        vault.recoverStray(TOKEN1, 0, hotkey4);
    }

    /// @dev Putting one slot's loss on file must not drop the swap another slot resolved on the way
    ///      past, or the record would keep pointing at the key that validator's alpha departed.
    function test_SyncBacking_KeepsAFollowedSwapInTheRecord() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 moved = _getVaultStake(hotkey1, NETUID1);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        _buildSwapTrail(NETUID1, hotkey2, 2);

        vault.syncBacking(TOKEN1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].active, hotkey4, "the record kept the key the swap reached");
        assertEq(slots[0].shortSince, 0, "which is not a loss and needs no clock");
        assertEq(_getVaultStake(hotkey4, NETUID1), moved, "and that is where the alpha is");
        assertGt(slots[1].shortSince, 0, "while the loss beside it got its own");
    }

    function test_RevertWhen_RecoveringFromAKeyHoldingNothing() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, 0, hotkey5);
    }

    function test_RevertWhen_RecoveringFromTheSlotsOwnKey() public {
        _depositAndWrap(alice, NETUID1, 30 ether);

        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, 0, hotkey1);
    }

    function test_RevertWhen_RecoveringWithASlotIndexOutOfRange() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);

        vm.expectRevert(stdError.indexOOBError);
        vault.recoverStray(TOKEN1, 3, hotkey4);
    }

    // -------------------- Running out the window ---------------------------------

    /// @dev The permissionless maintenance rail takes the write-off too, so a token nobody is
    ///      depositing into or exiting from still comes back on its own.
    function test_RebalanceAfterTheWindow_WritesTheLossOff() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        _runOutRecoveryWindow(TOKEN1);

        vault.rebalance(NETUID1);

        assertTrue(lens.isBackingIntact(TOKEN1), "the settle took the write-off");
        assertEq(lens.frozenUntil(TOKEN1), 0, "and the token is ordinary again");
        _simulateAlphaDeposit(bob, NETUID1, 1 ether);
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey1);
        assertGt(vault.balanceOf(bob, TOKEN1), 0, "deposits resume");
    }

    /// @dev The window is a floor, not a cliff: until a settling call anchors the record, the slot
    ///      still knows what it was owed and a late finder can still bring it home in full.
    function test_RecoverStray_StillAnswersAfterTheDeadline() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _runOutRecoveryWindow(TOKEN1);
        vm.warp(block.timestamp + 2 days);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, 0, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "the alpha came home in the overtime");
        assertApproxEqAbs(lens.totalStake(TOKEN1), 30 ether, 0.01 ether, "and the backing is whole again");
    }

    /// @dev Once the loss is booked it is gone for the holders who bore it. Alpha found afterwards
    ///      is new backing for whoever holds shares then - a deliberate transfer to the current
    ///      cohort, accepted as the price of a bounded window rather than an accident.
    function test_LateFoundAlpha_IsAWindfallForTheCurrentCohort() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 lost = _getVaultStake(hotkey1, NETUID1);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _runOutRecoveryWindow(TOKEN1);
        vault.rebalance(NETUID1);

        // Alice exits at the written-off valuation and takes none of what turns up later.
        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice));
        uint256 bobShares = _depositAndWrap(bob, NETUID1, 10 ether);
        uint256 navBefore = lens.totalStake(TOKEN1);

        vm.prank(alice);
        vault.recoverStray(TOKEN1, 0, hotkey4);

        assertApproxEqAbs(lens.totalStake(TOKEN1), navBefore + lost, 0.01 ether, "the find is new backing");
        (uint256 bobsAlpha,) = lens.previewUnwrap(TOKEN1, bobShares);
        assertGt(bobsAlpha, 10 ether, "and it belongs to whoever holds shares now");
        assertEq(vault.balanceOf(alice, TOKEN1), 0, "not to the cohort that bore the loss");
    }

    // -------------------- Mailboxes ----------------------------------------------

    /// @dev A hotkey swap carries a waiting deposit along with everyone else's stake. The mailbox
    ///      reads the chosen key and, if that is empty, its single direct successor.
    function test_Wrap_FindsADepositOneSwapAway() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        address mailbox = vault.getDepositAddress(bob, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, _toSubstrate(mailbox), NETUID1, 1 ether);

        vm.prank(bob);
        vault.wrap(NETUID1, hotkey1);

        assertGt(vault.balanceOf(bob, TOKEN1), 0, "the deposit landed from one edge away");
        assertEq(_getStakeForColdkey(hotkey4, _toSubstrate(mailbox), NETUID1), 0, "and the mailbox was drained");
        assertTrue(lens.isBackingIntact(TOKEN1), "with the record naming where it went");
    }

    /// @dev No path reads a second edge, so a deposit two swaps deep is not found here; it comes
    ///      back through the mailbox reclaim rail and is staked again.
    function test_Wrap_DoesNotWalkPastOneEdge() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        address mailbox = vault.getDepositAddress(bob, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey4, NETUID1, hotkey5);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey5, _toSubstrate(mailbox), NETUID1, 1 ether);

        vm.expectRevert(bytes4(keccak256("ZeroAmount()")));
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey1);

        vm.prank(bob);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey5, _toSubstrate(bob));
        assertEq(_getStake(hotkey5, bob, NETUID1), 1 ether, "the deposit came back to its owner");
    }

    /// @dev A deposit aimed at a validator whose alpha the record has followed elsewhere still lands
    ///      on that validator's key rather than sitting where the mailbox left it.
    function test_Wrap_LandsOnTheKeyTheRecordFollows() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        _simulateAlphaDepositHotkey(bob, NETUID1, 6 ether, hotkey1);
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey1);

        assertGt(vault.balanceOf(bob, TOKEN1), 0, "the deposit landed off the chosen name");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing was aimed at the retired key");
        assertTrue(lens.isBackingIntact(TOKEN1), "and the record accounts for all of it");
    }

    /// @dev A loss deepening on the same key rides the window its slot already has: the clock
    ///      answers for the slot's whole expectation, so the size of the gap moves no deadline.
    function test_DeepeningLoss_KeepsTheOriginalDeadline() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);

        // Short by a hair: just past the slack the record forgives.
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, owed - 2e3);
        vault.syncBacking(TOKEN1);
        uint256 deadline = lens.frozenUntil(TOKEN1);

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        assertEq(lens.frozenUntil(TOKEN1), deadline, "the deadline did not move");

        vm.warp(deadline - 1);
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);

        vm.warp(deadline);
        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, hotkey1, owed, 0);
        vault.syncBacking(TOKEN1);
        assertTrue(lens.isBackingIntact(TOKEN1), "the whole slot settled with the window it had");
    }

    /// @dev Each slot's loss runs its own clock: a second loss neither restarts the first slot's
    ///      window nor rides it out.
    function test_SecondLoss_GetsItsOwnClock() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);
        uint256 firstDeadline = lens.frozenUntil(TOKEN1);

        vm.warp(block.timestamp + 1 hours);
        _buildSwapTrail(NETUID1, hotkey2, 2);
        vault.syncBacking(TOKEN1);

        assertEq(
            vault.recordedSlots(TOKEN1)[0].shortSince + VaultReads.RECOVERY_WINDOW,
            firstDeadline,
            "the first clock did not move"
        );
        assertEq(lens.frozenUntil(TOKEN1), firstDeadline + 1 hours, "and the second got its own");

        // The first slot's window is out, the second's is not: booking one leaves the other shut.
        vm.warp(firstDeadline);
        vault.syncBacking(TOKEN1);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);

        vm.warp(firstDeadline + 1 hours);
        vault.syncBacking(TOKEN1);
        assertTrue(lens.isBackingIntact(TOKEN1), "both settle once the later window is out");
    }

    /// @dev The deadline is the whole mechanism, so it is worth pinning either side of.
    function testFuzz_WriteOff_FallsDueOnlyOnceTheWindowIsOut(uint256 offset) public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);
        uint256 deadline = lens.frozenUntil(TOKEN1);

        uint256 at = bound(offset, deadline - VaultReads.RECOVERY_WINDOW, deadline + VaultReads.RECOVERY_WINDOW);
        vm.warp(at);

        if (at < deadline) {
            vm.expectRevert(BackingUnchanged.selector);
            vault.syncBacking(TOKEN1);
            vm.expectPartialRevert(BackingShortfall.selector);
            lens.totalStake(TOKEN1);
        } else {
            vault.syncBacking(TOKEN1);
            assertTrue(lens.isBackingIntact(TOKEN1), "the loss is booked from the deadline on");
            assertGt(lens.totalStake(TOKEN1), 0, "and the quote answers on what is left");
        }
    }

    /// @dev Only the finalizer gives up on a loss. A rail keeps refusing past the deadline, so a
    ///      deposit or an exit can never book a write-off as a side effect.
    function test_PastTheDeadline_OnlySyncBackingBooksTheLoss() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);
        uint256 located = lens.locatedStake(TOKEN1);

        vm.warp(lens.frozenUntil(TOKEN1));
        vm.expectPartialRevert(BackingShortfall.selector);
        lens.totalStake(TOKEN1);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
        vm.prank(alice);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice));

        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, hotkey1, owed, 0);
        vm.prank(bob);
        vault.syncBacking(TOKEN1);

        assertEq(lens.totalStake(TOKEN1), located, "the quote answers on what is there");
        assertEq(lens.frozenUntil(TOKEN1), 0, "and no clock is left running");
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice));
    }

    /// @dev A balance the resolver already answers for is not stray. Left shufflable, anyone could
    ///      move a swapped-to key's alpha onto another slot and leave the first one short.
    function test_RevertWhen_RecoveringFromAKeyASlotResolvesTo() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        // A direct swap the resolver follows, with no call yet to persist it.
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        vm.expectRevert(NothingToRecover.selector);
        vm.prank(bob);
        vault.recoverStray(TOKEN1, 1, hotkey4);

        assertEq(_getVaultStake(hotkey4, NETUID1), owed, "the swapped-to key kept its alpha");
        assertTrue(lens.isBackingIntact(TOKEN1), "and the slot it answers for stayed covered");
    }

    /// @dev A surplus on a covered slot is not stray either: it already counts where it sits, and
    ///      one slot is never recapitalized out of another.
    function test_RevertWhen_RecoveringFromACoveredSlotsSurplus() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, _getVaultStake(hotkey2, NETUID1) + 4 ether);
        vault.syncBacking(TOKEN1);

        vm.expectRevert(NothingToRecover.selector);
        vm.prank(bob);
        vault.recoverStray(TOKEN1, 0, hotkey2);
    }

    /// @dev Booking a loss must leave the record pointing somewhere the next call can use. A slot
    ///      finalized at zero keeps its old physical key, so the settle has to take the attested
    ///      validator instead - otherwise the rails aim at a key that refuses them.
    function test_BookedLoss_LeavesTheRailsAimingAtAnAttestedKey() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey4, "the record persisted the swap");

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, _subnetColdkey(NETUID1), NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);
        _runOutRecoveryWindow(TOKEN1);
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey4, "the booking left the key alone");

        // The other slots are still funded, so the rebalance has stake to aim somewhere.
        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey1, "the settle anchored the attested validator");
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "and nothing was aimed at the dead key");

        _simulateAlphaDepositHotkey(bob, NETUID1, 5 ether, hotkey2);
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey2);
        assertGt(vault.balanceOf(bob, TOKEN1), 0, "deposits work again");
    }
}
