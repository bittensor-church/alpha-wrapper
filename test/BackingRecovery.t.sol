// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

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
        assertFalse(vault.isBackingIntact(TOKEN1), "the loss is visible first");

        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingRecovered(TOKEN1, hotkey4, _getVaultStake(hotkey4, NETUID1));
        vm.prank(bob);
        vault.recoverStray(TOKEN1, 0, hotkey4);

        assertTrue(vault.isBackingIntact(TOKEN1), "the found key accounts for the loss");
        assertApproxEqAbs(vault.totalStake(TOKEN1), 30 ether, 0.01 ether, "backing whole after recovery");
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

        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
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
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
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
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    function test_RevertWhen_RecoveringOntoAKeyHoldingNothing() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        vm.expectPartialRevert(AlphaVault.NothingStrayUnder.selector);
        vault.recoverStray(TOKEN1, 0, hotkey5);
    }

    function test_RevertWhen_RecoveringOntoAKeyAnotherSlotHolds() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        vm.expectPartialRevert(AlphaVault.HotkeyClaimedTwice.selector);
        vault.recoverStray(TOKEN1, 0, hotkey2);
    }

    /// @dev A slot that is not short has nothing to recover, so pointing it elsewhere would move
    ///      backing between slots rather than find any.
    function test_RevertWhen_RecoveringOntoAHealthySlot() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        vm.expectRevert(AlphaVault.BackingIntact.selector);
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

        vm.expectPartialRevert(AlphaVault.NothingStrayUnder.selector);
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

        assertGt(vault.depositsOpenFrom(TOKEN1), block.timestamp, "the exit started the window");
        _simulateAlphaDeposit(bob, NETUID1, 1 ether);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey1);

        vm.warp(vault.depositsOpenFrom(TOKEN1));
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey1);
        assertGt(vault.balanceOf(bob, TOKEN1), 0, "deposits resume once the window is out");
    }

    /// @dev Nobody has to be transacting for the clock to start. A token nothing else touches would
    ///      otherwise sit shut for good, so anyone may put the loss on file.
    function test_DeclareShortfall_StartsTheWindowWithoutAQuorum() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);

        vm.prank(bob);
        vault.declareShortfall(TOKEN1);

        assertEq(vault.depositsOpenFrom(TOKEN1), block.timestamp + 3 hours, "the window runs from here");
        assertFalse(vault.isBackingIntact(TOKEN1), "and the loss still stands until it is out");
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
        assertApproxEqAbs(vault.totalStake(TOKEN1), survives, 0.01 ether, "and its stake came home");
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

        AlphaVault.Slot[] memory slots = vault.recordedSlots(TOKEN1);
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
        bytes32 shortfall = keccak256(abi.encodePacked(bytes32(0), uint256(0), hotkey1, owed));
        _buildSwapTrail(NETUID1, hotkey1, 2);
        uint256 located = _vaultStakeAcross(_hotkeys(hotkey2, hotkey3), NETUID1);

        vm.expectEmit(true, true, true, true, address(vault));
        emit ShortfallDeclared(TOKEN1, shortfall, located);
        vault.declareShortfall(TOKEN1);

        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, owed, "the slot still knows what it is owed");
        assertFalse(vault.isBackingIntact(TOKEN1), "and still reports itself short");
    }

    function test_RevertWhen_DeclaringOnAPositionThatAccountsForItself() public {
        _depositAndWrap(alice, NETUID1, 30 ether);

        vm.expectRevert(AlphaVault.BackingIntact.selector);
        vault.declareShortfall(TOKEN1);
    }

    /// @dev The clock starts once per loss and is never restarted, or anyone could hold a token shut
    ///      past its deadline by re-declaring the same loss every couple of hours. Asking again is
    ///      allowed and does nothing: an exit may have got there first, and no caller should have to
    ///      know which.
    function test_DeclareShortfall_CannotPushTheDeadlineOut() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.declareShortfall(TOKEN1);
        uint256 deadline = vault.depositsOpenFrom(TOKEN1);

        vm.warp(block.timestamp + 1 hours);
        vault.declareShortfall(TOKEN1);
        assertEq(vault.depositsOpenFrom(TOKEN1), deadline, "the deadline did not move");
    }

    /// @dev Nor may the exits push it out, and they see the position far more often than anyone
    ///      calling in from outside.
    function test_ExitsDuringTheWindow_CannotPushTheDeadlineOut() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.declareShortfall(TOKEN1);
        uint256 deadline = vault.depositsOpenFrom(TOKEN1);

        for (uint256 i; i < 3; ++i) {
            vm.warp(block.timestamp + 30 minutes);
            vm.prank(alice);
            vault.unwrap(TOKEN1, shares / 20, _toSubstrate(alice));
        }

        assertEq(vault.depositsOpenFrom(TOKEN1), deadline, "the deadline stayed where the first sighting put it");
    }

    /// @dev The quote counts only what the vault can still locate, so while a loss stands it
    ///      understates the holding and steps back up the moment the alpha is found. Anything
    ///      valuing the token off it would be trading against a number that is right by accident,
    ///      so it refuses instead - and resumes once the record is whole again.
    function test_RevertWhen_QuotingATokenThatCannotAccountForItself() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);

        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.totalStake(TOKEN1);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.previewUnwrap(TOKEN1, shares / 4);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.sharePrice(TOKEN1);

        _writeOffShortfall(TOKEN1);
        vault.rebalance(NETUID1);

        (uint256 quoted,) = vault.previewUnwrap(TOKEN1, shares / 4);
        assertGt(quoted, 0, "the quote resumes on a record that adds up again");
    }

    /// @dev Refusing to value a position must not make it unreadable. The located figure is the
    ///      same number the quote would have given, named so that nobody reaches for it by
    ///      accident: it answers throughout, and agrees with `totalStake` once that one will speak.
    function test_LocatedStake_AnswersWhileTheQuoteRefuses() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 whole = vault.locatedStake(TOKEN1);
        assertEq(whole, vault.totalStake(TOKEN1), "they are the same number on a healthy position");

        _buildSwapTrail(NETUID1, hotkey1, 2);
        uint256 located = vault.locatedStake(TOKEN1);
        assertGt(located, 0, "the located figure still answers");
        assertLt(located, whole, "and is short by what the vault lost track of");

        _writeOffShortfall(TOKEN1);
        vault.rebalance(NETUID1);
        assertEq(vault.locatedStake(TOKEN1), vault.totalStake(TOKEN1), "and they agree again after");
    }

    /// @dev A loss on file may hold quotes and deposits shut, but it must never stand between a
    ///      holder and the door: both exit rails run throughout, whatever the clock says.
    function test_ExitDuringTheWindow_IsNotBlocked() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.declareShortfall(TOKEN1);
        assertGt(vault.depositsOpenFrom(TOKEN1), block.timestamp, "the window is running");

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice));
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);
    }

    /// @dev A loss that appears while the window runs was never the one on file, and gets no free
    ///      ride out of it: the record stops matching, so the first call after the deadline refuses
    ///      instead of writing both off together. The second loss earns its own window.
    function test_ALossAfterTheDeclaration_IsNotCoveredByIt() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.declareShortfall(TOKEN1);

        _buildSwapTrail(NETUID1, hotkey2, 2);
        vm.warp(vault.depositsOpenFrom(TOKEN1));

        _simulateAlphaDepositHotkey(bob, NETUID1, 1 ether, hotkey3);
        vm.prank(bob);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
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
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.declareShortfall(TOKEN1);

        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);

        vm.warp(vault.depositsOpenFrom(TOKEN1));
        vault.rebalance(NETUID1);

        assertTrue(vault.isBackingIntact(TOKEN1), "the settle took the write-off");
        assertEq(vault.depositsOpenFrom(TOKEN1), 0, "and the token is ordinary again");
    }

    /// @dev So does an exit, which matters because an exit is the one thing a token in this state is
    ///      still guaranteed to see. Waiting on a deposit would keep quotes shut for a position
    ///      whose holders are doing nothing but leaving.
    function test_ExitAfterTheWindow_WritesTheLossOff() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.declareShortfall(TOKEN1);

        vm.warp(vault.depositsOpenFrom(TOKEN1));
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice));

        assertTrue(vault.isBackingIntact(TOKEN1), "the exit took the write-off");
        assertEq(vault.depositsOpenFrom(TOKEN1), 0, "and left no clock running");
        assertGt(vault.totalStake(TOKEN1), 0, "with the quote answering again");
    }

    /// @dev The TAO rail sells straight off rotated-out keys instead of consolidating, so it settles
    ///      by re-anchoring rather than rewriting the record. It must still take the write-off, or
    ///      the one exit that never touches the alpha rail could never clear a loss.
    function test_UnwrapForTaoAfterTheWindow_WritesTheLossOff() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.declareShortfall(TOKEN1);

        vm.warp(vault.depositsOpenFrom(TOKEN1));
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);

        assertTrue(vault.isBackingIntact(TOKEN1), "the TAO rail took the write-off too");
        assertEq(vault.depositsOpenFrom(TOKEN1), 0, "and left no clock running");
    }

    /// @dev Declaring is refused once someone has recovered the alpha, so a token that no longer
    ///      needs a window cannot be handed one.
    function test_RevertWhen_DeclaringAfterTheAlphaIsFound() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        vault.recoverStray(TOKEN1, 0, hotkey4);

        vm.expectRevert(AlphaVault.BackingIntact.selector);
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
        assertGt(vault.depositsOpenFrom(TOKEN1), block.timestamp, "the window is running");

        vm.prank(bob);
        vault.recoverStray(TOKEN1, 0, hotkey4);

        assertEq(vault.depositsOpenFrom(TOKEN1), 0, "finding the alpha ends the window");
        assertTrue(vault.isBackingIntact(TOKEN1), "and restores the record");
        assertApproxEqAbs(vault.totalStake(TOKEN1), whole, 0.01 ether, "with the backing whole again");
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
        vm.warp(vault.depositsOpenFrom(TOKEN1));
        vault.rebalance(NETUID1);

        assertTrue(vault.isBackingIntact(TOKEN1), "the position accounts for itself again");
        assertEq(vault.depositsOpenFrom(TOKEN1), 0, "and the window it was granted is spent");

        // Same slot, same key, same amount: a clock left running would still match this digest, and
        // its deadline is long gone.
        assertEq(_getVaultStake(hotkey1, NETUID1), tracked, "the recurrence is identical to the first loss");
        _buildSwapTrail(NETUID1, hotkey1, 2);

        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);

        _simulateAlphaDepositHotkey(bob, NETUID1, 1 ether, hotkey3);
        vm.prank(bob);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.wrap(NETUID1, hotkey3);
    }
}
