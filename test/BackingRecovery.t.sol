// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { stdError } from "forge-std/Test.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import {
    BackingIntact,
    BackingShortfall,
    HotkeyClaimedTwice,
    NoOpenDestination,
    NothingStrayUnder,
    NothingToUnwrap,
    SubnetInDissolutionBlackoutPeriod
} from "src/VaultErrors.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { MockSubnetPrecompile } from "./mocks/MockSubnetPrecompile.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { SUBNET_PRECOMPILE } from "src/interfaces/ISubnet.sol";

/// @dev Covers getting a position back once the vault has lost sight of its alpha: anyone pointing
///      it at the key that holds it, and a loss nobody can find running out its window.
contract BackingRecoveryTest is AlphaVaultTestBase {
    // -------------------- Recovery by naming where the alpha went ----------------

    /// @dev Recovery needs nobody's signature. The alpha sits under the vault's own coldkey, so
    ///      recognising the key that holds it can only raise the located total - which is why
    ///      anyone may do it, the moment they find it.
    function test_RecoverStray_ClearsTheShortfallWithoutAQuorum() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);
        assertFalse(lens.isBackingIntact(TOKEN1), "the loss is visible first");

        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingRecovered(TOKEN1, hotkey4, _getVaultStake(hotkey4, NETUID1));
        vm.prank(bob);
        vault.recoverStray(TOKEN1, 0, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "the found key accounts for the loss");
        assertApproxEqAbs(lens.totalStake(TOKEN1), 30 ether, 0.01 ether, "backing whole after recovery");
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey4, "the slot points at where its alpha is");
    }

    /// @dev A rotation leaves a fresh nonce standing until something settles. It must not double as
    ///      consent for a loss that happens afterwards and lands nowhere the attesters named.
    function test_RotationThenLaterLoss_IsNotExcused() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        // Only now does the backing leave, down a trail the one-hop resolver cannot walk.
        _buildSwapTrail(NETUID1, hotkey1, 2);

        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev Naming a key holding part of the loss explains part of it, which is not an explanation.
    function test_PartiallyNamedLoss_IsNotExcused() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 lost = _getVaultStake(hotkey1, NETUID1);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, lost / 2);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev Settling spends the attestation, so one signature cannot excuse a later, separate loss.
    function test_SettledAttestation_CannotExcuseTheNextLoss() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vault.rebalance(NETUID1);

        _simulateOffVaultSwap(NETUID1, hotkey4, hotkey5);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    function test_RevertWhen_RecoveringOntoAKeyHoldingNothing() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        vm.expectPartialRevert(NothingStrayUnder.selector);
        vault.recoverStray(TOKEN1, 0, hotkey5);
    }

    function test_RevertWhen_RecoveringOntoAKeyAnotherSlotHolds() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        vm.expectPartialRevert(HotkeyClaimedTwice.selector);
        vault.recoverStray(TOKEN1, 0, hotkey2);
    }

    /// @dev A slot that is not short has nothing to recover, so pointing it elsewhere would move
    ///      backing between slots rather than find any.
    function test_RevertWhen_RecoveringOntoAHealthySlot() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        vm.expectRevert(BackingIntact.selector);
        vault.recoverStray(TOKEN1, 1, hotkey4);
    }

    /// @dev The key has to cover what the slot is owed. A partial find leaves the position short,
    ///      and accepting it would report the rest as backing that is not there.
    function test_RevertWhen_TheFoundKeyDoesNotCoverTheSlot() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, owed / 2);

        vm.expectPartialRevert(NothingStrayUnder.selector);
        vault.recoverStray(TOKEN1, 0, hotkey4);
    }

    // -------------------- Recovery by running out the window ---------------------

    /// @dev Declaring the loss touches nothing but the clock. It starts a window in which anyone who
    ///      can still find the alpha may say so, and only once that runs out does the next call
    ///      write the loss off and let deposits back in. Holders were never shut out: the exit works
    ///      before the window, during it and after it.
    function test_DeclaredShortfall_ReopensATokenNobodyCanAccountFor() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice));

        assertGt(lens.depositsOpenFrom(TOKEN1), block.timestamp, "the exit started the window");
        _simulateAlphaDepositHotkey(bob, NETUID1, 1 ether, hotkey2);
        vm.expectPartialRevert(BackingShortfall.selector);
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey2);

        vm.warp(lens.depositsOpenFrom(TOKEN1));
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey2);
        assertGt(vault.balanceOf(bob, TOKEN1), 0, "deposits resume once the window is out");
    }

    /// @dev Nobody has to be transacting for the clock to start. A token nothing else touches would
    ///      otherwise sit shut for good, so anyone may put the loss on file.
    function test_DeclareShortfall_StartsTheWindowWithoutAQuorum() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);

        vm.prank(bob);
        vault.declareShortfall(TOKEN1);

        assertEq(
            lens.depositsOpenFrom(TOKEN1), block.timestamp + VaultReads.RECOVERY_WINDOW, "the window runs from here"
        );
        assertFalse(lens.isBackingIntact(TOKEN1), "and the loss still stands until it is out");
    }

    /// @dev A validator the attesters dropped while the token was shut still holds its stake. The
    ///      write-off must not lose it, and the ordinary path must still bring it home.
    function test_WriteOff_KeepsADroppedValidatorsStake() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 dropped = _getVaultStake(hotkey3, NETUID1);
        assertGt(dropped, 0, "the dropped validator must hold something to lose");

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, 0);
        _setValidators(NETUID1, _hotkeys(hotkey2, hotkey4), _weights(5000, 5000));
        uint256 survives = _vaultStakeAcross(_hotkeys(hotkey2, hotkey3), NETUID1);

        _writeOffShortfall(TOKEN1);
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "the dropped validator was emptied, not abandoned");
        assertApproxEqAbs(lens.totalStake(TOKEN1), survives, 0.01 ether, "and its stake came home");
        assertGe(survives, dropped, "which is more than the dropped validator was holding alone");
    }

    /// @dev Declaring settles nothing, but it owes the record the swaps its own plan followed.
    ///      Dropping them would leave the record pointing at the key the alpha departed and strand
    ///      what is still sitting under the one it reached.
    function test_DeclareShortfall_KeepsAFollowedSwapInTheRecord() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 moved = _getVaultStake(hotkey1, NETUID1);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, _subnetColdkey(NETUID1), NETUID1, 0);

        vault.declareShortfall(TOKEN1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].active, hotkey4, "the record kept the key the swap reached");
        assertEq(slots[0].tracked, moved, "and still expects the alpha sitting there");
        assertEq(_getVaultStake(hotkey4, NETUID1), moved, "which is where it is");
    }

    /// @dev Declaring says the clock is running, not that the alpha stopped existing. The record
    ///      therefore keeps what each slot is owed, which is what leaves a premature declaration
    ///      recoverable at all.
    function test_DeclareShortfall_KeepsTheRecordStanding() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        _buildSwapTrail(NETUID1, hotkey1, 2);

        vm.expectEmit(true, true, false, true, address(vault));
        emit ShortfallDeclared(TOKEN1, hotkey1, owed);
        vault.declareShortfall(TOKEN1);

        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, owed, "the slot still knows what it is owed");
        assertFalse(lens.isBackingIntact(TOKEN1), "and still reports itself short");
    }

    function test_RevertWhen_DeclaringOnAPositionThatAccountsForItself() public {
        _depositAndWrap(alice, NETUID1, 30 ether);

        vm.expectRevert(BackingIntact.selector);
        vault.declareShortfall(TOKEN1);
    }

    function test_RevertWhen_DeclaringAgainstATokenWithNoPosition() public {
        vm.expectRevert(NothingToUnwrap.selector);
        vault.declareShortfall(TOKEN1);
    }

    /// @dev Starting a clock persists followed swaps and settles nothing else, so it takes the same
    ///      guards as every other rail that writes to the record.
    function test_RevertWhen_DeclaringWhileTheSubnetIsDissolving() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        MockSubnetPrecompile(SUBNET_PRECOMPILE).setDissolving(uint16(NETUID1), true);

        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        vault.declareShortfall(TOKEN1);
    }

    /// @dev A shortfall deepening on the same key rides the window its slot already has: the clock
    ///      answers for the slot's whole expectation, fixed at the last settle, so nothing about
    ///      the gap's size can move a deadline in either direction.
    function test_ALossDeepeningUnderTheClock_SettlesOnTheOriginalDeadline() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);

        // Short by a hair: just past the slack the record forgives.
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, owed - 2e3);
        vault.declareShortfall(TOKEN1);
        uint256 deadline = lens.depositsOpenFrom(TOKEN1);

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        assertEq(lens.depositsOpenFrom(TOKEN1), deadline, "the deadline did not move");

        vm.warp(deadline - 1);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);

        vm.warp(deadline);
        vm.expectEmit(true, true, false, true, address(vault));
        emit ShortfallWrittenOff(TOKEN1, hotkey1, owed);
        vault.rebalance(NETUID1);
        assertTrue(lens.isBackingIntact(TOKEN1), "the whole slot settled with the window it had");
    }

    /// @dev The deadline is the whole mechanism, so it is worth pinning either side of rather than
    ///      only at the boundary every other test warps to.
    function testFuzz_WriteOff_FallsDueOnlyOnceTheWindowIsOut(uint256 offset) public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.declareShortfall(TOKEN1);
        uint256 deadline = lens.depositsOpenFrom(TOKEN1);

        uint256 at = bound(offset, deadline - VaultReads.RECOVERY_WINDOW, deadline + VaultReads.RECOVERY_WINDOW);
        vm.warp(at);

        if (at < deadline) {
            vm.expectPartialRevert(BackingShortfall.selector);
            vault.rebalance(NETUID1);
            assertFalse(lens.isBackingIntact(TOKEN1), "the loss still stands before the deadline");
        } else {
            vault.rebalance(NETUID1);
            assertTrue(lens.isBackingIntact(TOKEN1), "and settles from the deadline onwards");
        }
    }

    /// @dev The clock starts once per loss and is never restarted, or anyone could hold a token shut
    ///      past its deadline by re-declaring the same loss every couple of hours. Asking again is
    ///      allowed and does nothing: an exit may have got there first, and no caller should have to
    ///      know which.
    function test_DeclareShortfall_CannotPushTheDeadlineOut() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.declareShortfall(TOKEN1);
        uint256 deadline = lens.depositsOpenFrom(TOKEN1);

        vm.warp(block.timestamp + 1 hours);
        vault.declareShortfall(TOKEN1);
        assertEq(lens.depositsOpenFrom(TOKEN1), deadline, "the deadline did not move");
    }

    /// @dev Nor may the exits push it out, and they see the position far more often than anyone
    ///      calling in from outside.
    function test_ExitsDuringTheWindow_CannotPushTheDeadlineOut() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.declareShortfall(TOKEN1);
        uint256 deadline = lens.depositsOpenFrom(TOKEN1);

        for (uint256 i; i < 3; ++i) {
            vm.warp(block.timestamp + 30 minutes);
            vm.prank(alice);
            vault.unwrap(TOKEN1, shares / 20, _toSubstrate(alice));
        }

        assertEq(lens.depositsOpenFrom(TOKEN1), deadline, "the deadline stayed where the first sighting put it");
    }

    /// @dev The quote counts only what the vault can still locate, so while a loss stands it
    ///      understates the holding and steps back up the moment the alpha is found. Anything
    ///      valuing the token off it would be trading against a number that is right by accident,
    ///      so it refuses instead - and resumes once the record is whole again.
    function test_RevertWhen_QuotingATokenThatCannotAccountForItself() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);

        vm.expectPartialRevert(BackingShortfall.selector);
        lens.totalStake(TOKEN1);
        vm.expectPartialRevert(BackingShortfall.selector);
        lens.previewUnwrap(TOKEN1, shares / 4);
        vm.expectPartialRevert(BackingShortfall.selector);
        lens.sharePrice(TOKEN1);

        _writeOffShortfall(TOKEN1);
        vault.rebalance(NETUID1);

        (uint256 quoted,) = lens.previewUnwrap(TOKEN1, shares / 4);
        assertGt(quoted, 0, "the quote resumes on a record that adds up again");
    }

    /// @dev Refusing to value a position must not make it unreadable. The located figure is the
    ///      same number the quote would have given, named so that nobody reaches for it by
    ///      accident: it answers throughout, and agrees with `totalStake` once that one will speak.
    function test_LocatedStake_AnswersWhileTheQuoteRefuses() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 whole = lens.locatedStake(TOKEN1);
        assertEq(whole, lens.totalStake(TOKEN1), "they are the same number on a healthy position");

        _buildSwapTrail(NETUID1, hotkey1, 2);
        uint256 located = lens.locatedStake(TOKEN1);
        assertGt(located, 0, "the located figure still answers");
        assertLt(located, whole, "and is short by what the vault lost track of");

        _writeOffShortfall(TOKEN1);
        vault.rebalance(NETUID1);
        assertEq(lens.locatedStake(TOKEN1), lens.totalStake(TOKEN1), "and they agree again after");
    }

    /// @dev A loss on file may hold quotes and deposits shut, but it must never stand between a
    ///      holder and the door: both exit rails run throughout, whatever the clock says.
    function test_ExitDuringTheWindow_IsNotBlocked() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.declareShortfall(TOKEN1);
        assertGt(lens.depositsOpenFrom(TOKEN1), block.timestamp, "the window is running");

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice));
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);
    }

    /// @dev A loss that appears while another's window runs gets no free ride out of it: its own
    ///      slot has no clock until a write rail sees it, so the first call after the first
    ///      deadline refuses instead of writing both off together.
    function test_ALossAfterTheDeclaration_IsNotCoveredByIt() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.declareShortfall(TOKEN1);

        _buildSwapTrail(NETUID1, hotkey2, 2);
        assertEq(lens.depositsOpenFrom(TOKEN1), type(uint256).max, "a loss with no clock reports no opening");

        // Even long past the first deadline, the second loss has had no window of its own.
        vm.warp(block.timestamp + VaultReads.RECOVERY_WINDOW);
        _simulateAlphaDepositHotkey(bob, NETUID1, 1 ether, hotkey3);
        vm.prank(bob);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.wrap(NETUID1, hotkey3);

        _writeOffShortfall(TOKEN1);
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey3);
        assertGt(vault.balanceOf(bob, TOKEN1), 0, "a window covering both losses lets it in");
    }

    /// @dev The write-off is taken by whichever settling rail runs first. Keyed to deposits alone,
    ///      the permissionless maintenance rail would go on refusing a loss whose window was long
    ///      out, with nothing short of a deposit able to clear it.
    function test_RebalanceAfterTheWindow_WritesTheLossOff() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.declareShortfall(TOKEN1);

        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);

        vm.warp(lens.depositsOpenFrom(TOKEN1));
        vm.expectEmit(true, true, false, true, address(vault));
        emit ShortfallWrittenOff(TOKEN1, hotkey1, owed);
        vault.rebalance(NETUID1);

        assertTrue(lens.isBackingIntact(TOKEN1), "the settle took the write-off");
        assertEq(lens.depositsOpenFrom(TOKEN1), 0, "and the token is ordinary again");
    }

    /// @dev An exit never books a loss - the write-off is a settling rail's to take, and rebalance
    ///      is open to anyone. Quotes and deposits stop refusing at the deadline either way, so
    ///      leaving the record standing costs nothing and keeps the loss recoverable meanwhile.
    function test_ExitAfterTheWindow_LeavesTheRecordStanding() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.declareShortfall(TOKEN1);

        vm.warp(lens.depositsOpenFrom(TOKEN1));
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice));

        assertFalse(lens.isBackingIntact(TOKEN1), "the exit booked nothing off");
        assertGt(lens.totalStake(TOKEN1), 0, "while the quote answers from the deadline");

        vault.rebalance(NETUID1);
        assertTrue(lens.isBackingIntact(TOKEN1), "the settling rail takes the write-off");
        assertEq(lens.depositsOpenFrom(TOKEN1), 0, "and leaves no clock running");
    }

    /// @dev The TAO rail is an exit like any other: it pays out past the deadline and books
    ///      nothing off, leaving the settle to a refusing rail.
    function test_UnwrapForTaoAfterTheWindow_LeavesTheRecordStanding() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.declareShortfall(TOKEN1);

        vm.warp(lens.depositsOpenFrom(TOKEN1));
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);

        assertFalse(lens.isBackingIntact(TOKEN1), "the exit booked nothing off");

        vault.rebalance(NETUID1);
        assertTrue(lens.isBackingIntact(TOKEN1), "the settling rail takes the write-off");
    }

    /// @dev Declaring is refused once someone has recovered the alpha, so a token that no longer
    ///      needs a window cannot be handed one.
    function test_RevertWhen_DeclaringAfterTheAlphaIsFound() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        vault.recoverStray(TOKEN1, 0, hotkey4);

        vm.expectRevert(BackingIntact.selector);
        vault.declareShortfall(TOKEN1);
    }

    /// @dev And the other direction: a declaration that turns out to be premature is undone by
    ///      anyone who finds the alpha, which also ends the window it started.
    function test_RecoverStray_UndoesAPrematureDeclaration() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);
        uint256 whole = 30 ether;

        vault.declareShortfall(TOKEN1);
        assertGt(lens.depositsOpenFrom(TOKEN1), block.timestamp, "the window is running");

        vm.prank(bob);
        vault.recoverStray(TOKEN1, 0, hotkey4);

        assertEq(lens.depositsOpenFrom(TOKEN1), 0, "finding the alpha ends the window");
        assertTrue(lens.isBackingIntact(TOKEN1), "and restores the record");
        assertApproxEqAbs(lens.totalStake(TOKEN1), whole, 0.01 ether, "with the backing whole again");
    }

    /// @dev A window is spent by the position ceasing to show the loss it was granted for, however
    ///      that happens. Left standing after the alpha came back on its own, an expired clock would
    ///      sit there and wave the next identical loss straight through.
    function test_ALossRepairingItself_SpendsTheDeclaration() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 tracked = _getVaultStake(hotkey1, NETUID1);

        bytes32 tip = _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.declareShortfall(TOKEN1);

        // The alpha finds its own way back to the recorded key, so nobody calls recoverStray and
        // nothing but the ordinary maintenance rail ever observes the repair.
        _simulateOffVaultSwap(NETUID1, tip, hotkey1);
        vm.warp(lens.depositsOpenFrom(TOKEN1));
        vault.rebalance(NETUID1);

        assertTrue(lens.isBackingIntact(TOKEN1), "the position accounts for itself again");
        assertEq(lens.depositsOpenFrom(TOKEN1), 0, "and the window it was granted is spent");

        // Same slot, same key, same amount: a clock left running would cover this exactly, and
        // its deadline is long gone.
        assertEq(_getVaultStake(hotkey1, NETUID1), tracked, "the recurrence is identical to the first loss");
        _buildSwapTrail(NETUID1, hotkey1, 2);

        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);

        _simulateAlphaDepositHotkey(bob, NETUID1, 1 ether, hotkey3);
        vm.prank(bob);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.wrap(NETUID1, hotkey3);
    }

    /// @dev Each slot's loss runs its own clock: a second loss neither restarts the first slot's
    ///      window nor rides it.
    function test_ASecondLoss_LeavesTheFirstClockAlone() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 owedFirst = _getVaultStake(hotkey1, NETUID1);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.declareShortfall(TOKEN1);
        uint256 firstDeadline = lens.depositsOpenFrom(TOKEN1);

        vm.warp(block.timestamp + 1 hours);
        uint256 owedSecond = _getVaultStake(hotkey2, NETUID1);
        _buildSwapTrail(NETUID1, hotkey2, 2);
        vault.declareShortfall(TOKEN1);

        assertEq(
            vault.recordedSlots(TOKEN1)[0].shortSince + VaultReads.RECOVERY_WINDOW,
            firstDeadline,
            "the first clock did not move"
        );
        assertEq(lens.depositsOpenFrom(TOKEN1), firstDeadline + 1 hours, "and the second got its own");

        vm.warp(firstDeadline);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);

        vm.warp(firstDeadline + 1 hours);
        vm.expectEmit(true, true, false, true, address(vault));
        emit ShortfallWrittenOff(TOKEN1, hotkey1, owedFirst);
        vm.expectEmit(true, true, false, true, address(vault));
        emit ShortfallWrittenOff(TOKEN1, hotkey2, owedSecond);
        vault.rebalance(NETUID1);
        assertTrue(lens.isBackingIntact(TOKEN1), "both settle once the later window is out");
    }

    /// @dev The vault selling residue off a short slot's key pays an exit, not a deeper loss, so
    ///      the slot's clock never notices.
    function test_ExitsDrainingAShortSlotsResidual_CannotPushTheDeadlineOut() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, owed / 2);
        vault.declareShortfall(TOKEN1);
        uint256 deadline = lens.depositsOpenFrom(TOKEN1);
        uint256 residual = _getVaultStake(hotkey1, NETUID1);

        for (uint256 i; i < 3; ++i) {
            vm.warp(block.timestamp + 1 hours);
            vm.prank(alice);
            vault.unwrapForTao(TOKEN1, shares / 10, 0);
        }

        assertLt(_getVaultStake(hotkey1, NETUID1), residual, "the exits sold from the short key");
        assertEq(lens.depositsOpenFrom(TOKEN1), deadline, "and its deadline never moved");
    }

    /// @dev The lost key no longer exists on the chain, so nothing may aim stake at it - the
    ///      write-off reopens the token anyway, on every rail.
    function test_WriteOff_ReopensWhenTheLostKeyNoLongerExists() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        _writeOffShortfall(TOKEN1);
        vault.rebalance(NETUID1);
        assertTrue(lens.isBackingIntact(TOKEN1), "the settle went through without touching the dead key");

        _simulateAlphaDepositHotkey(bob, NETUID1, 1 ether, hotkey2);
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey2);
        assertGt(vault.balanceOf(bob, TOKEN1), 0, "deposits reopen");

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice));
    }

    /// @dev A key the record cannot account for takes no new stake: refilled, its loss would read
    ///      as repaired without the alpha ever being found.
    function test_Exit_NeverRefillsAShortSlotsKey() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        vault.declareShortfall(TOKEN1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice));

        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing landed back on the short key");
        assertFalse(lens.isBackingIntact(TOKEN1), "so the loss still shows");
    }

    /// @dev The window is a floor, not a cliff: until a settling rail books the loss, the record
    ///      still knows what the slot is owed and anyone may still point the vault at it.
    function test_RecoverStray_StillAnswersAfterTheDeadline() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);
        vault.declareShortfall(TOKEN1);

        vm.warp(lens.depositsOpenFrom(TOKEN1) + 2 days);
        vm.prank(bob);
        vault.recoverStray(TOKEN1, 0, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "the alpha came home in the overtime");
        assertApproxEqAbs(lens.totalStake(TOKEN1), 30 ether, 0.01 ether, "and the backing is whole again");
    }

    /// @dev Recovery onto an attested key is a genuine answer even while the slot's own validator
    ///      stays attested: the assignment routes each name through the slot answering for it, so
    ///      the recovered key backs one expectation and every rail keeps working.
    function test_RecoverStray_AcceptsAnAttestedKeyNoSlotAnswersFor() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        _setValidators(
            NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, owed);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, 0, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "the named key accounts for the loss");
        vault.rebalance(NETUID1);
        uint256 quarter = vault.balanceOf(alice, TOKEN1) / 4;
        vm.prank(alice);
        vault.unwrap(TOKEN1, quarter, _toSubstrate(alice));
    }

    /// @dev The reviewer's chained-swap catch-up: slots (A - B), (B - D), (C, C) are a healthy
    ///      record, and an attestation naming B, D and C must resolve one-to-one onto B, D and C
    ///      rather than reading B through its old identity and colliding with D.
    function test_EffectiveSet_ResolvesAChainedSwapCatchUpOneToOne() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey2, hotkey4);
        vault.rebalance(NETUID1);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey2);
        vault.rebalance(NETUID1);

        _setValidators(
            NETUID1, _hotkeys(hotkey2, hotkey4, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );

        vault.rebalance(NETUID1);
        _simulateAlphaDepositHotkey(bob, NETUID1, 1 ether, hotkey2);
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey2);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice));
        assertApproxEqAbs(lens.totalStake(TOKEN1), 31 ether - (31 ether / 4), 0.4 ether, "the position stayed whole");
    }

    /// @dev Recovery onto an attested name whose own slot moved on: with slots (A, A) short,
    ///      (B - D) and (C, C), the alpha that left A sits under attested B, which nothing
    ///      answers for - naming it heals the record in place.
    function test_RecoverStray_AcceptsAnAttestedNameWhoseSlotMovedOn() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey2, hotkey4);
        vault.rebalance(NETUID1);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey2);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, 0, hotkey2);

        assertTrue(lens.isBackingIntact(TOKEN1), "the moved-on name accounts for the loss");
        assertApproxEqAbs(lens.totalStake(TOKEN1), 30 ether, 0.01 ether, "and the backing is whole");
        vault.rebalance(NETUID1);
    }

    /// @dev When the attesters have replaced the swapped validator with the very key holding its
    ///      alpha, naming that key is the common way home and must answer.
    function test_RecoverStray_AcceptsTheAttestersReplacementKey() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );

        vm.prank(bob);
        vault.recoverStray(TOKEN1, 0, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "the replacement key accounts for the loss");
        assertApproxEqAbs(lens.totalStake(TOKEN1), 30 ether, 0.01 ether, "and the backing is whole");
    }

    function test_RevertWhen_RecoveringWithASlotIndexOutOfRange() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);

        vm.expectRevert(stdError.indexOOBError);
        vault.recoverStray(TOKEN1, 3, hotkey4);
    }

    /// @dev With no attested key able to take stake, consolidating would park the pile where the
    ///      record is about to forget it, so the alpha rail refuses; the TAO rail still exits.
    function test_RevertWhen_NoAttestedKeyCanTakeTheConsolidatedStake() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _setValidators(NETUID1, _hotkeys(hotkey4, hotkey5), _weights(5000, 5000));
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey5, true);

        vm.prank(alice);
        vm.expectRevert(NoOpenDestination.selector);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice));

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);
    }

    /// @dev The reported reopening is always the latest clock among the slots still missing.
    function testFuzz_DepositsOpenFrom_ReportsTheLatestClock(uint256 gap) public {
        gap = bound(gap, 1, VaultReads.RECOVERY_WINDOW - 1);
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.declareShortfall(TOKEN1);
        uint256 firstDeadline = lens.depositsOpenFrom(TOKEN1);

        vm.warp(block.timestamp + gap);
        _buildSwapTrail(NETUID1, hotkey2, 2);
        vault.declareShortfall(TOKEN1);

        assertEq(
            lens.depositsOpenFrom(TOKEN1), block.timestamp + VaultReads.RECOVERY_WINDOW, "the latest clock governs"
        );
        assertGt(lens.depositsOpenFrom(TOKEN1), firstDeadline, "and it postdates the first");

        vm.warp(lens.depositsOpenFrom(TOKEN1));
        vault.rebalance(NETUID1);
        assertTrue(lens.isBackingIntact(TOKEN1), "both windows have run by the later deadline");
    }

    /// @dev A write-off must not orphan balance still sitting on a key the rewrite forgets: the
    ///      settle rolls it onto the attested set before the record moves on.
    function test_WriteOff_CarriesARotatedResidualOntoTheAttestedSet() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, owed / 2);
        uint256 located = lens.locatedStake(TOKEN1);

        _setValidators(NETUID1, _hotkeys(hotkey2, hotkey3), _weights(5000, 5000));
        _writeOffShortfall(TOKEN1);
        vault.rebalance(NETUID1);

        assertTrue(lens.isBackingIntact(TOKEN1), "the record is whole again");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing stayed on the forgotten key");
        assertEq(lens.totalStake(TOKEN1), located, "and nothing the vault could see was dropped");
    }

    /// @dev The alpha rail prices an exit over the balances it may actually move: a distrusted
    ///      key's residual is not among them, so the burn matches the delivery exactly and the
    ///      residual stays counted for the holders who remain.
    function test_Unwrap_PricesOverReachableBalances() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, owed / 2);
        vault.declareShortfall(TOKEN1);
        uint256 located = lens.locatedStake(TOKEN1);
        uint256 reachable = located - owed / 2;

        vm.prank(alice);
        vault.unwrap(TOKEN1, (shares * 4) / 5, _toSubstrate(alice));

        uint256 received;
        bytes32[] memory keys = _hotkeys(hotkey1, hotkey2, hotkey3);
        for (uint256 i; i < keys.length; ++i) {
            received += _getStake(keys[i], alice, NETUID1);
        }
        assertApproxEqRel(received, (reachable * 4) / 5, 0.02e18, "the burn matches the delivery");
        assertEq(_getVaultStake(hotkey1, NETUID1), owed / 2, "the distrusted key was left untouched");
        assertEq(lens.locatedStake(TOKEN1), located - received, "what stayed still counts the residual");
    }

    /// @dev A deposit whose chosen key the chain erased still lands: the mailbox follows its own
    ///      successor trail to find the alpha, and the vault settles it on the first attested key
    ///      that can take stake.
    function test_Wrap_FollowsTheMailboxTrailAndLandsOnAnOpenKey() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);
        _writeOffShortfall(TOKEN1);

        address mailbox = vault.getDepositAddress(bob, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey5);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey5, _toSubstrate(mailbox), NETUID1, 1 ether);
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey1);

        assertGt(vault.balanceOf(bob, TOKEN1), 0, "the deposit landed");
        assertEq(_getStakeForColdkey(hotkey5, _toSubstrate(mailbox), NETUID1), 0, "the mailbox was drained");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "and nothing was aimed at the erased key");
    }

    /// @dev A follow onto a key the attesters already list swaps places with that key's own union
    ///      entry: the total must stand, since a reordering of the sum's terms changes nothing.
    function test_TotalStake_CountsAFollowOntoAnAttestedKeyOnce() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        assertApproxEqAbs(lens.totalStake(TOKEN1), 30 ether, 0.01 ether, "the followed balance is counted once");
        uint256 half = vault.balanceOf(alice, TOKEN1) / 2;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, half, 0);
        assertApproxEqAbs(lens.locatedStake(TOKEN1), 15 ether, 0.5 ether, "the exit paid the honest half");
    }

    /// @dev The consolidation roll may draw from a distrusted key but never rest on one: with the
    ///      richest open key elected as the roller, a pulled balance cannot land on a key whose
    ///      standing loss it would silently repair.
    function test_Consolidation_NeverLandsPulledStakeOnAStandingLoss() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 shortHold = _getVaultStake(hotkey1, NETUID1) / 2;
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, shortHold);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, coldkey, NETUID1, shortHold / 2);
        vault.declareShortfall(TOKEN1);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));

        uint256 tenth = vault.balanceOf(alice, TOKEN1) / 10;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, tenth, 0);
        tenth = vault.balanceOf(alice, TOKEN1) / 10;
        vm.prank(alice);
        vault.unwrap(TOKEN1, tenth, _toSubstrate(alice));

        assertLe(_getVaultStake(hotkey1, NETUID1), shortHold, "the standing loss's key received nothing");
    }

    /// @dev A deposit staked toward the attested name itself still lands after the record followed
    ///      that validator's stake elsewhere: the intake falls back from the effective key to the
    ///      name the caller chose.
    function test_Wrap_ReadsTheChosenNameWhenTheEffectiveKeyHoldsNothing() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        _simulateAlphaDepositHotkey(bob, NETUID1, 1 ether, hotkey1);
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey1);

        assertGt(vault.balanceOf(bob, TOKEN1), 0, "the deposit landed off the chosen name");
    }

    /// @dev Successor edges chain rather than rewrite, so a deposit that slept through two swaps
    ///      sits two edges away; the mailbox walks the trail to it.
    function test_Wrap_WalksAChainedMailboxTrail() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        address mailbox = vault.getDepositAddress(bob, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey4, NETUID1, hotkey5);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey5, _toSubstrate(mailbox), NETUID1, 1 ether);

        vm.prank(bob);
        vault.wrap(NETUID1, hotkey1);

        assertGt(vault.balanceOf(bob, TOKEN1), 0, "the deposit landed from two edges away");
        assertEq(_getStakeForColdkey(hotkey5, _toSubstrate(mailbox), NETUID1), 0, "and the mailbox was drained");
    }

    /// @dev Recovery carries the departing key's residual along, so nothing the record can see
    ///      today becomes invisible tomorrow.
    function test_RecoverStray_CarriesTheOldKeysResidualAlong() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, owed / 3);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, owed);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, 0, hotkey4);

        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "the departing key was drained");
        assertEq(_getVaultStake(hotkey4, NETUID1), owed + owed / 3, "its residual rode along");
        assertApproxEqAbs(lens.totalStake(TOKEN1), 30 ether + owed / 3, 0.01 ether, "and stays counted");
    }
}
