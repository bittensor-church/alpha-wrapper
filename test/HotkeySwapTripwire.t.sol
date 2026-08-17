// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// @dev Tests the vault's protection against a validator renaming its hotkey out from under the
///      position: every operation verifies the recorded backing first, follows the chain's rename
///      trail when one exists, and refuses to price shares against a shortfall it cannot explain.
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

    /// @dev An attester rotation swaps hotkey1 out for hotkey4; consolidation rolls the backing
    ///      onto the new set and the record settles to it, carrying no trace of hotkey1.
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

    /// @dev Growth on the other validators cannot hide one validator's loss: each slot is checked
    ///      against its own expectation, so a shortfall reverts even when the total looks whole.
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

    /// @dev A depositor arriving right after a rename gets shares priced on the whole backing,
    ///      the exact mispricing the tripwire exists to prevent.
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

    /// @dev The follow reads exactly one rename edge; a further edge beyond the funded successor
    ///      is someone else's history and never confuses the repair.
    function test_FundedSuccessor_WinsOverDeeperTrail() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey4, NETUID1, hotkey5);

        vm.expectEmit(true, true, true, true, address(vault));
        emit HotkeySwapFollowed(TOKEN1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        assertApproxEqAbs(vault.totalStake(TOKEN1), 30 ether, 0.01 ether, "one-hop backing counted whole");
    }

    /// @dev The follow deliberately reads one edge only; a two-rename trail between vault touches
    ///      is an exceptional case that fails closed for the attesters.
    function test_MultiHopRename_FailsClosed() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildRenameTrail(NETUID1, hotkey1, 2);

        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev The chain's own rename migration can credit the successor a few RAO short; the
    ///      comparison slack absorbs it, so the follow still lands instead of freezing the token
    ///      over rounding.
    function test_SwapCreditedShort_StillFollowed() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 credited = _getStakeForColdkey(hotkey4, coldkey, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, credited - 500);

        vault.rebalance(NETUID1);

        assertApproxEqAbs(vault.totalStake(TOKEN1), 30 ether, 0.01 ether, "backing whole despite the short credit");
    }

    /// @dev Backing forgiven onto a newly attested key is recorded in the same pass, so it can
    ///      neither move off-record unseen afterwards nor excuse a second, unrelated shortfall.
    function test_ForgivenAdoption_IsRecorded() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 30 ether);
        _depositAndWrap(bob, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );

        // The TAO exit adopts through forgiveness without consolidating.
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, aliceShares / 2, 0);

        AlphaVault.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        bool recorded;
        for (uint256 i; i < slots.length; ++i) {
            if (slots[i].hotkey == hotkey4) recorded = slots[i].tracked > 0;
        }
        assertTrue(recorded, "the adopted key joined the record with its balance");

        // A second off-record move of the adopted backing is no longer invisible.
        _simulateOffVaultSwap(NETUID1, hotkey4, hotkey5);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev A rename that leaves the stake in place is a non-event: the record keeps the original
    ///      hotkey and nothing is followed.
    function test_KeepStakeSwap_IsNonEvent() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);

        vault.rebalance(NETUID1);

        assertEq(vault.recordedSlots(TOKEN1)[0].hotkey, hotkey1, "record keeps the funded original");
        assertApproxEqAbs(vault.totalStake(TOKEN1), 30 ether, 0.01 ether, "backing unchanged");
    }

    /// @dev One coldkey renaming two of its validators into the same key merges their positions on
    ///      chain; the record merges the expectations too, so the merged key is counted once.
    function test_SwapCollision_MergesSlots() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 merged = _getVaultStake(hotkey1, NETUID1) + _getVaultStake(hotkey2, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, merged);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey2, NETUID1, hotkey4);

        vault.rebalance(NETUID1);

        assertApproxEqAbs(vault.totalStake(TOKEN1), 30 ether, 0.01 ether, "merged backing counted exactly once");
        assertTrue(vault.isBackingIntact(TOKEN1), "record intact after the merge");
    }

    // -------------------- Legitimate quiet changes never trip --------------------

    function test_Emission_DoesNotTrip() public {
        _depositAndWrap(alice, NETUID1, 30 ether);

        _simulateEmissions(NETUID1, 5 ether);
        vault.rebalance(NETUID1);

        assertGt(vault.totalStake(TOKEN1), 30 ether, "emission counted into NAV, no false trip");
    }

    /// @dev A busy sequence of the vault's own operations keeps the record settled; nothing the
    ///      vault does to its own backing can trip the check.
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

    /// @dev The chain credits each stake move a few RAO short; the comparison's slack absorbs it,
    ///      so ordinary rebalancing never reads as a shortfall.
    function test_MoveRoundingLoss_DoesNotTrip() public {
        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(100);
        _depositAndWrap(alice, NETUID1, 30 ether);

        vault.rebalance(NETUID1);
        vault.rebalance(NETUID1);

        assertTrue(vault.isBackingIntact(TOKEN1), "rounding shortfalls stay inside the slack");
    }

    /// @dev The chain force-clears positions below its dust threshold without the vault's
    ///      signature; an expectation that small is exempt, so the sweep cannot freeze the token.
    function test_DustSweep_DoesNotFreeze() public {
        uint256 netuid = 5;
        _registerSubnet(netuid, hotkey1);
        _simulateAlphaDepositHotkey(alice, netuid, 1e7, hotkey1);
        _wrapHotkey(alice, netuid, hotkey1);
        uint256 tokenId = vault.currentTokenId(netuid);

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(netuid), netuid, 0);

        assertTrue(vault.isBackingIntact(tokenId), "a sweepable expectation is exempt");
        vault.rebalance(netuid);
        assertEq(vault.recordedSlots(tokenId)[0].tracked, 0, "record settled to the swept state");
    }

    // -------------------- Honest views and recovery ------------------------------

    function test_IsBackingIntact_TrueWithoutPosition() public view {
        assertTrue(vault.isBackingIntact(TOKEN2), "a token with no position has nothing to break");
    }

    /// @dev During an unexplained shortfall the mint quote fails exactly as the deposit would,
    ///      the total reports what the vault can locate - exactly what exits realize - and the
    ///      monitor view flags the anomaly.
    function test_Views_MirrorTheirOperations() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        assertFalse(vault.isBackingIntact(TOKEN1), "off-vault move reports backing not intact");
        assertApproxEqAbs(vault.totalStake(TOKEN1), 20 ether, 0.01 ether, "total reports the locatable backing");
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.previewWrap(TOKEN1, 1 ether);
    }

    /// @dev The pricing views count a pending rename's backing at its funded successor, so a
    ///      quote taken during the window matches what the operations realize.
    function test_Views_CountRenamedBacking() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 navBefore = vault.totalStake(TOKEN1);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        assertEq(vault.totalStake(TOKEN1), navBefore, "renamed backing counted at its successor");
        (uint256 previewAlpha,) = vault.previewUnwrap(TOKEN1, vault.balanceOf(alice, TOKEN1));
        assertApproxEqAbs(previewAlpha, 30 ether, 0.01 ether, "exit quote counts the successor");
    }

    /// @dev A position the chain emptied outright reads an honest zero everywhere instead of
    ///      trapping integrators in reverts.
    function test_TotalStake_ZeroWhenEmptied() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, coldkey, NETUID1, 0);

        assertEq(vault.totalStake(TOKEN1), 0, "an emptied position reads zero");
    }

    /// @dev With no trail to follow, recovery is the attesters re-attesting the moved-to hotkey;
    ///      consolidation then adopts it and the token needs no vault-held recovery path.
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

    /// @dev Re-attestation forgives a shortfall only up to what the newly attested keys actually
    ///      hold; attesting a key that covers half the loss keeps the token failing closed.
    function test_PartialAdoption_StillFailsClosed() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 lost = _getVaultStake(hotkey1, NETUID1);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, lost / 2);

        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );

        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev The mechanism holds at the widest attested set: one of many validators renamed away
    ///      is followed and the whole backing keeps pricing.
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

    /// @dev The dissolution guard runs before the backing check, so a dissolving subnet reverts on
    ///      the blackout, never on a shortfall.
    function test_Dissolving_SkipsCheck() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _simulateDissolutionStarted(NETUID1);

        vm.prank(alice);
        vm.expectRevert(AlphaVault.SubnetInDissolutionBlackoutPeriod.selector);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice));
    }

    /// @dev A shortfall never traps the last holder: with nobody else to shortchange, a burn of
    ///      the entire supply exits at the counted backing.
    function test_FullSupplyBurn_ExitsDuringShortfall() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));

        assertEq(vault.totalSupply(TOKEN1), 0, "the whole supply retired");
        assertApproxEqAbs(
            _userStakeAcrossHotkeys(alice, NETUID1), 20 ether, 0.01 ether, "the exit pays the counted backing"
        );
    }

    function test_FullSupplyBurnForTao_ExitsDuringShortfall() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(vault.totalSupply(TOKEN1), 0, "the whole supply retired");
        assertApproxEqAbs(alice.balance - balanceBefore, 20 ether, 0.01 ether, "the sale covers the counted backing");
    }

    /// @dev The chain can sell a whole position out from under the vault; retiring shares against
    ///      the zero reading pays zero and mispricing is impossible, so the exit proceeds while
    ///      the record - and with it the deposit freeze - stays in place.
    function test_ZeroBackingRetire_KeepsRecord() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 30 ether);
        _depositAndWrap(bob, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, coldkey, NETUID1, 0);

        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice));
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 0, "a zero backing pays zero");

        _simulateAlphaDeposit(bob, NETUID1, 10 ether);
        vm.prank(bob);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.wrap(NETUID1, hotkey1);
    }

    /// @dev Mailbox funds were never counted as backing, so their recovery paths stay open while
    ///      pricing paths fail closed.
    function test_MailboxReclaim_OpenDuringShortfall() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        _simulateAlphaDeposit(bob, NETUID1, 5 ether);
        vm.prank(bob);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey1, _toSubstrate(bob));

        assertEq(_getStake(hotkey1, bob, NETUID1), 5 ether, "mailbox alpha reclaimed during the freeze");
    }

    /// @dev A fully renamed hotkey no longer exists on chain, so nothing may stake toward it:
    ///      operations substitute the recorded successor for the retired attested key and keep
    ///      working while the registry lags the rename.
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

    /// @dev A partial exit right after a rename heals first and pays real value; it never burns
    ///      shares against the stale zero reading.
    function test_PartialExitAfterRename_PaysProperly() public {
        uint256 netuid = 5;
        _registerSubnet(netuid, hotkey1);
        _simulateAlphaDepositHotkey(alice, netuid, 10 ether, hotkey1);
        _wrapHotkey(alice, netuid, hotkey1);
        uint256 tokenId = vault.currentTokenId(netuid);
        _simulateFollowedSwap(netuid, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        uint256 shares = vault.balanceOf(alice, tokenId);
        vm.prank(alice);
        vault.unwrap(tokenId, shares / 2, _toSubstrate(alice));

        assertApproxEqAbs(_userStakeAcrossHotkeys(alice, netuid), 5 ether, 0.01 ether, "half the backing delivered");
    }

    function test_FullBurnAfterRename_PaysFull() public {
        uint256 netuid = 5;
        _registerSubnet(netuid, hotkey1);
        _simulateAlphaDepositHotkey(alice, netuid, 10 ether, hotkey1);
        _wrapHotkey(alice, netuid, hotkey1);
        uint256 tokenId = vault.currentTokenId(netuid);
        _simulateFollowedSwap(netuid, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        uint256 shares = vault.balanceOf(alice, tokenId);
        vm.prank(alice);
        vault.unwrap(tokenId, shares, _toSubstrate(alice));

        assertApproxEqAbs(_userStakeAcrossHotkeys(alice, netuid), 10 ether, 0.01 ether, "whole backing delivered");
        assertEq(vault.totalSupply(tokenId), 0, "supply retired");
    }

    function test_FullBurnForTaoAfterRename_SellsFull() public {
        uint256 netuid = 5;
        _registerSubnet(netuid, hotkey1);
        _simulateAlphaDepositHotkey(alice, netuid, 10 ether, hotkey1);
        _wrapHotkey(alice, netuid, hotkey1);
        uint256 tokenId = vault.currentTokenId(netuid);
        _simulateFollowedSwap(netuid, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        uint256 balanceBefore = alice.balance;
        uint256 shares = vault.balanceOf(alice, tokenId);
        vm.prank(alice);
        vault.unwrapForTao(tokenId, shares, 0);

        assertApproxEqAbs(alice.balance - balanceBefore, 10 ether, 0.01 ether, "whole backing sold");
        assertEq(vault.totalSupply(tokenId), 0, "supply retired");
    }

    /// @dev A rename edge is positive evidence the backing was not swept, so no exit - partial
    ///      or whole-supply, either rail - may burn shares against it; re-attestation recovers.
    function test_TwoHopRename_ExitsFailClosed() public {
        uint256 netuid = 5;
        _registerSubnet(netuid, hotkey1);
        _simulateAlphaDepositHotkey(alice, netuid, 10 ether, hotkey1);
        _wrapHotkey(alice, netuid, hotkey1);
        uint256 tokenId = vault.currentTokenId(netuid);
        _buildRenameTrail(netuid, hotkey1, 2);

        uint256 shares = vault.balanceOf(alice, tokenId);
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

    /// @dev A chain-side sale can leave a few RAO behind; a reading within the comparison slack
    ///      retires like an exact zero instead of trapping the holders.
    function test_SweepResidue_StaysExitable() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 30 ether);
        _depositAndWrap(bob, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, coldkey, NETUID1, 500);

        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice));

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 0, "a residue reading pays zero");
        assertEq(vault.balanceOf(alice, TOKEN1), 0, "shares retired");
    }

    /// @dev A rename that kept its stake leaves it counted but immovable under a deleted key;
    ///      the vault names that state instead of dying inside a later stake move.
    function test_KeepStakeRename_FailsWithNamedCause() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        vm.expectPartialRevert(AlphaVault.StakeParkedOnRetiredHotkey.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev A rename landing between mailbox funding and the first wrap has no record to alias
    ///      against; the mailbox reclaim is the documented path out.
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

    /// @dev On a chain build without the rename getter the vault stays fully usable and degrades
    ///      to fail-closed: probes read as "no edge" instead of bricking every caller.
    function test_ChainWithoutRenameGetter_StaysUsable() public {
        MockStaking(STAKING_PRECOMPILE).setSuccessorGetterReverts(true);

        _depositAndWrap(alice, NETUID1, 30 ether);
        vault.rebalance(NETUID1);
        assertApproxEqAbs(vault.totalStake(TOKEN1), 30 ether, 0.01 ether, "ordinary flows unaffected");

        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev Forgiveness opens only when the attesters have signed since the last settle: parking
    ///      a donation on a lapsed attested key explains nothing by itself.
    function test_DonationWithoutAttestation_DoesNotForgive() public {
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

    /// @dev Moves the clone's whole backing off `fromHotkey` onto `toHotkey` with no vault call,
    ///      standing in for a validator coldkey renaming its hotkey out from under the position.
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
