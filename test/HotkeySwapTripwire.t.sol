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
    bytes32 internal hotkey6 = keccak256("hotkey6");

    // -------------------- Tracked accounting -------------------------------------

    function test_Wrap_SettlesTrackedToStaked() public {
        _depositAndWrap(alice, NETUID1, 30 ether);

        AlphaVault.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots.length, 3, "one slot per attested validator");
        assertEq(slots[0].hotkey, hotkey1, "slot 0 remembers hotkey1");
        assertEq(uint256(slots[0].tracked), _getVaultStake(hotkey1, NETUID1), "slot 0 tracked mirrors staked alpha");
        assertEq(uint256(slots[1].tracked), _getVaultStake(hotkey2, NETUID1), "slot 1 tracked mirrors staked alpha");
        assertEq(uint256(slots[2].tracked), _getVaultStake(hotkey3, NETUID1), "slot 2 tracked mirrors staked alpha");
    }

    function test_Unwrap_LowersTrackedToPostBalance() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 ether);
        uint256 trackedBefore = uint256(vault.recordedSlots(TOKEN1)[0].tracked);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice));

        AlphaVault.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertLt(uint256(slots[0].tracked), trackedBefore, "tracked drops after the partial exit");
        assertEq(uint256(slots[0].tracked), _getVaultStake(hotkey1, NETUID1), "slot 0 tracked mirrors reduced stake");
        assertEq(uint256(slots[1].tracked), _getVaultStake(hotkey2, NETUID1), "slot 1 tracked mirrors reduced stake");
        assertEq(uint256(slots[2].tracked), _getVaultStake(hotkey3, NETUID1), "slot 2 tracked mirrors reduced stake");
    }

    function test_UnwrapForTao_LowersTrackedToPostBalance() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 ether);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);

        AlphaVault.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            assertEq(
                uint256(slots[i].tracked),
                _getVaultStake(slots[i].hotkey, NETUID1),
                "tracked mirrors the post-sale stake"
            );
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
        assertEq(
            uint256(slots[0].tracked), _getVaultStake(hotkey4, NETUID1), "slot 0 tracked mirrors consolidated stake"
        );
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "rotated-out hotkey holds no backing");
        for (uint256 i; i < slots.length; ++i) {
            assertTrue(slots[i].hotkey != hotkey1, "no slot still remembers the rotated-out hotkey");
        }
    }

    /// @dev A stake reading wider than the slot's `uint128` cannot be recorded, so the settle
    ///      reverts rather than silently truncate the expectation. A single-validator subnet
    ///      keeps the whole oversized reading on one slot.
    function test_RevertWhen_TrackedOverflow() public {
        uint256 netuid = 5;
        _registerSubnet(netuid, hotkey1);
        _simulateAlphaDepositHotkey(alice, netuid, 10 ether, hotkey1);
        _wrapHotkey(alice, netuid, hotkey1);

        MockStaking(STAKING_PRECOMPILE)
            .setStake(hotkey1, _subnetColdkey(netuid), netuid, uint256(type(uint128).max) + 1);

        vm.expectRevert(AlphaVault.TrackedOverflow.selector);
        vault.rebalance(netuid);
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
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);

        vm.expectEmit(true, true, true, true, address(vault));
        emit HotkeySwapFollowed(TOKEN1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        assertApproxEqAbs(vault.totalStake(TOKEN1), 30 ether, 0.01 ether, "backing whole after the follow");
        AlphaVault.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            assertTrue(slots[i].hotkey != hotkey4, "consolidation rolled the successor onto the attested set");
        }
        assertTrue(vault.isBackingIntact(TOKEN1), "record is intact after the follow");
    }

    /// @dev A depositor arriving right after a rename gets shares priced on the whole backing,
    ///      the exact mispricing the tripwire exists to prevent.
    function test_WrapAfterSwap_MintsFairShares() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);

        uint256 bobShares = _depositAndWrap(bob, NETUID1, 30 ether);
        assertApproxEqRel(bobShares, aliceShares, 0.001e18, "equal deposits mint equal shares across the rename");
    }

    function test_UnwrapAfterSwap_PaysFullBacking() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));

        assertApproxEqAbs(
            _userStakeAcrossHotkeys(alice, NETUID1), 30 ether, 0.01 ether, "full exit pays the whole backing"
        );
    }

    function test_UnwrapForTaoAfterSwap_SellsFullBacking() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertApproxEqAbs(alice.balance - balanceBefore, 30 ether, 0.01 ether, "sale covers the whole backing");
    }

    function testFuzz_SwapChainWithinBound_Heals(uint256 rawHops) public {
        uint256 hops = bound(rawHops, 1, 3);
        _depositAndWrap(alice, NETUID1, 30 ether);

        bytes32 previous = hotkey1;
        bytes32 tip;
        for (uint256 i; i < hops; ++i) {
            tip = keccak256(abi.encode("chain-hop", i));
            MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(previous, NETUID1, tip);
            previous = tip;
        }
        _simulateOffVaultSwap(NETUID1, hotkey1, tip);

        vault.rebalance(NETUID1);
        assertApproxEqAbs(vault.totalStake(TOKEN1), 30 ether, 0.01 ether, "backing whole across the chain");
    }

    /// @dev A rename can leave the backing parked mid-trail, so the follow tests the stake at
    ///      every hop instead of jumping to the tip.
    function test_MidTrailStake_IsFound() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey4, NETUID1, hotkey5);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        vm.expectEmit(true, true, true, true, address(vault));
        emit HotkeySwapFollowed(TOKEN1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        assertApproxEqAbs(vault.totalStake(TOKEN1), 30 ether, 0.01 ether, "mid-trail backing counted whole");
    }

    /// @dev Trails longer than the follow bound fail closed; the attesters recover such cases.
    function test_SwapChainBeyondBound_FailsClosed() public {
        _depositAndWrap(alice, NETUID1, 30 ether);

        bytes32 previous = hotkey1;
        bytes32 tip;
        for (uint256 i; i < 4; ++i) {
            tip = keccak256(abi.encode("long-chain-hop", i));
            MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(previous, NETUID1, tip);
            previous = tip;
        }
        _simulateOffVaultSwap(NETUID1, hotkey1, tip);

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
        assertEq(uint256(vault.recordedSlots(tokenId)[0].tracked), 0, "record settled to the swept state");
    }

    // -------------------- Honest views and recovery ------------------------------

    function test_IsBackingIntact_TrueWithoutPosition() public view {
        assertTrue(vault.isBackingIntact(TOKEN2), "a token with no position has nothing to break");
    }

    /// @dev Views never mask the shortfall: backing reads not-intact and NAV honestly undercounts,
    ///      so an off-chain consumer sees the same world the mutating path fails closed on.
    function test_Views_ReportShortfallHonestly() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 navBefore = vault.totalStake(TOKEN1);

        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        assertFalse(vault.isBackingIntact(TOKEN1), "off-vault move reports backing not intact");
        assertLt(vault.totalStake(TOKEN1), navBefore, "NAV honestly reflects the undercount");
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

    /// @dev Moves the clone's whole backing off `fromHotkey` onto `toHotkey` with no vault call,
    ///      standing in for a validator coldkey renaming its hotkey out from under the position.
    function _simulateOffVaultSwap(uint256 netuid, bytes32 fromHotkey, bytes32 toHotkey) internal {
        bytes32 coldkey = _subnetColdkey(netuid);
        uint256 amount = _getStakeForColdkey(fromHotkey, coldkey, netuid);
        MockStaking(STAKING_PRECOMPILE).setStake(fromHotkey, coldkey, netuid, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(toHotkey, coldkey, netuid, amount);
    }
}
