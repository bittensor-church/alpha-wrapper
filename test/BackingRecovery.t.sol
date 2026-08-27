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

    /// @dev A loss deepening on the same key rides the window its slot already has: the clock
    ///      answers for the slot's whole expectation, fixed at the last settle, so nothing about the
    ///      gap's size can move a deadline in either direction.
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
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);

        vm.warp(deadline);
        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, hotkey1, owed, 0);
        vault.rebalance(NETUID1);
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

        vm.warp(firstDeadline);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);

        vm.warp(firstDeadline + 1 hours);
        vault.rebalance(NETUID1);
        assertTrue(lens.isBackingIntact(TOKEN1), "both settle once the later window is out");
    }

    /// @dev The deadline is the whole mechanism, so it is worth pinning either side of rather than
    ///      only at the boundary every other test warps to.
    function testFuzz_WriteOff_FallsDueOnlyOnceTheWindowIsOut(uint256 offset) public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);
        uint256 deadline = lens.frozenUntil(TOKEN1);

        uint256 at = bound(offset, deadline - VaultReads.RECOVERY_WINDOW, deadline + VaultReads.RECOVERY_WINDOW);
        vm.warp(at);

        if (at < deadline) {
            vm.expectPartialRevert(BackingShortfall.selector);
            vault.rebalance(NETUID1);
            vm.expectPartialRevert(BackingShortfall.selector);
            lens.totalStake(TOKEN1);
        } else {
            assertGt(lens.totalStake(TOKEN1), 0, "the reduced holding is publishable from the deadline");
            vault.rebalance(NETUID1);
            assertTrue(lens.isBackingIntact(TOKEN1), "and the next write anchors it");
        }
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

    /// @dev A key another slot answers for may only give up what it holds above that slot's own
    ///      expectation, or one checkpoint could be drained to make another look whole.
    function test_RecoverStray_TakesOnlyASourceSlotsSurplus() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 owedByTwo = _getVaultStake(hotkey2, NETUID1);
        uint256 surplus = 4 ether;
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, owedByTwo + surplus);
        vault.syncBacking(TOKEN1);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, 0, hotkey2);

        assertEq(_getVaultStake(hotkey2, NETUID1), owedByTwo, "the source kept exactly what it owed");
        assertEq(_getVaultStake(hotkey1, NETUID1), surplus, "and only its surplus moved");

        vm.expectRevert(NothingToRecover.selector);
        vm.prank(bob);
        vault.recoverStray(TOKEN1, 0, hotkey2);
    }

    /// @dev Whatever the chain makes of the move, a source slot the recovery drew on has to come
    ///      out of it still covering its own expectation.
    function testFuzz_RecoverStray_LeavesEverySourceSlotCovered(uint256 rawSurplus) public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 owedByTwo = _getVaultStake(hotkey2, NETUID1);
        uint256 surplus = bound(rawSurplus, 1e7, 40 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, owedByTwo + surplus);
        vault.syncBacking(TOKEN1);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, 0, hotkey2);

        assertGe(_getVaultStake(hotkey2, NETUID1), vault.recordedSlots(TOKEN1)[1].tracked, "the source kept its own");
        assertEq(_getVaultStake(hotkey1, NETUID1), surplus, "and gave up only its surplus");
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

    /// @dev From the deadline the quote answers again on what the vault can locate, and the next
    ///      call that moves the position anchors the record to it. Nothing else has to be called.
    function test_AtTheDeadline_TheReducedHoldingBecomesPublishable() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);

        vm.expectPartialRevert(BackingShortfall.selector);
        lens.totalStake(TOKEN1);
        uint256 located = lens.locatedStake(TOKEN1);

        vm.warp(lens.frozenUntil(TOKEN1));
        assertEq(lens.totalStake(TOKEN1), located, "the quote answers on what is there");

        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, hotkey1, owed, 0);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice));

        assertTrue(lens.isBackingIntact(TOKEN1), "the write anchored the record with no finalizer");
        assertEq(lens.frozenUntil(TOKEN1), 0, "and left no clock running");
    }

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
}
