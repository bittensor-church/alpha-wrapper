// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import { BackingShortfall, HotkeyClaimedTwice } from "src/VaultErrors.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// @dev Covers a validator swapping its hotkey out from under the position: which swaps the vault
///      follows on its own, and which losses it refuses to price around. Recovery from a refusal
///      lives in BackingRecovery.t.sol.
contract BackingResolutionTest is AlphaVaultTestBase {
    // -------------------- Fail closed on an unexplained shortfall ----------------

    function test_UnfollowableSwap_FailsClosedOnEveryPath() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _depositAndWrap(bob, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);

        assertFalse(lens.isBackingIntact(TOKEN1), "a trail the vault cannot walk is not accounted for");

        // Minting is the one direction an understated position can be exploited from, so it waits.
        vm.expectPartialRevert(BackingShortfall.selector);
        lens.previewWrap(TOKEN1, 1 ether);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
        _simulateAlphaDeposit(bob, NETUID1, 1 ether);
        vm.prank(bob);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.wrap(NETUID1, hotkey1);

        // So does every quote. What the vault can locate understates the holding by whatever it has
        // lost track of, so a valuation taken from it is right only by accident - worse to hand out
        // than nothing at all.
        vm.expectPartialRevert(BackingShortfall.selector);
        lens.totalStake(TOKEN1);
        vm.expectPartialRevert(BackingShortfall.selector);
        lens.previewUnwrap(TOKEN1, shares / 2);
        vm.expectPartialRevert(BackingShortfall.selector);
        lens.sharePrice(TOKEN1);

        // The door still opens, quoted or not: holders are never shut in by a loss they did not
        // cause, and both rails pay their share of everything the vault can locate.
        uint256 located = _vaultStakeAcross(_hotkeys(hotkey2, hotkey3), NETUID1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice));
        assertApproxEqAbs(
            _userStakeAcrossHotkeys(alice, NETUID1), located / 4, 0.01 ether, "a quarter of the supply, a quarter of it"
        );
        vm.prank(bob);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);
    }

    /// @dev A withdrawal re-reads the record from the chain, which would file the loss as an
    ///      ordinary balance change and reopen deposits at the lowered price. The slot the plan
    ///      could not account for keeps its expectation instead.
    function test_ExitDuringAShortfall_LeavesTheLossStanding() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        _buildSwapTrail(NETUID1, hotkey1, 2);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice));

        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, owed, "the exit did not write the loss off");
        assertFalse(lens.isBackingIntact(TOKEN1), "so the token still reports itself short");
        _simulateAlphaDeposit(bob, NETUID1, 1 ether);
        vm.prank(bob);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.wrap(NETUID1, hotkey1);
    }

    /// @dev Each slot answers for its own expectation, so growth elsewhere cannot cover a loss.
    function test_GrowthElsewhere_DoesNotCoverALoss() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 lost = _getVaultStake(hotkey1, NETUID1);
        _buildSwapTrail(NETUID1, hotkey1, 2);

        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE)
            .setStake(hotkey2, coldkey, NETUID1, _getVaultStake(hotkey2, NETUID1) + lost + 5 ether);

        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev One balance cannot back two positions, whether or not the attesters name the key.
    function test_ConvergentSwaps_FailClosed() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 merged = _getVaultStake(hotkey1, NETUID1) + _getVaultStake(hotkey2, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, merged);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey2, NETUID1, hotkey4);

        assertFalse(lens.isBackingIntact(TOKEN1), "the quote sees the collision");
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    function test_ConvergentSwapsOntoAttestedKey_FailClosed() public {
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

        assertFalse(lens.isBackingIntact(TOKEN1), "counted once is not claimed twice");
        vm.expectPartialRevert(BackingShortfall.selector);
        lens.previewWrap(TOKEN1, 1 ether);
    }

    /// @dev A followed swap leaves the record naming A while its alpha sits under B. If the
    ///      attesters then name B in its own right, A's slot and B's slot resolve onto one balance
    ///      and the token would report twice the backing it holds. The set is refused instead, and
    ///      the attesters clear it by dropping one of the pair.
    function test_SetNamingBothEndsOfASwap_ResolvesOneToOne() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey4, hotkey2), _weights(4000, 3000, 3000));

        vault.rebalance(NETUID1);
        assertTrue(lens.isBackingIntact(TOKEN1), "both ends of the swap resolve to their own keys");
        assertApproxEqAbs(lens.totalStake(TOKEN1), 30 ether, 0.01 ether, "and nothing is counted twice");
    }

    /// @dev A swap can carry one slot's alpha onto a name the set still lists, when that name's
    ///      own slot has itself moved on. Nothing answers twice there, and refusing it would freeze
    ///      a healthy token, so the check reads the keys the slots resolve to rather than the names
    ///      the attesters wrote.
    function test_SwapOntoAStillListedName_StaysOperable() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey2, hotkey5);
        vault.rebalance(NETUID1);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey2);

        vault.rebalance(NETUID1);

        assertTrue(lens.isBackingIntact(TOKEN1), "no balance answers for two slots");
        assertApproxEqAbs(lens.totalStake(TOKEN1), 30 ether, 0.01 ether, "the whole position is counted once");
        uint256 quarter = vault.balanceOf(alice, TOKEN1) / 4;
        vm.prank(alice);
        vault.unwrap(TOKEN1, quarter, _toSubstrate(alice));
    }

    // -------------------- Emptyings the chain does not explain -------------------

    /// @dev The chain's dust sweep records nothing at all. Reading that silence as proof of a sweep
    ///      would be unsound, because a swap leaves the same silence once the old key is
    ///      registered again and the chain drops the edge: an operator could swap away with the
    ///      alpha, re-register, and have the vault write the loss off and reprice the token beneath
    ///      it. So an emptying nothing explains stands, and the attesters settle what happened.
    function test_EdgeFreeEmptying_FailsClosed() public {
        uint256 netuid = 5;
        _registerSubnet(netuid, hotkey1);
        _depositAndWrap(alice, netuid, 1e7);
        uint256 tokenId = vault.currentTokenId(netuid);

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(netuid), netuid, 0);

        assertFalse(lens.isBackingIntact(tokenId), "nothing on chain accounts for the emptying");
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(netuid);
    }

    /// @dev The same silence with the alpha demonstrably alive under another key. The vault has no
    ///      way to tell this from the case above and does not guess between them.
    function test_SwapWithNoEdge_FailsClosed() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        assertFalse(lens.isBackingIntact(TOKEN1), "an unrecorded move is not accounted for");
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev Nothing in the decision reads a price, so neither the size of the loss nor the price
    ///      of alpha touches the verdict.
    function test_EdgeFreeEmptying_RefusesAtAnyPriceOrSize() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, coldkey, NETUID1, 0);
        _setAlphaPrice(NETUID1, 10e18);

        assertFalse(lens.isBackingIntact(TOKEN1), "a whole position is no better explained than dust");
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev A position the chain really did empty. The holder is never shut in - the exit retires
    ///      the shares against what is located, which is nothing - and it is that same exit that
    ///      puts the loss on file, so deposits resume a window later with nobody having to ask.
    function test_SweptPosition_ReopensAfterTheWindow() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, coldkey, NETUID1, 0);

        assertFalse(lens.isBackingIntact(TOKEN1), "an emptied position cannot account for itself");
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));
        assertEq(vault.totalSupply(TOKEN1), 0, "the shares retire without waiting on anyone");

        vm.warp(lens.depositsOpenFrom(TOKEN1));
        _depositAndWrap(bob, NETUID1, 30 ether);
        assertGt(vault.balanceOf(bob, TOKEN1), 0, "the token recapitalizes after the window");
    }
}
