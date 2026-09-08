// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { AlphaVaultLens } from "src/AlphaVaultLens.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import {
    AttestedHotkeyRetired,
    BackingShortfall,
    BackingUnchanged,
    ConsolidationBelowFloor,
    NothingToRecover,
    NothingToUnwrap,
    Parked,
    RecoveryIncomplete,
    ShortfallOnFile,
    SlippageExceeded,
    SubnetInDissolutionBlackoutPeriod,
    ZeroAmount
} from "src/VaultErrors.sol";
import { MockStaking, CHAIN_MIN_STAKE } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// Tests how the vault handles alpha that goes missing: declaring the loss, parking what it can find
/// on its own hotkey, holding the parked position until the attesters publish again, and writing off
/// what never comes back.
contract BackingRecoveryTest is AlphaVaultTestBase {
    struct LateCohorts {
        uint256 incumbentShares;
        uint256 incumbentValueBefore;
        uint256 backingBefore;
        uint256 backingAfterWriteOff;
        uint256 finalizedWriteOff;
        uint256 recapitalizationDeposit;
        uint256 recapitalizerShares;
        uint256 recapitalizerValueBefore;
        uint256 supplyAtRecovery;
    }

    // --- Declaring and clearing a shortfall ---------------------------------------------------

    function test_SyncBacking_DeclaresTheShortfall() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 lost = _getVaultStake(hotkey1, NETUID1);
        _buildSwapTrail(NETUID1, hotkey1, 2);

        assertEq(lens.frozenUntil(TOKEN1), type(uint256).max, "short, but nothing is on file before the sync");
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingShortfallDeclared(TOKEN1, 30 ether, 30 ether - lost);
        vm.prank(bob);
        vault.syncBacking(TOKEN1);

        assertEq(lens.frozenUntil(TOKEN1), block.timestamp + vault.recoveryWindow(), "the window runs from here");
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, lost, "the slot still knows what it is owed");
        assertFalse(lens.isBackingIntact(TOKEN1), "and the token reports itself short");
    }

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

    function test_SyncBacking_KeepsAFollowedSwapInTheRecord() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 moved = _getVaultStake(hotkey1, NETUID1);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        vault.syncBacking(TOKEN1);

        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey4, "the record kept the key the swap reached");
        assertEq(lens.frozenUntil(TOKEN1), 0, "which is not a loss and needs no clock");
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey5);
        assertTrue(lens.isBackingIntact(TOKEN1), "so the next hop resolves from there");
        assertEq(_getVaultStake(hotkey5, NETUID1), moved, "where the alpha now is");
        vault.rebalance(NETUID1);
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

    function test_RevertWhen_SyncingARetiredTokenId() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _setRegBlock(NETUID1, 999);

        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
    }

    function test_RevertWhen_SyncingWhileTheSubnetIsDissolving() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        _setDissolving(NETUID1, true);

        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        vault.syncBacking(TOKEN1);
    }

    /// @dev Alpha that comes back on its own does not reopen the vault; only a sync takes the loss off file.
    function test_DeclaredShortfall_HoldsTheTokenShutUntilSynced() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 tip = _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);

        _simulateOffVaultSwap(NETUID1, tip, hotkey1);

        assertFalse(lens.isBackingIntact(TOKEN1), "the loss is still on file");
        vm.expectRevert(ShortfallOnFile.selector);
        vault.rebalance(NETUID1);
        vm.prank(alice);
        vm.expectRevert(ShortfallOnFile.selector);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingShortfallCleared(TOKEN1);
        vault.syncBacking(TOKEN1);

        assertTrue(lens.isBackingIntact(TOKEN1), "the sync took it off file");
        assertEq(lens.frozenUntil(TOKEN1), 0, "and stopped the clock");
        vault.rebalance(NETUID1);
    }

    /// @dev A cleared loss must not lend its expired clock to a later shortfall.
    function test_ClearedShortfall_StartsAFreshClockOnTheNextLoss() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 tip = _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);
        _simulateOffVaultSwap(NETUID1, tip, hotkey1);
        vault.syncBacking(TOKEN1);

        vm.warp(block.timestamp + 2 * vault.recoveryWindow());
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);

        assertEq(lens.frozenUntil(TOKEN1), block.timestamp + vault.recoveryWindow(), "the new loss gets a full window");
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
    }

    function test_SecondLoss_JoinsTheOpenClock() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);
        uint256 deadline = lens.frozenUntil(TOKEN1);

        vm.warp(block.timestamp + 1 hours);
        _buildSwapTrail(NETUID1, hotkey2, 2);
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
        assertEq(lens.frozenUntil(TOKEN1), deadline, "the later loss shares the clock");

        vm.warp(deadline);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), _getVaultStake(vault.parkingHotkey(), NETUID1), "both losses are written off");
    }

    // --- Recovery parks the position ------------------------------------------------------------

    function test_RecoverStray_ParksTheWholePosition() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        vault.syncBacking(TOKEN1);
        assertFalse(lens.isBackingIntact(TOKEN1), "the loss is visible first");

        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingParked(TOKEN1, 30 ether, registry.nonces(NETUID1));
        vm.prank(bob);
        vault.recoverStray(TOKEN1, _hotkeys(hotkey4));

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots.length, 1, "the record collapses to one slot");
        assertEq(slots[0].active, vault.parkingHotkey(), "on the parking hotkey");
        assertEq(slots[0].logical, vault.parkingHotkey(), "named by the parking hotkey");
        assertEq(slots[0].tracked, 30 ether, "expecting the whole position");
        assertEq(_parkedStake(NETUID1), 30 ether, "which is where the alpha is");
        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1) + _getVaultStake(hotkey4, NETUID1), 0, "nothing stays behind");
        assertTrue(lens.isBackingIntact(TOKEN1), "the position accounts for itself");
        assertEq(lens.frozenUntil(TOKEN1), 0, "the clock is gone");
        assertTrue(lens.awaitingAttestation(TOKEN1), "and it waits for the attesters");
        assertEq(lens.totalStake(TOKEN1), 30 ether, "backing whole after recovery");
    }

    function test_RecoverStray_ParksALossNobodyDeclared() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        assertEq(lens.frozenUntil(TOKEN1), type(uint256).max, "the loss is visible with no clock");

        vm.prank(bob);
        vault.recoverStray(TOKEN1, _hotkeys(hotkey4));

        assertTrue(lens.awaitingAttestation(TOKEN1), "the find parks without a sighting on file");
        assertEq(lens.totalStake(TOKEN1), 30 ether, "and the backing is whole");
    }

    function test_RecoverStray_ResolvesATwoHopTrail() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 tip = _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, _hotkeys(tip));

        assertEq(lens.totalStake(TOKEN1), 30 ether, "the watcher-supplied source accounts for the loss");
        assertEq(_getVaultStake(tip, NETUID1), 0, "and the trail's tip is empty");
    }

    function test_RecoverStray_CoversTwoLossesInOneCall() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _simulateOffVaultSwap(NETUID1, hotkey2, hotkey5);
        vault.syncBacking(TOKEN1);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, _hotkeys(hotkey4, hotkey5));

        assertEq(lens.totalStake(TOKEN1), 30 ether, "both lumps are home");
        assertEq(_parkedStake(NETUID1), 30 ether, "on the parking hotkey");
    }

    /// @dev Two attested slots swapped onto one key: nothing is missing, so no source is needed.
    function test_RecoverStray_ParksMergedSlotsWithoutASource() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _simulateOffVaultSwap(NETUID1, hotkey2, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey2, NETUID1, hotkey4);
        vault.syncBacking(TOKEN1);

        vault.recoverStray(TOKEN1, new bytes32[](0));

        assertEq(lens.totalStake(TOKEN1), 30 ether, "the merged balance is counted once");
        assertEq(_parkedStake(NETUID1), 30 ether, "on the parking hotkey");
    }

    function test_RecoverStray_BringsAnEmissionGrownLumpHome() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        uint256 lump = _getStakeForColdkey(hotkey4, coldkey, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, lump + 2 ether);
        vault.syncBacking(TOKEN1);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, _hotkeys(hotkey4));

        assertEq(lens.totalStake(TOKEN1), 32 ether, "the emissions came home with the lump");
    }

    /// @dev The chain refuses to move stake from a hotkey nobody owns; the vault claims it and moves on.
    function test_RecoverStray_ClaimsAnOwnerlessSourceForTheVault() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);
        vault.syncBacking(TOKEN1);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, _hotkeys(hotkey4));

        (bool exists, bytes32 owner) = MockStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkey4);
        assertTrue(exists, "the source has an owner again");
        assertEq(owner, _toSubstrate(address(vault)), "the vault, not the caller");
        assertEq(lens.totalStake(TOKEN1), 30 ether, "and the alpha is parked");
    }

    /// @dev Synthetic split backing exercises the coverage guard; ordinary swaps move whole entries.
    function test_RevertWhen_TheSourcesCannotCoverTheLoss() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, owed / 3);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey5, coldkey, NETUID1, owed);
        _simulateSameOwner(hotkey1, hotkey4);
        _simulateSameOwner(hotkey1, hotkey5);
        vault.syncBacking(TOKEN1);
        uint256 deadline = lens.frozenUntil(TOKEN1);

        vm.expectRevert(RecoveryIncomplete.selector);
        vm.prank(bob);
        vault.recoverStray(TOKEN1, _hotkeys(hotkey4));
        assertFalse(lens.isBackingIntact(TOKEN1), "the loss still stands");
        assertEq(_getStakeForColdkey(hotkey4, coldkey, NETUID1), owed / 3, "the alpha it refused stayed put");
        assertEq(lens.frozenUntil(TOKEN1), deadline, "and the deadline did not move");

        vm.prank(bob);
        vault.recoverStray(TOKEN1, _hotkeys(hotkey5));
        assertTrue(lens.isBackingIntact(TOKEN1), "the key covering the loss parks it");
        assertEq(lens.frozenUntil(TOKEN1), 0, "and the window ends");
    }

    function test_RevertWhen_RecoveringFromAKeyHoldingNothing() public {
        _depositAndWrap(alice, NETUID1, 30 ether);

        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, _hotkeys(hotkey5));
    }

    function test_RevertWhen_RecoveringFromTheSlotsOwnKey() public {
        _depositAndWrap(alice, NETUID1, 30 ether);

        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, _hotkeys(hotkey1));
    }

    function test_RevertWhen_RecoveringFromAKeyASlotResolvesTo() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        vm.expectRevert(NothingToRecover.selector);
        vm.prank(bob);
        vault.recoverStray(TOKEN1, _hotkeys(hotkey4));

        assertEq(_getVaultStake(hotkey4, NETUID1), owed, "the swapped-to key kept its alpha");
        assertTrue(lens.isBackingIntact(TOKEN1), "and the slot it answers for stayed covered");
    }

    function test_RevertWhen_RecoveringOnATokenWithNoSlots() public {
        vault.createSubnetProxy(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, _subnetColdkey(NETUID1), NETUID1, 5 ether);

        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, _hotkeys(hotkey4));
    }

    function test_RevertWhen_RecoveringOnARetiredTokenId() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _setRegBlock(NETUID1, 999);

        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, _hotkeys(hotkey4));
    }

    // --- Strays with nothing missing join the live backing -------------------------------------

    function test_RecoverStray_AnnexesADonationToTheFirstSlot() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, _subnetColdkey(NETUID1), NETUID1, 3 ether);
        _simulateHotkeyOwnerPresent(hotkey4);

        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingRecovered(TOKEN1, hotkey1, 3 ether);
        vault.recoverStray(TOKEN1, _hotkeys(hotkey4));

        assertEq(lens.totalStake(TOKEN1), 33 ether, "the donation is new backing");
        assertFalse(lens.awaitingAttestation(TOKEN1), "and nothing parked");
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, _getVaultStake(hotkey1, NETUID1), "booked on the first slot");
    }

    /// @dev The slot's own pile carries a stray the chain would refuse to move on its own.
    function test_RecoverStray_CarriesADustStrayHomeWithTheSlotsOwnPile() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, _subnetColdkey(NETUID1), NETUID1, 1);
        _simulateHotkeyOwnerPresent(hotkey4);

        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingRecovered(TOKEN1, hotkey1, 1);
        vault.recoverStray(TOKEN1, _hotkeys(hotkey4));

        assertEq(lens.totalStake(TOKEN1), 30 ether + 1, "the dust is home");
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "and nothing stays behind");
    }

    /// @dev A slot the resolver follows through a swap is re-anchored to the key that holds its stake.
    function test_RecoverStray_AnnexReanchorsASlotFollowedThroughASwap() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey5, _subnetColdkey(NETUID1), NETUID1, 3 ether);
        _simulateHotkeyOwnerPresent(hotkey5);
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey1, "the record still names the swapped key");

        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingRecovered(TOKEN1, hotkey4, 3 ether);
        vault.recoverStray(TOKEN1, _hotkeys(hotkey5));

        VaultReads.Slot memory slot = vault.recordedSlots(TOKEN1)[0];
        assertEq(slot.active, hotkey4, "the slot now points at the successor holding its stake");
        assertEq(slot.tracked, _getVaultStake(hotkey4, NETUID1), "and expects exactly what sits there");
        assertEq(_getVaultStake(hotkey5, NETUID1), 0, "the stray came home");
        assertEq(lens.totalStake(TOKEN1), 33 ether, "as new backing");
    }

    function test_RevertWhen_NeitherTheStrayNorTheSlotCanMoveTheirPile() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _plantVaultStakes(NETUID1, 1, 1, 1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, _subnetColdkey(NETUID1), NETUID1, 1);
        _simulateHotkeyOwnerPresent(hotkey4);

        vm.expectRevert(ConsolidationBelowFloor.selector);
        vault.recoverStray(TOKEN1, _hotkeys(hotkey4));
    }

    // --- Life on the parking hotkey --------------------------------------------------------------

    function _parkedPosition() private returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        vault.recoverStray(TOKEN1, _hotkeys(hotkey4));
        assertTrue(lens.awaitingAttestation(TOKEN1), "the fixture needs a parked position");
    }

    function test_ParkedPosition_RefusesDepositsAndAlignmentUntilANewAttestation() public {
        _parkedPosition();

        _simulateAlphaDeposit(bob, NETUID1, 1 ether);
        vm.expectRevert(Parked.selector);
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey1, 0);
        vm.expectRevert(Parked.selector);
        vault.rebalance(NETUID1);
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
    }

    function test_ParkedPosition_PaysAlphaExitsFromTheParkingHotkey() public {
        uint256 shares = _parkedPosition();
        bytes32 parking = vault.parkingHotkey();

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 1);

        assertEq(_getStake(parking, alice, NETUID1), 7.5 ether, "the exit is delivered on the parking hotkey");
        assertEq(_parkedStake(NETUID1), 22.5 ether, "leaving the rest parked");
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 22.5 ether, "with the record following");
        assertTrue(lens.awaitingAttestation(TOKEN1), "and the position still waiting");
    }

    function test_ParkedPosition_PaysTaoExitsFromTheParkingHotkey() public {
        uint256 shares = _parkedPosition();
        uint256 before = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);

        assertEq(alice.balance - before, _expectedTaoFor(15 ether), "the sale pays out");
        assertEq(_parkedStake(NETUID1), 15 ether, "from the parked balance");
        assertTrue(lens.awaitingAttestation(TOKEN1), "which stays parked");
    }

    function test_ParkedPosition_FullTaoExitReleasesIt() public {
        uint256 shares = _parkedPosition();

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(vault.totalSupply(TOKEN1), 0, "nothing outstanding");
        assertFalse(lens.awaitingAttestation(TOKEN1), "with no shares left there is nothing to hold");
        _depositAndWrap(bob, NETUID1, 5 ether);
        assertGe(lens.totalStake(TOKEN1), 5 ether, "and the next depositor starts a fresh position");
    }

    /// @dev Stake is keyed by hotkey, coldkey and netuid, so one parking hotkey serves every subnet.
    function test_ParkedPosition_LeavesOtherSubnetsUntouched() public {
        _parkedPosition();

        uint256 shares = _depositAndWrap(bob, NETUID2, 10 ether);
        vault.rebalance(NETUID2);
        vm.prank(bob);
        vault.unwrap(TOKEN2, shares / 2, _toSubstrate(bob), 0);

        assertFalse(lens.awaitingAttestation(TOKEN2), "the other subnet is not parked");
        assertEq(_parkedStake(NETUID2), 0, "and holds nothing on the parking hotkey");
        assertEq(_parkedStake(NETUID1), 30 ether, "while the parked subnet's balance did not move");
        assertTrue(lens.awaitingAttestation(TOKEN1), "and still waits for its own attesters");
    }

    function test_ParkedPosition_KeepsTransfersAndClaimsLive() public {
        uint256 shares = _parkedPosition();
        _donateToClone(vault.subnetClone(TOKEN1), 4 ether);

        vm.prank(alice);
        vault.safeTransferFrom(alice, bob, TOKEN1, shares / 2, "");
        assertEq(vault.balanceOf(bob, TOKEN1), shares / 2, "shares move while parked");

        assertGt(lens.claimableTaoOf(alice, TOKEN1), 0, "the TAO quote still answers");
        _claimQuotedAmount(alice, TOKEN1);
    }

    function test_ParkedPosition_FullExitRetiresEveryShare() public {
        uint256 shares = _parkedPosition();

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(vault.totalSupply(TOKEN1), 0, "nothing outstanding");
        assertLe(_parkedStake(NETUID1), 1e12, "and nothing of note left parked");
        assertGt(_getStake(vault.parkingHotkey(), alice, NETUID1), 29 ether, "the holder took the position");
        assertFalse(lens.awaitingAttestation(TOKEN1), "with no shares left there is nothing to hold");

        _depositAndWrap(bob, NETUID1, 5 ether);
        assertGe(lens.totalStake(TOKEN1), 5 ether, "and the next depositor starts a fresh position");
    }

    /// @dev A remainder below the vault's conservative floor stays on the books until a pile carries it.
    function test_WriteOff_KeepsARemainderItCannotMove() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 1e6);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, coldkey, NETUID1, 0);
        vault.syncBacking(TOKEN1);
        vm.warp(lens.frozenUntil(TOKEN1));

        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, 30 ether, 1e6);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingParked(TOKEN1, 1e6, registry.nonces(NETUID1));
        vault.syncBacking(TOKEN1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots.length, 2, "the parking slot and the remainder");
        assertEq(slots[1].active, hotkey1, "the remainder stays where the chain left it");
        assertEq(slots[1].tracked, 1e6, "and on the books");
        assertEq(lens.totalStake(TOKEN1), 1e6, "so the quote still counts it");
        assertTrue(lens.awaitingAttestation(TOKEN1), "while the position waits");

        _reattestCurrentSet(NETUID1);
        _depositAndWrap(bob, NETUID1, 5 ether);
        assertEq(lens.totalStake(TOKEN1), 5 ether + 1e6, "and the next deposit carries it along");
    }

    /// @dev The vault's stake on the parking hotkey is a nominator position the chain can sweep.
    function test_ParkedPosition_ThatGoesShort_IsWrittenOffAndPaysAgain() public {
        uint256 shares = _parkedPosition();
        MockStaking(STAKING_PRECOMPILE).setStake(vault.parkingHotkey(), _subnetColdkey(NETUID1), NETUID1, 20 ether);

        assertFalse(lens.isBackingIntact(TOKEN1), "the parked position is short");
        vm.prank(alice);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        vault.syncBacking(TOKEN1);
        vm.warp(lens.frozenUntil(TOKEN1));
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, 30 ether, 20 ether);
        vault.syncBacking(TOKEN1);

        assertTrue(lens.isBackingIntact(TOKEN1), "the write-off settles the position on what is left");
        assertTrue(lens.awaitingAttestation(TOKEN1), "still parked");
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);
        assertEq(_getStake(vault.parkingHotkey(), alice, NETUID1), 5 ether, "and paying exits again");
    }

    function test_NewAttestation_ReleasesTheParkedPosition() public {
        _parkedPosition();

        _reattestCurrentSet(NETUID1);
        assertFalse(lens.awaitingAttestation(TOKEN1), "the newer nonce lifts the hold");
        vault.rebalance(NETUID1);

        assertEq(_parkedStake(NETUID1), 0, "the parking hotkey is empty again");
        assertEq(vault.recordedSlots(TOKEN1).length, 3, "the record follows the attested set");
        assertEq(_getVaultStake(hotkey1, NETUID1), _weighted(30 ether, NETUID1_BPS_HK1), "spread by weight");
        assertEq(_getVaultStake(hotkey2, NETUID1), _weighted(30 ether, NETUID1_BPS_HK2), "spread by weight");
        assertEq(lens.totalStake(TOKEN1), 30 ether, "with nothing lost in the release");
        (, uint256 parkedAtNonce) = vault.recovery(TOKEN1);
        assertEq(parkedAtNonce, 0, "and the position is ordinary again");
    }

    function test_Wrap_ReleasesAParkedPositionAfterANewAttestation() public {
        _parkedPosition();
        _reattestCurrentSet(NETUID1);

        _simulateAlphaDepositHotkey(bob, NETUID1, 6 ether, hotkey2);
        _wrapHotkey(bob, NETUID1, hotkey2);

        assertGt(vault.balanceOf(bob, TOKEN1), 0, "the deposit landed");
        assertEq(_parkedStake(NETUID1), 0, "and the parked alpha moved onto the set with it");
        assertEq(lens.totalStake(TOKEN1), 36 ether, "backing whole across the release");
    }

    function test_ReplacingTheLostName_RoutesParkedAlphaToTheSuccessor() public {
        _parkedPosition();

        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing goes back to the lost name");
        assertEq(
            _getVaultStake(hotkey4, NETUID1), _weighted(30 ether, NETUID1_BPS_HK1), "its weight went to the successor"
        );
        assertEq(_parkedStake(NETUID1), 0, "and the parking hotkey is empty");
    }

    function test_LateFoundAlpha_JoinsTheParkedPosition() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _runOutRecoveryWindow(TOKEN1);
        assertTrue(lens.awaitingAttestation(TOKEN1), "the write-off parks what is left");
        uint256 parked = _parkedStake(NETUID1);

        vault.recoverStray(TOKEN1, _hotkeys(hotkey4));

        assertEq(
            _parkedStake(NETUID1), parked + _weighted(30 ether, NETUID1_BPS_HK1), "the find joins the parked alpha"
        );
        assertEq(lens.totalStake(TOKEN1), 30 ether, "and the backing is whole again");
    }

    // --- Writing a loss off ----------------------------------------------------------------------

    function test_WriteOff_ParksWhatIsLeft() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 lost = _getVaultStake(hotkey1, NETUID1);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);

        vm.warp(lens.frozenUntil(TOKEN1));
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, 30 ether, 30 ether - lost);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingParked(TOKEN1, 30 ether - lost, registry.nonces(NETUID1));
        vm.prank(bob);
        vault.syncBacking(TOKEN1);

        assertEq(lens.totalStake(TOKEN1), 30 ether - lost, "the quote answers on what is there");
        assertEq(_parkedStake(NETUID1), 30 ether - lost, "parked on the vault's hotkey");
        assertEq(lens.frozenUntil(TOKEN1), 0, "with no clock left running");
        assertTrue(lens.awaitingAttestation(TOKEN1), "waiting for the attesters");
    }

    function test_WriteOff_WithNothingLocatedParksAnEmptyPosition() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32[] memory recordedHotkeys = _hotkeys(hotkey1, hotkey2, hotkey3);
        for (uint256 i; i < recordedHotkeys.length; ++i) {
            _simulateOffVaultSwap(NETUID1, recordedHotkeys[i], keccak256(abi.encode("gone", i)));
        }
        _runOutRecoveryWindow(TOKEN1);

        assertEq(lens.totalStake(TOKEN1), 0, "nothing is left");
        (uint256 quote,) = lens.previewUnwrap(TOKEN1, shares);
        assertEq(quote, 0, "the shares quote zero alpha");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, 0));
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        assertEq(vault.balanceOf(alice, TOKEN1), 0, "a zero floor retires the shares");
    }

    function testFuzz_WriteOff_FallsDueOnlyOnceTheWindowIsOut(uint256 offset) public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);
        uint256 deadline = lens.frozenUntil(TOKEN1);

        uint256 at = bound(offset, deadline - vault.recoveryWindow(), deadline + vault.recoveryWindow());
        vm.warp(at);

        if (at < deadline) {
            vm.expectRevert(BackingUnchanged.selector);
            vault.syncBacking(TOKEN1);
            vm.expectRevert(ShortfallOnFile.selector);
            lens.totalStake(TOKEN1);
        } else {
            vault.syncBacking(TOKEN1);
            assertTrue(lens.awaitingAttestation(TOKEN1), "the loss is booked from the deadline on");
            assertGt(lens.totalStake(TOKEN1), 0, "and the quote answers on what is left");
        }
    }

    function test_PastTheDeadline_OnlySyncBackingBooksTheLoss() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);
        uint256 located = lens.locatedStake(TOKEN1);

        vm.warp(lens.frozenUntil(TOKEN1));
        vm.expectRevert(ShortfallOnFile.selector);
        lens.totalStake(TOKEN1);
        vm.expectRevert(ShortfallOnFile.selector);
        vault.rebalance(NETUID1);
        vm.prank(alice);
        vm.expectRevert(ShortfallOnFile.selector);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        vm.prank(bob);
        vault.syncBacking(TOKEN1);

        assertEq(lens.totalStake(TOKEN1), located, "the quote answers on what is there");
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);
    }

    function test_RecoveryWindow_SetAtDeploymentDrivesTheDeadline() public {
        (AlphaVault hourVault, AlphaVaultLens hourLens) = _deployVaultAndLens(address(registry), 1 hours);
        uint256 tokenId = hourVault.currentTokenId(NETUID1);
        address mailbox = hourVault.getDepositAddress(alice, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _toSubstrate(mailbox), NETUID1, 10 ether);
        vm.prank(alice);
        hourVault.wrap(NETUID1, hotkey1, 0);

        bytes32 coldkey = _toSubstrate(hourVault.subnetClone(tokenId));
        uint256 lump = MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, coldkey, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, lump);
        hourVault.syncBacking(tokenId);

        assertEq(hourLens.frozenUntil(tokenId), block.timestamp + 1 hours, "the deadline runs on the deployed window");
        vm.warp(block.timestamp + 1 hours);
        hourVault.syncBacking(tokenId);
        assertTrue(hourLens.awaitingAttestation(tokenId), "and the write-off falls due on it too");
    }

    // --- Who a late recovery belongs to --------------------------------------------------------

    function test_LateFoundAlpha_IsAWindfallForTheCurrentCohort() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 lost = _getVaultStake(hotkey1, NETUID1);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _runOutRecoveryWindow(TOKEN1);
        _reattestCurrentSet(NETUID1);
        vault.rebalance(NETUID1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice), 0);
        uint256 bobShares = _depositAndWrap(bob, NETUID1, 10 ether);
        uint256 navBefore = lens.totalStake(TOKEN1);

        vm.prank(alice);
        vault.recoverStray(TOKEN1, _hotkeys(hotkey4));

        assertEq(lens.totalStake(TOKEN1), navBefore + lost, "the find is new backing");
        (uint256 bobsAlpha,) = lens.previewUnwrap(TOKEN1, bobShares);
        assertGt(bobsAlpha, 10 ether, "and it belongs to whoever holds shares now");
        assertEq(vault.balanceOf(alice, TOKEN1), 0, "not to the cohort that bore the loss");
    }

    /// @dev No growth on hidden backing here. Partial-loss deposits exercise material cohort splits;
    ///      full-loss deposits are bounded below the virtual-rate supply cap.
    function testFuzz_LateRecovery_CannotDiluteIncumbentByMoreThanFinalizedWriteOff(
        uint256 incumbentDeposit,
        uint256 recapitalizationSeed,
        uint256 hiddenSlotCount
    ) public {
        incumbentDeposit = bound(incumbentDeposit, 30 ether, 1_000_000 ether);
        hiddenSlotCount = bound(hiddenSlotCount, 1, 3);

        LateCohorts memory cohorts = _openIncumbentCohort(incumbentDeposit);

        bytes32[] memory recordedHotkeys = _hotkeys(hotkey1, hotkey2, hotkey3);
        uint256 hidden;
        for (uint256 i; i < hiddenSlotCount; ++i) {
            hidden += _getVaultStake(recordedHotkeys[i], NETUID1);
            _simulateOffVaultSwap(NETUID1, recordedHotkeys[i], keccak256(abi.encode("stray", i)));
        }

        _runOutRecoveryWindow(TOKEN1);
        cohorts.backingAfterWriteOff = lens.totalStake(TOKEN1);
        cohorts.finalizedWriteOff = cohorts.backingBefore - cohorts.backingAfterWriteOff;
        assertEq(cohorts.finalizedWriteOff, hidden, "the finalized deficit is exactly the hidden principal");

        _reattestCurrentSet(NETUID1);
        cohorts.recapitalizationDeposit = cohorts.backingAfterWriteOff == 0
            ? bound(recapitalizationSeed, CHAIN_MIN_STAKE, 1e9)
            : bound(recapitalizationSeed, cohorts.backingAfterWriteOff / 4, cohorts.backingAfterWriteOff * 4);
        _addRecapitalizer(cohorts);
        for (uint256 i; i < hiddenSlotCount; ++i) {
            vm.prank(bob);
            vault.recoverStray(TOKEN1, _hotkeys(keccak256(abi.encode("stray", i))));
        }

        assertEq(
            lens.totalStake(TOKEN1),
            cohorts.backingBefore + cohorts.recapitalizationDeposit,
            "recovery restores only the written-off principal plus the new deposit"
        );

        uint256 recapitalizerRecoveryGain = _assertLateCohortOutcome(cohorts, cohorts.finalizedWriteOff);
        if (cohorts.backingAfterWriteOff == 0) {
            assertGe(
                recapitalizerRecoveryGain,
                cohorts.finalizedWriteOff - cohorts.finalizedWriteOff / 1_000_000,
                "a valid post-wipeout deposit captures nearly all of the recovered principal"
            );
        }
    }

    function test_LateAttestation_AdoptsWrittenOffAlphaForCurrentCohort() public {
        LateCohorts memory cohorts = _openIncumbentCohort(30 ether);

        bytes32 successor = keccak256(abi.encode("attested-successor"));
        uint256 hidden = _getVaultStake(hotkey1, NETUID1);
        _simulateOffVaultSwap(NETUID1, hotkey1, successor);
        _runOutRecoveryWindow(TOKEN1);
        cohorts.backingAfterWriteOff = lens.totalStake(TOKEN1);
        cohorts.finalizedWriteOff = cohorts.backingBefore - cohorts.backingAfterWriteOff;
        assertEq(cohorts.finalizedWriteOff, hidden, "the successor holds exactly the written-off principal");

        _reattestCurrentSet(NETUID1);
        cohorts.recapitalizationDeposit = cohorts.backingAfterWriteOff;
        _addRecapitalizer(cohorts);

        _setValidators(
            NETUID1, _hotkeys(successor, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vault.rebalance(NETUID1);

        assertEq(
            lens.totalStake(TOKEN1),
            cohorts.backingBefore + cohorts.recapitalizationDeposit,
            "settlement adopts the funded successor exactly once"
        );
        _assertLateCohortOutcome(cohorts, cohorts.finalizedWriteOff);
    }

    function _openIncumbentCohort(uint256 deposit) internal returns (LateCohorts memory cohorts) {
        cohorts.incumbentShares = _depositAndWrap(alice, NETUID1, deposit);
        cohorts.backingBefore = lens.totalStake(TOKEN1);
        (cohorts.incumbentValueBefore,) = lens.previewUnwrap(TOKEN1, cohorts.incumbentShares);
    }

    function _addRecapitalizer(LateCohorts memory cohorts) internal {
        cohorts.recapitalizerShares = _depositAndWrap(bob, NETUID1, cohorts.recapitalizationDeposit);
        (cohorts.recapitalizerValueBefore,) = lens.previewUnwrap(TOKEN1, cohorts.recapitalizerShares);
        cohorts.supplyAtRecovery = vault.totalSupply(TOKEN1);
    }

    function _assertLateCohortOutcome(LateCohorts memory cohorts, uint256 recovered)
        internal
        view
        returns (uint256 recapitalizerGain)
    {
        (uint256 incumbentValueAfter,) = lens.previewUnwrap(TOKEN1, cohorts.incumbentShares);
        assertLe(
            cohorts.incumbentValueBefore,
            incumbentValueAfter + cohorts.finalizedWriteOff,
            "incumbents cannot lose more than the finalized write-off"
        );

        (uint256 recapitalizerValueAfter,) = lens.previewUnwrap(TOKEN1, cohorts.recapitalizerShares);
        assertLe(
            recapitalizerValueAfter,
            cohorts.recapitalizationDeposit + recovered,
            "the recapitalizer cannot capture more than the balance that returned"
        );
        recapitalizerGain = recapitalizerValueAfter - cohorts.recapitalizerValueBefore;
        assertGe(
            recapitalizerGain,
            (recovered * cohorts.recapitalizerShares) / (cohorts.supplyAtRecovery + 1e9),
            "the late cohort receives its pro-rata share of the returned balance"
        );
    }

    // --- Names that answer to the wrong coldkey --------------------------------------------------

    function test_SquattedVacatedName_SendsAllocationToTheSuccessorInstead() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey5);
        _simulateSquatter(hotkey4);

        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "nothing goes to the squatted name");
        assertGt(_getVaultStake(hotkey5, NETUID1), 0, "its weight goes to the validator's successor");
    }

    function test_SquattedVacatedNameWithNoSuccessor_IsRetired() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        _simulateSquatter(hotkey4);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        vault.rebalance(NETUID1);
    }

    function test_OwnerlessFundedKey_RefusesAlignmentUntilReplaced() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.rebalance(NETUID1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        _setValidators(NETUID1, _hotkeys(hotkey2, hotkey3), _weights(5000, 5000));
        vault.rebalance(NETUID1);

        (, bytes32 owner) = MockStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkey1);
        assertEq(owner, _toSubstrate(address(vault)), "the vault claimed the ownerless key to roll it");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "and rolled its alpha onto the set");
        assertEq(lens.totalStake(TOKEN1), 30 ether, "losing nothing");
    }

    /// @dev A coldkey swap moves every hotkey of the validator to the new coldkey; the attesters confirm it.
    function test_ValidatorColdkeySwap_RetiresItsSlotUntilReattested() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        MockStaking(STAKING_PRECOMPILE).setHotkeyOwner(hotkey1, keccak256("the validator's new coldkey"));

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.rebalance(NETUID1);

        _reattestCurrentSet(NETUID1);
        vault.rebalance(NETUID1);
        assertEq(lens.totalStake(TOKEN1), 30 ether, "the position is whole under the new coldkey");
    }

    function testFuzz_RecoverStray_ParksOnlyWhenTheSourcesCoverTheRecord(uint256 missing) public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 slack = VaultReads.TRACKED_SLACK_RAO * vault.recordedSlots(TOKEN1).length;
        missing = bound(missing, 0, 2 * slack);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, owed - missing);
        _simulateSameOwner(hotkey1, hotkey4);

        if (missing > slack) vm.expectRevert(RecoveryIncomplete.selector);
        vault.recoverStray(TOKEN1, _hotkeys(hotkey4));

        assertEq(lens.awaitingAttestation(TOKEN1), missing <= slack, "parked exactly when the sources cover the record");
    }

    function test_SquattedFundedKey_IsRetiredNotFunded() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);
        _simulateSquatter(hotkey1);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.rebalance(NETUID1);
    }
}
