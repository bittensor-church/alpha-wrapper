// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// @dev Covers a validator renaming its hotkey out from under the position: operations verify the
///      recorded backing, follow one rename hop, and refuse to price an unexplained shortfall.
contract HotkeySwapTripwireTest is AlphaVaultTestBase {
    event HotkeySwapFollowed(uint256 indexed tokenId, bytes32 indexed oldHotkey, bytes32 indexed newHotkey);

    bytes32 internal hotkey5 = keccak256("hotkey5");

    // -------------------- Tracked accounting -------------------------------------

    function test_Wrap_SettlesTrackedToStaked() public {
        _depositAndWrap(alice, NETUID1, 30 ether);

        AlphaVault.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots.length, 3, "one slot per attested validator");
        assertEq(slots[0].hotkey, hotkey1, "slot 0 remembers hotkey1");
        assertEq(slots[0].tracked, _getVaultStake(hotkey1, NETUID1), "slot 0 tracked mirrors staked alpha");
        assertEq(slots[1].tracked, _getVaultStake(hotkey2, NETUID1), "slot 1 tracked mirrors staked alpha");
        assertEq(slots[2].tracked, _getVaultStake(hotkey3, NETUID1), "slot 2 tracked mirrors staked alpha");
    }

    function test_Unwrap_LowersTrackedToPostBalance() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 ether);
        uint256 trackedBefore = vault.recordedSlots(TOKEN1)[0].tracked;

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice));

        AlphaVault.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertLt(slots[0].tracked, trackedBefore, "tracked drops after the partial exit");
        assertEq(slots[0].tracked, _getVaultStake(hotkey1, NETUID1), "slot 0 tracked mirrors reduced stake");
        assertEq(slots[1].tracked, _getVaultStake(hotkey2, NETUID1), "slot 1 tracked mirrors reduced stake");
        assertEq(slots[2].tracked, _getVaultStake(hotkey3, NETUID1), "slot 2 tracked mirrors reduced stake");
    }

    function test_UnwrapForTao_LowersTrackedToPostBalance() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 ether);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);

        AlphaVault.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            assertEq(slots[i].tracked, _getVaultStake(slots[i].hotkey, NETUID1), "tracked mirrors the post-sale stake");
        }
    }

    /// @dev Consolidation rolls the backing onto the rotated-in set and the record settles to it,
    ///      carrying no trace of the old hotkey.
    function test_AuthorizedRotation_ResetsTracked() public {
        _depositAndWrap(alice, NETUID1, 30 ether);

        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vault.rebalance(NETUID1);

        AlphaVault.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].hotkey, hotkey4, "slot 0 remembers the rotated-in hotkey");
        assertEq(slots[0].tracked, _getVaultStake(hotkey4, NETUID1), "slot 0 tracked mirrors consolidated stake");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "rotated-out hotkey holds no backing");
        for (uint256 i; i < slots.length; ++i) {
            assertTrue(slots[i].hotkey != hotkey1, "no slot still remembers the rotated-out hotkey");
        }
    }

    // -------------------- Fail-closed on an unexplained shortfall ----------------

    function test_Wrap_RevertsWhenBackingShort() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        _simulateAlphaDeposit(bob, NETUID1, 10 ether);
        vm.prank(bob);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.wrap(NETUID1, hotkey1);
    }

    function test_Unwrap_RevertsWhenBackingShort() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        vm.prank(alice);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice));
    }

    function test_UnwrapForTao_RevertsWhenBackingShort() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        vm.prank(alice);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);
    }

    function test_Rebalance_RevertsWhenBackingShort() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev Each slot is checked against its own expectation, so growth elsewhere cannot hide a
    ///      loss even when the total looks whole.
    function test_EmissionElsewhere_DoesNotMaskLoss() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 lost = _getVaultStake(hotkey1, NETUID1);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 grown = _getVaultStake(hotkey2, NETUID1) + lost + 5 ether;
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, grown);

        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    // -------------------- Following the rename trail -----------------------------

    function test_Rebalance_FollowsHotkeySwap() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        vm.expectEmit(true, true, true, true, address(vault));
        emit HotkeySwapFollowed(TOKEN1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        assertApproxEqAbs(vault.totalStake(TOKEN1), 30 ether, 0.01 ether, "backing whole after the follow");
        assertEq(vault.recordedSlots(TOKEN1)[0].hotkey, hotkey4, "the successor stands in for the retired key");
        assertGt(_getVaultStake(hotkey4, NETUID1), 0, "the backing stays on the successor");
        assertTrue(vault.isBackingIntact(TOKEN1), "record is intact after the follow");
    }

    /// @dev A depositor arriving right after a rename is priced on the whole backing - the exact
    ///      mispricing the tripwire exists to prevent.
    function test_WrapAfterSwap_MintsFairShares() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        // Post-rename deposits land under the successor; wrap accepts the alias of the attested key.
        _simulateAlphaDepositHotkey(bob, NETUID1, 30 ether, hotkey4);
        _wrapHotkey(bob, NETUID1, hotkey4);
        uint256 bobShares = vault.balanceOf(bob, TOKEN1);
        assertApproxEqRel(bobShares, aliceShares, 0.001e18, "equal deposits mint equal shares across the rename");
    }

    function test_UnwrapAfterSwap_PaysFullBacking() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        // A second holder keeps alice's burn partial, so her exit itself runs the gate.
        _depositAndWrap(bob, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));

        assertApproxEqAbs(
            _userStakeAcrossHotkeys(alice, NETUID1), 30 ether, 0.01 ether, "the exit pays the exiter's whole share"
        );
    }

    function test_UnwrapForTaoAfterSwap_SellsFullBacking() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        // A second holder keeps alice's burn partial, so her exit itself runs the gate.
        _depositAndWrap(bob, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertApproxEqAbs(alice.balance - balanceBefore, 30 ether, 0.01 ether, "sale covers the exiter's share");
    }

    /// @dev A further edge beyond the funded successor is someone else's history and never
    ///      confuses the repair.
    function test_FundedSuccessor_WinsOverDeeperTrail() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey4, NETUID1, hotkey5);

        vm.expectEmit(true, true, true, true, address(vault));
        emit HotkeySwapFollowed(TOKEN1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        assertApproxEqAbs(vault.totalStake(TOKEN1), 30 ether, 0.01 ether, "one-hop backing counted whole");
    }

    /// @dev One edge only: a two-rename trail is exceptional and fails closed for the attesters.
    function test_MultiHopRename_FailsClosed() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildRenameTrail(NETUID1, hotkey1, 2);

        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev The chain's rename migration credits the successor a few RAO short; the slack absorbs
    ///      it rather than freezing the token over rounding.
    function test_SwapCreditedShort_StillFollowed() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 credited = _getStakeForColdkey(hotkey4, coldkey, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, credited - 500);

        vault.rebalance(NETUID1);

        assertApproxEqAbs(vault.totalStake(TOKEN1), 30 ether, 0.01 ether, "backing whole despite the short credit");
    }

    /// @dev Re-anchoring spends the attestation that authorized it, so the next loss is caught
    ///      like any other.
    function test_ReanchoredRecord_StillFailsClosedOnNewLoss() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vault.rebalance(NETUID1);

        _simulateOffVaultSwap(NETUID1, hotkey4, hotkey5);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev A rename that leaves the stake in place is a non-event; nothing is followed.
    function test_KeepStakeSwap_IsNonEvent() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);

        vault.rebalance(NETUID1);

        assertEq(vault.recordedSlots(TOKEN1)[0].hotkey, hotkey1, "record keeps the funded original");
        assertApproxEqAbs(vault.totalStake(TOKEN1), 30 ether, 0.01 ether, "backing unchanged");
    }

    /// @dev Two slots resolving onto one key would count it twice, so the vault refuses rather
    ///      than merges. The chain cannot produce this - a rename destination must be unused.
    function test_SwapCollision_FailsClosed() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 merged = _getVaultStake(hotkey1, NETUID1) + _getVaultStake(hotkey2, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, merged);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey2, NETUID1, hotkey4);

        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    // -------------------- Legitimate quiet changes never trip --------------------

    function test_Emission_DoesNotTrip() public {
        _depositAndWrap(alice, NETUID1, 30 ether);

        _simulateEmissions(NETUID1, 5 ether);
        vault.rebalance(NETUID1);

        assertGt(vault.totalStake(TOKEN1), 30 ether, "emission counted into NAV, no false trip");
    }

    /// @dev Nothing the vault does to its own backing can trip the check.
    function test_VaultOperationSequence_NeverTrips() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 60 ether);
        vault.rebalance(NETUID1);
        _depositAndWrap(bob, NETUID1, 25 ether);

        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares / 3, _toSubstrate(alice));
        vault.rebalance(NETUID1);
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, aliceShares / 3, 0);
        vault.rebalance(NETUID1);

        assertTrue(vault.isBackingIntact(TOKEN1), "record settled through the whole sequence");
    }

    /// @dev Moves credit a few RAO short; the slack keeps ordinary rebalancing from reading as a
    ///      shortfall.
    function test_MoveRoundingLoss_DoesNotTrip() public {
        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(100);
        _depositAndWrap(alice, NETUID1, 30 ether);

        vault.rebalance(NETUID1);
        vault.rebalance(NETUID1);

        assertTrue(vault.isBackingIntact(TOKEN1), "rounding shortfalls stay inside the slack");
    }

    /// @dev The chain force-clears sub-threshold positions unsigned; that small an expectation is
    ///      exempt, so the sweep cannot freeze the token.
    function test_DustSweep_DoesNotFreeze() public {
        uint256 netuid = 5;
        _registerSubnet(netuid, hotkey1);
        _depositAndWrap(alice, netuid, 1e7);
        uint256 tokenId = vault.currentTokenId(netuid);

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(netuid), netuid, 0);

        assertTrue(vault.isBackingIntact(tokenId), "a sweepable expectation is exempt");
        vault.rebalance(netuid);
        assertEq(vault.recordedSlots(tokenId)[0].tracked, 0, "record settled to the swept state");
    }

    /// @dev A cheap enough expectation looks sweepable whether or not the chain swept it, so the
    ///      rename record is consulted first. Backing that merely moved must never be written off.
    function test_DustScaleRename_IsFollowedNotWrittenOff() public {
        uint256 netuid = 5;
        _registerSubnet(netuid, hotkey1);
        _depositAndWrap(alice, netuid, 1e7);
        uint256 tokenId = vault.currentTokenId(netuid);

        _simulateFollowedSwap(netuid, hotkey1, hotkey4);

        assertApproxEqAbs(vault.totalStake(tokenId), 1e7, 1e3, "the view counts the moved backing");
        vault.rebalance(netuid);
        assertEq(vault.recordedSlots(tokenId)[0].hotkey, hotkey4, "the record follows the rename");
        assertApproxEqAbs(vault.recordedSlots(tokenId)[0].tracked, 1e7, 1e3, "the backing is kept, not swept");
    }

    /// @dev A rename that keeps its stake parks the position under an unowned hotkey, which the
    ///      chain refuses to move from. Claiming the hotkey is permissionless and reopens the
    ///      position with no attester involvement.
    function test_ParkedStake_ClearsOnceHotkeyIsClaimed() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);
        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );

        // The backing is exactly where the record expects it, so the check passes and the roll
        // off the rotated-out hotkey is what the chain turns down.
        vm.expectRevert();
        vault.rebalance(NETUID1);

        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, false);
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "the parked position rolled off the claimed hotkey");
        assertApproxEqAbs(vault.totalStake(TOKEN1), 30 ether, 0.01 ether, "backing whole after the roll");
        assertTrue(vault.isBackingIntact(TOKEN1), "record intact once the position moved");
    }

    // -------------------- Honest views and recovery ------------------------------

    function test_IsBackingIntact_TrueWithoutPosition() public view {
        assertTrue(vault.isBackingIntact(TOKEN2), "a token with no position has nothing to break");
    }

    /// @dev The mint quote fails where the deposit would, the total reports what exits realize,
    ///      and the monitor view flags the anomaly.
    function test_Views_MirrorTheirOperations() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        assertFalse(vault.isBackingIntact(TOKEN1), "off-vault move reports backing not intact");
        assertApproxEqAbs(vault.totalStake(TOKEN1), 20 ether, 0.01 ether, "total reports the locatable backing");
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.previewWrap(TOKEN1, 1 ether);
    }

    /// @dev A quote taken mid-rename counts the successor, matching what the operations realize.
    function test_Views_CountRenamedBacking() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 navBefore = vault.totalStake(TOKEN1);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        assertEq(vault.totalStake(TOKEN1), navBefore, "renamed backing counted at its successor");
        (uint256 previewAlpha,) = vault.previewUnwrap(TOKEN1, vault.balanceOf(alice, TOKEN1));
        assertApproxEqAbs(previewAlpha, 30 ether, 0.01 ether, "exit quote counts the successor");
    }

    /// @dev Attesters listing the successor before the vault next runs is the good case, and the
    ///      quotes must not read it as a shortfall the operations sail straight through.
    function test_AttestedSuccessor_ViewsAgreeWithOperations() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );

        assertTrue(vault.isBackingIntact(TOKEN1), "an attested successor explains the slot");
        assertApproxEqAbs(vault.totalStake(TOKEN1), 30 ether, 0.01 ether, "counted once, not twice");
        vault.previewWrap(TOKEN1, 1 ether);

        _simulateAlphaDepositHotkey(bob, NETUID1, 30 ether, hotkey4);
        _wrapHotkey(bob, NETUID1, hotkey4);
        assertApproxEqRel(
            vault.balanceOf(bob, TOKEN1), vault.balanceOf(alice, TOKEN1), 0.001e18, "the deposit priced fairly"
        );
    }

    /// @dev An emptied position reads an honest zero rather than trapping integrators in reverts.
    function test_TotalStake_ZeroWhenEmptied() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, coldkey, NETUID1, 0);

        assertEq(vault.totalStake(TOKEN1), 0, "an emptied position reads zero");
    }

    /// @dev With no trail to follow, re-attesting the moved-to hotkey is the recovery; the vault
    ///      holds no recovery path of its own.
    function test_AttesterReattest_RecoversAfterShortfall() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vault.rebalance(NETUID1);

        AlphaVault.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].hotkey, hotkey4, "slot adopts the re-attested hotkey");
        assertApproxEqAbs(vault.totalStake(TOKEN1), 30 ether, 0.01 ether, "backing whole after recovery");
        assertTrue(vault.isBackingIntact(TOKEN1), "record intact after recovery");
    }

    /// @dev A loss the attesters cannot fully locate re-anchors to what is really there, so the
    ///      token keeps working at an honest, lower price.
    function test_PartialLoss_ReanchorsOnReattest() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 lost = _getVaultStake(hotkey1, NETUID1);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, lost / 2);

        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);

        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vault.rebalance(NETUID1);

        assertTrue(vault.isBackingIntact(TOKEN1), "record re-anchored on what the chain holds");
        assertApproxEqAbs(vault.totalStake(TOKEN1), 25 ether, 0.01 ether, "the total reports the surviving backing");
    }

    /// @dev The mechanism holds at the widest attested set.
    function testFuzz_WideSet_SwapFollowed(uint256 rawCount) public {
        uint256 count = bound(rawCount, 2, 64);
        uint256 netuid = 9;
        _setRegBlock(netuid, 400);
        bytes32[] memory hks = _setValidatorCount(netuid, count);

        _simulateAlphaDepositHotkey(alice, netuid, 64 ether, hks[0]);
        _wrapHotkey(alice, netuid, hks[0]);
        uint256 tokenId = vault.currentTokenId(netuid);

        bytes32 renamed = keccak256("wide-set-successor");
        _simulateOffVaultSwap(netuid, hks[0], renamed);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hks[0], netuid, renamed);

        vault.rebalance(netuid);

        assertApproxEqAbs(vault.totalStake(tokenId), 64 ether, 0.01 ether, "backing whole across the wide set");
        assertTrue(vault.isBackingIntact(tokenId), "record intact after the follow");
    }

    /// @dev The dissolution guard runs first, so a dissolving subnet reverts on the blackout.
    function test_Dissolving_SkipsCheck() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _simulateDissolutionStarted(NETUID1);

        vm.prank(alice);
        vm.expectRevert(AlphaVault.SubnetInDissolutionBlackoutPeriod.selector);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice));
    }

    /// @dev Exits get no exemption: burning against a total the record contradicts would hand the
    ///      exiter backing that may still be recoverable. Both rails wait for the attesters.
    function test_FullSupplyBurn_FailsClosedDuringShortfall() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        vm.prank(alice);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));

        vm.prank(alice);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.unwrapForTao(TOKEN1, shares, 0);
    }

    /// @dev A position emptied off-record freezes until the attesters re-attest; the re-anchor
    ///      then lets the holders retire their shares against the honest zero.
    function test_EmptiedPosition_FailsClosedUntilReattest() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 30 ether);
        _depositAndWrap(bob, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, coldkey, NETUID1, 0);

        vm.prank(alice);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice));

        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vault.rebalance(NETUID1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice));
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 0, "a zero backing pays zero");
        assertEq(vault.balanceOf(alice, TOKEN1), 0, "shares retired");
    }

    /// @dev Mailbox funds are not backing, so their recovery stays open while pricing fails closed.
    function test_MailboxReclaim_OpenDuringShortfall() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        _simulateAlphaDeposit(bob, NETUID1, 5 ether);
        vm.prank(bob);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey1, _toSubstrate(bob));

        assertEq(_getStake(hotkey1, bob, NETUID1), 5 ether, "mailbox alpha reclaimed during the freeze");
    }

    /// @dev A fully renamed hotkey no longer exists on chain, so operations substitute its
    ///      recorded successor and keep working while the registry lags.
    function test_RenamedValidator_OpsKeepWorking() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        _simulateAlphaDepositHotkey(bob, NETUID1, 30 ether, hotkey4);
        _wrapHotkey(bob, NETUID1, hotkey4);
        vault.rebalance(NETUID1);

        assertApproxEqAbs(vault.totalStake(TOKEN1), 60 ether, 0.01 ether, "both deposits counted");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing staked toward the retired key");
        assertGt(_getVaultStake(hotkey4, NETUID1), 0, "the successor carries the retired key's weight");
    }

    /// @dev A partial exit heals first and pays real value, never burning against the stale zero.
    function test_PartialExitAfterRename_PaysProperly() public {
        uint256 netuid = 5;
        _registerSubnet(netuid, hotkey1);
        uint256 shares = _depositAndWrap(alice, netuid, 10 ether);
        uint256 tokenId = vault.currentTokenId(netuid);
        _simulateFollowedSwap(netuid, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        vm.prank(alice);
        vault.unwrap(tokenId, shares / 2, _toSubstrate(alice));

        assertApproxEqAbs(_userStakeAcrossHotkeys(alice, netuid), 5 ether, 0.01 ether, "half the backing delivered");
    }

    function test_FullBurnAfterRename_PaysFull() public {
        uint256 netuid = 5;
        _registerSubnet(netuid, hotkey1);
        uint256 shares = _depositAndWrap(alice, netuid, 10 ether);
        uint256 tokenId = vault.currentTokenId(netuid);
        _simulateFollowedSwap(netuid, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        vm.prank(alice);
        vault.unwrap(tokenId, shares, _toSubstrate(alice));

        assertApproxEqAbs(_userStakeAcrossHotkeys(alice, netuid), 10 ether, 0.01 ether, "whole backing delivered");
        assertEq(vault.totalSupply(tokenId), 0, "supply retired");
    }

    function test_FullBurnForTaoAfterRename_SellsFull() public {
        uint256 netuid = 5;
        _registerSubnet(netuid, hotkey1);
        uint256 shares = _depositAndWrap(alice, netuid, 10 ether);
        uint256 tokenId = vault.currentTokenId(netuid);
        _simulateFollowedSwap(netuid, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(tokenId, shares, 0);

        assertApproxEqAbs(alice.balance - balanceBefore, 10 ether, 0.01 ether, "whole backing sold");
        assertEq(vault.totalSupply(tokenId), 0, "supply retired");
    }

    /// @dev A rename edge is evidence the backing is recoverable, so no exit on either rail may
    ///      burn against it.
    function test_TwoHopRename_ExitsFailClosed() public {
        uint256 netuid = 5;
        _registerSubnet(netuid, hotkey1);
        uint256 shares = _depositAndWrap(alice, netuid, 10 ether);
        uint256 tokenId = vault.currentTokenId(netuid);
        _buildRenameTrail(netuid, hotkey1, 2);

        vm.prank(alice);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.unwrap(tokenId, shares / 2, _toSubstrate(alice));
        vm.prank(alice);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.unwrap(tokenId, shares, _toSubstrate(alice));
        vm.prank(alice);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.unwrapForTao(tokenId, shares, 0);
    }

    /// @dev The chain sweep leaves a few RAO behind. The expectation is dust-scale, so it is
    ///      exempt, and the holders retire against the residue instead of being trapped.
    function test_SweepResidue_StaysExitable() public {
        uint256 netuid = 5;
        _registerSubnet(netuid, hotkey1);
        uint256 shares = _depositAndWrap(alice, netuid, 1e7);
        uint256 tokenId = vault.currentTokenId(netuid);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(netuid), netuid, 500);

        vm.prank(alice);
        vault.unwrap(tokenId, shares, _toSubstrate(alice));

        assertEq(_userStakeAcrossHotkeys(alice, netuid), 0, "a residue reading pays zero");
        assertEq(vault.totalSupply(tokenId), 0, "shares retired");
    }

    /// @dev A rename before the first wrap has no record to alias against; mailbox reclaim is the
    ///      documented path out.
    function test_RenameBeforeFirstWrap_ReclaimsViaMailbox() public {
        uint256 netuid = 5;
        _registerSubnet(netuid, hotkey1);
        _simulateAlphaDepositHotkey(bob, netuid, 10 ether, hotkey1);

        // The rename migrates the mailbox stake before any wrap has recorded slots.
        address mailbox = vault.getDepositAddress(bob, netuid);
        bytes32 mailboxColdkey = _toSubstrate(mailbox);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, mailboxColdkey, netuid, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, mailboxColdkey, netuid, 10 ether);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, netuid, hotkey4);

        vm.prank(bob);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.wrap(netuid, hotkey1);
        vm.prank(bob);
        vm.expectRevert(AlphaVault.ChosenHotkeyNotInSet.selector);
        vault.wrap(netuid, hotkey4);

        vm.prank(bob);
        vault.reclaimAlphaFromMailbox(netuid, hotkey4, _toSubstrate(bob));
        assertEq(_getStake(hotkey4, bob, netuid), 10 ether, "mailbox stake reclaimed from the successor");
    }

    /// @dev Any settled call spends the attestation, so a signature published before the loss
    ///      cannot be cashed in after it.
    function test_StaleAttestation_DoesNotAuthorizeReanchor() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _depositAndWrap(bob, NETUID1, 30 ether);
        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );

        // Nothing is short yet, so the exit settles and consumes the fresh attestation.
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);

        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey5);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev Re-anchoring needs an attester signature since the last settle; stake parked nearby
    ///      explains nothing by itself.
    function test_DonationWithoutReattestation_FailsClosed() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        // Settles the record onto the successor while the registry still lists hotkey1.
        vault.rebalance(NETUID1);

        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 lost = _getVaultStake(hotkey2, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey5, coldkey, NETUID1, lost);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, lost + 1 ether);

        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev Moves the clone's backing between hotkeys with no vault call, standing in for a
    ///      validator renaming its hotkey out from under the position.
    function _simulateOffVaultSwap(uint256 netuid, bytes32 fromHotkey, bytes32 toHotkey) internal {
        bytes32 coldkey = _subnetColdkey(netuid);
        uint256 amount = _getStakeForColdkey(fromHotkey, coldkey, netuid);
        MockStaking(STAKING_PRECOMPILE).setStake(fromHotkey, coldkey, netuid, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(toHotkey, coldkey, netuid, amount);
    }

    /// @dev A full rename as the chain records it: the stake moves and the trail points at it.
    function _simulateFollowedSwap(uint256 netuid, bytes32 fromHotkey, bytes32 toHotkey) internal {
        _simulateOffVaultSwap(netuid, fromHotkey, toHotkey);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(fromHotkey, netuid, toHotkey);
    }

    /// @dev Chains `hops` renames from `fromHotkey`, moving the backing to the returned tip.
    function _buildRenameTrail(uint256 netuid, bytes32 fromHotkey, uint256 hops) internal returns (bytes32 tip) {
        bytes32 previous = fromHotkey;
        for (uint256 i; i < hops; ++i) {
            tip = keccak256(abi.encode("trail-hop", i));
            MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(previous, netuid, tip);
            previous = tip;
        }
        _simulateOffVaultSwap(netuid, fromHotkey, tip);
    }
}
