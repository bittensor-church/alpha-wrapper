// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import { AttestedHotkeyRetired, BackingShortfall, SwappedHotkeyStillAttested } from "src/VaultErrors.sol";
import { CHAIN_MIN_TRANSFER, MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract BackingResolutionTest is AlphaVaultTestBase {
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
        vault.wrap(NETUID1, hotkey1, 0);
        vm.prank(alice);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);
        vm.prank(bob);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);
    }

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

    /// @dev Synthetic partial migration exercises the coverage guard; ordinary swaps move whole entries.
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

    function test_SuccessorWithAResidualLeftBehind_StaysOperable() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 accounted = lens.totalStake(TOKEN1);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, CHAIN_MIN_TRANSFER);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, owed);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "stray stake cannot block the recorded successor");
        assertEq(lens.totalStake(TOKEN1), accounted, "the residual is not counted twice");
        vault.rebalance(NETUID1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);
    }

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
        vault.unwrap(TOKEN1, quarter, _toSubstrate(alice), 0);
    }

    /// @dev Falling back to a logical name now occupied by another slot would count one balance twice.
    function test_TaoExitEmptyingASwappedSlot_LeavesNoBalanceAnsweringTwice() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        _simulateFollowedSwap(NETUID1, hotkey2, hotkey1);

        uint256 burn = (shares * (_getVaultStake(hotkey4, NETUID1) + 1e15)) / lens.locatedStake(TOKEN1);
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, burn, 0);

        uint256 held =
            _getVaultStake(hotkey1, NETUID1) + _getVaultStake(hotkey3, NETUID1) + _getVaultStake(hotkey4, NETUID1);
        assertEq(lens.locatedStake(TOKEN1), held, "the position counts what it holds, once");

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            for (uint256 j = i + 1; j < slots.length; ++j) {
                assertTrue(slots[i].active != slots[j].active, "no two slots answer for one key");
            }
        }
    }

    function test_SettleAfterAnEmptyingExit_KeepsSlotsOnDistinctKeys() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        _simulateFollowedSwap(NETUID1, hotkey2, hotkey1);
        uint256 burn = (shares * (_getVaultStake(hotkey4, NETUID1) + 1e15)) / lens.locatedStake(TOKEN1);
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, burn, 0);
        uint256 held = lens.locatedStake(TOKEN1);

        vault.rebalance(NETUID1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            for (uint256 j = i + 1; j < slots.length; ++j) {
                assertTrue(slots[i].active != slots[j].active, "no two slots answer for one key");
            }
        }
        assertEq(slots[0].active, hotkey4, "the emptied slot kept its resolved key");
        assertEq(slots[1].active, hotkey1, "beside the slot whose alpha its name carries");
        assertApproxEqAbs(lens.totalStake(TOKEN1), held, 0.01 ether, "and the total counts each balance once");
    }

    function _positionWithAnEmptiedSlotOnAnotherKey() private {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        _simulatePerSubnetSwap(NETUID1, hotkey2, hotkey1);
        _drainTheFirstSlot(alice, NETUID1);
    }

    function test_SetNamingTheKeyAnEmptiedSlotStaysOn_Refuses() public {
        _positionWithAnEmptiedSlotOnAnotherKey();

        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey4, hotkey2), _weights(3334, 3333, 3333));

        vm.expectRevert(SwappedHotkeyStillAttested.selector);
        vault.rebalance(NETUID1);
    }

    function test_EmptiedSlotWhoseKeyIsRetired_RefusesTheRebalance() public {
        _positionWithAnEmptiedSlotOnAnotherKey();

        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.rebalance(NETUID1);
    }

    /// @dev No edge distinguishes a dust sweep from an erased swap trail; neither permits immediate repricing.
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

    function test_SwapWithNoEdge_FailsClosed() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        assertFalse(lens.isBackingIntact(TOKEN1), "an unrecorded move is not accounted for");
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

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

    function test_SweptPosition_ReopensAfterTheWindow() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, coldkey, NETUID1, 0);

        assertFalse(lens.isBackingIntact(TOKEN1), "an emptied position cannot account for itself");
        _runOutRecoveryWindow(TOKEN1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        assertEq(vault.totalSupply(TOKEN1), 0, "the shares retire against what is left");

        _depositAndWrap(bob, NETUID1, 30 ether);
        assertGt(vault.balanceOf(bob, TOKEN1), 0, "the token recapitalizes after the window");
    }

    function test_RegistryUpdate_NeitherClearsALossNorAddsBacking() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 located = lens.locatedStake(TOKEN1);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);

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
