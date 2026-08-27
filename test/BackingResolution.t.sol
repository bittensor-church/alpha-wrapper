// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { BackingShortfall } from "src/VaultErrors.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// @dev Covers what the one-hop resolver refuses: trails it will not walk, edges the chain never
///      recorded, and collisions where one balance would answer for two slots. Getting a refused
///      position back lives in BackingRecovery.t.sol.
contract BackingResolutionTest is AlphaVaultTestBase {
    // -------------------- Fail closed on an unexplained shortfall ----------------

    /// @dev A second edge is never read, so a deposit's worth of backing two swaps away is a loss
    ///      for the watcher to resolve, and every path that prices shares or moves alpha waits.
    function test_TwoHopSwap_FailsClosedOnEveryPath() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _depositAndWrap(bob, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);

        assertFalse(lens.isBackingIntact(TOKEN1), "a trail the vault will not walk is not accounted for");

        vm.expectPartialRevert(BackingShortfall.selector);
        lens.totalStake(TOKEN1);
        vm.expectPartialRevert(BackingShortfall.selector);
        lens.sharePrice(TOKEN1);
        vm.expectPartialRevert(BackingShortfall.selector);
        lens.previewWrap(TOKEN1, 1 ether);
        vm.expectPartialRevert(BackingShortfall.selector);
        lens.previewUnwrap(TOKEN1, shares / 2);

        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
        _simulateAlphaDeposit(bob, NETUID1, 1 ether);
        vm.prank(bob);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.wrap(NETUID1, hotkey1);
        vm.prank(alice);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice));
        vm.prank(bob);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);
    }

    /// @dev Share transfers and the native TAO a holder has already earned belong to the holder
    ///      whatever the alpha is doing, so neither waits on a recovery window.
    function test_ShortfallStanding_LeavesTransfersAndTaoClaimsLive() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _donateToClone(vault.subnetClone(TOKEN1), 4 ether);
        vault.rebalance(NETUID1);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);

        vm.prank(alice);
        vault.safeTransferFrom(alice, bob, TOKEN1, shares / 2, "");
        assertEq(vault.balanceOf(bob, TOKEN1), shares / 2, "shares move while the window runs");

        assertGt(lens.claimableTaoOf(alice, TOKEN1), 0, "the TAO quote still answers");
        _claimQuotedAmount(alice, TOKEN1);
    }

    /// @dev Each slot answers for its own expectation, so growth elsewhere cannot cover a loss.
    function test_GrowthElsewhere_DoesNotCoverALoss() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 lost = _getVaultStake(hotkey1, NETUID1);
        _buildSwapTrail(NETUID1, hotkey1, 2);

        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE)
            .setStake(hotkey2, coldkey, NETUID1, _getVaultStake(hotkey2, NETUID1) + lost + 5 ether);

        assertFalse(lens.isBackingIntact(TOKEN1), "a richer neighbour explains nothing");
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev One balance cannot back two slots, so a successor another slot already answers for is
    ///      refused however the two got there.
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

    /// @dev A successor holding less than the slot is owed explains part of the loss, which is not
    ///      an explanation: accepting it would report the rest as backing that is not there.
    function test_PartialSuccessor_FailsClosed() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, owed / 2);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);

        assertFalse(lens.isBackingIntact(TOKEN1), "half the alpha is not the alpha");
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev A slot spread across two physical keys is more than the compact record can carry, so a
    ///      residual left behind sends the case to the watcher rather than down the follow.
    function test_SuccessorWithAResidualLeftBehind_FailsClosed() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, owed / 4);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, owed);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);

        assertFalse(lens.isBackingIntact(TOKEN1), "two piles for one slot is not a clean swap");
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev A swap can carry one slot's alpha onto a key another slot has itself moved off. Nothing
    ///      answers twice there, so the follow is allowed and the token stays operable.
    function test_SwapOntoAKeyAnotherSlotLeft_StaysOperable() public {
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
    ///      would be unsound, because a swap leaves the same silence once the old key is registered
    ///      again and the chain drops the edge: an operator could swap away with the alpha,
    ///      re-register, and have the vault write the loss off and reprice the token beneath it. So
    ///      an emptying nothing explains stands until a watcher resolves it or its window runs.
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

    /// @dev Nothing in the decision reads a price, so neither the size of the loss nor the price of
    ///      alpha touches the verdict.
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

    /// @dev A position the chain really did empty. Nobody can find alpha that no longer exists, so
    ///      the window runs out on it and the token comes back with the loss socialized.
    function test_SweptPosition_ReopensAfterTheWindow() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, coldkey, NETUID1, 0);

        assertFalse(lens.isBackingIntact(TOKEN1), "an emptied position cannot account for itself");
        _runOutRecoveryWindow(TOKEN1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));
        assertEq(vault.totalSupply(TOKEN1), 0, "the shares retire against what is left");

        _depositAndWrap(bob, NETUID1, 30 ether);
        assertGt(vault.balanceOf(bob, TOKEN1), 0, "the token recapitalizes after the window");
    }

    /// @dev The registry is allocation policy and nothing more: rotating a validator in neither
    ///      settles a standing loss nor brings that validator's own balance into the count.
    function test_RegistryUpdate_NeitherClearsALossNorAddsBacking() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 located = lens.locatedStake(TOKEN1);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);

        // hotkey4 comes in already holding alpha of the vault's, which no slot answers for.
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, _subnetColdkey(NETUID1), NETUID1, 9 ether);
        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );

        assertFalse(lens.isBackingIntact(TOKEN1), "the rotation settled nothing");
        assertEq(lens.locatedStake(TOKEN1), located - _lostToTheTrail(located), "and added no backing of its own");
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    function _lostToTheTrail(uint256 located) private view returns (uint256) {
        return located - _getVaultStake(hotkey2, NETUID1) - _getVaultStake(hotkey3, NETUID1);
    }
}
