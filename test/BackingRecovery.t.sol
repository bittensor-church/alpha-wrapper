// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { AlphaVaultLens } from "src/AlphaVaultLens.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import {
    BackingShortfall,
    BackingUnchanged,
    NothingToRecover,
    NothingToUnwrap,
    RecoveryBelowFloor,
    RecoveryIncomplete,
    SlippageExceeded,
    SubnetInDissolutionBlackoutPeriod,
    ZeroAmount
} from "src/VaultErrors.sol";
import { MockStaking, CHAIN_MIN_STAKE } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

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

    /// @dev Reverted user calls cannot persist a clock; permissionless `syncBacking` starts it.
    function test_SyncBacking_StartsTheWindowWithoutAQuorum() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        _buildSwapTrail(NETUID1, hotkey1, 2);

        assertEq(lens.frozenUntil(TOKEN1), type(uint256).max, "a loss with no clock reports no opening");
        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingShortfallDeclared(TOKEN1, hotkey1, owed, 0);
        vm.prank(bob);
        vault.syncBacking(TOKEN1);

        assertEq(lens.frozenUntil(TOKEN1), block.timestamp + vault.recoveryWindow(), "the window runs from here");
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, owed, "the slot still knows what it is owed");
        assertFalse(lens.isBackingIntact(TOKEN1), "and still reports itself short");
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

    function test_WriteOff_ReturnsAShortSlotToItsAttestedValidator() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey4, "the record followed the swap");

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, _subnetColdkey(NETUID1), NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);
        _runOutRecoveryWindow(TOKEN1);

        vault.rebalance(NETUID1);

        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey1, "the slot answers to its validator again");
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "and nothing was staked toward the dead key");
        assertTrue(lens.isBackingIntact(TOKEN1), "the token is ordinary again");

        uint256 quarter = vault.balanceOf(alice, TOKEN1) / 4;
        vm.prank(alice);
        vault.unwrap(TOKEN1, quarter, _toSubstrate(alice), 0);
    }

    function test_RevertWhen_SyncingWhileTheSubnetIsDissolving() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        _setDissolving(NETUID1, true);

        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        vault.syncBacking(TOKEN1);
    }

    /// @dev A repaired loss must not lend its expired clock to a later shortfall.
    function test_LossRepairingItself_SpendsItsClock() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        bytes32 tip = _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);

        _simulateOffVaultSwap(NETUID1, tip, hotkey1);
        vault.syncBacking(TOKEN1);
        assertEq(lens.frozenUntil(TOKEN1), 0, "the window it was granted is spent");
        assertEq(vault.recordedSlots(TOKEN1)[0].shortSince, 0, "no clock left running");

        vm.warp(block.timestamp + 2 * vault.recoveryWindow());
        assertEq(_getVaultStake(hotkey1, NETUID1), owed, "the recurrence is identical to the first loss");
        _buildSwapTrail(NETUID1, hotkey1, 2);

        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
        assertEq(lens.frozenUntil(TOKEN1), type(uint256).max, "the recurrence starts from no clock at all");
    }

    function test_RecoverStray_ClearsTheShortfallWithoutAQuorum() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        vault.syncBacking(TOKEN1);
        assertFalse(lens.isBackingIntact(TOKEN1), "the loss is visible first");

        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingRecovered(TOKEN1, hotkey1, owed);
        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "the found alpha accounts for the loss");
        assertEq(lens.frozenUntil(TOKEN1), 0, "finding it ends the window");
        assertEq(lens.totalStake(TOKEN1), 30 ether, "backing whole after recovery");
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey1, "and the alpha is back where the slot expects it");
    }

    function test_RecoverStray_ResolvesATwoHopTrail() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 tip = _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, tip);

        assertTrue(lens.isBackingIntact(TOKEN1), "the watcher-supplied source accounts for the loss");
        assertEq(lens.totalStake(TOKEN1), 30 ether, "backing whole again");
    }

    function test_RecoverStray_WaitsForAnOutsiderToClaimTheAbandonedKey() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);
        vault.syncBacking(TOKEN1);

        vm.expectRevert(bytes("MockStaking: hotkey has no owner"));
        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);

        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, false);
        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "the exit reopens without the vault owning anything");
        uint256 quarter = vault.balanceOf(alice, TOKEN1) / 4;
        vm.prank(alice);
        vault.unwrap(TOKEN1, quarter, _toSubstrate(alice), 0);
    }

    /// @dev Synthetic split backing exercises the coverage guard; ordinary swaps move whole entries.
    function test_RevertWhen_TheSourceCannotCoverTheLoss() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, owed / 3);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey5, coldkey, NETUID1, owed);
        vault.syncBacking(TOKEN1);
        uint256 deadline = lens.frozenUntil(TOKEN1);

        vm.expectRevert(RecoveryIncomplete.selector);
        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);
        assertFalse(lens.isBackingIntact(TOKEN1), "the loss still stands");
        assertEq(_getStakeForColdkey(hotkey4, coldkey, NETUID1), owed / 3, "the alpha it refused stayed put");
        assertEq(lens.frozenUntil(TOKEN1), deadline, "and the deadline did not move");

        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey5);
        assertTrue(lens.isBackingIntact(TOKEN1), "the key covering the loss recovers it");
        assertEq(lens.frozenUntil(TOKEN1), 0, "and the window ends");
    }

    function test_RevertWhen_TheStrayIsTooSmallForTheChainToMove() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, 1);
        vault.syncBacking(TOKEN1);

        vm.expectRevert(RecoveryBelowFloor.selector);
        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);
    }

    function test_SyncBacking_KeepsAFollowedSwapInTheRecord() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 moved = _getVaultStake(hotkey1, NETUID1);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        _buildSwapTrail(NETUID1, hotkey2, 2);

        vault.syncBacking(TOKEN1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].active, hotkey4, "the record kept the key the swap reached");
        assertEq(slots[0].shortSince, 0, "which is not a loss and needs no clock");
        assertEq(_getVaultStake(hotkey4, NETUID1), moved, "and that is where the alpha is");
        assertGt(slots[1].shortSince, 0, "while the loss beside it got its own");
    }

    function test_RevertWhen_RecoveringFromAKeyHoldingNothing() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, hotkey5);
    }

    function test_RevertWhen_RecoveringFromTheSlotsOwnKey() public {
        _depositAndWrap(alice, NETUID1, 30 ether);

        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, hotkey1);
    }

    function test_RevertWhen_RecoveringOnATokenWithNoSlots() public {
        vault.createSubnetProxy(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, _subnetColdkey(NETUID1), NETUID1, 5 ether);

        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, hotkey4);
    }

    function test_RecoverStray_RoutesEachLumpToItsOwnSlot() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(6000, 3000, 1000));
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _simulateOffVaultSwap(NETUID1, hotkey2, hotkey5);
        vault.syncBacking(TOKEN1);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey5);
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertGt(slots[0].shortSince, 0, "the larger loss still stands");
        assertEq(slots[1].shortSince, 0, "the smaller slot is whole");

        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);
        assertTrue(lens.isBackingIntact(TOKEN1), "both lumps are home");
        assertEq(lens.totalStake(TOKEN1), 30 ether, "with nothing lost in routing");
    }

    function test_RecoverStray_AimsACoveringSourceAtTheLargestShortSlot() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(6000, 3000, 1000));
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _simulateOffVaultSwap(NETUID1, hotkey2, hotkey5);
        vault.syncBacking(TOKEN1);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].shortSince, 0, "the largest expectation took the covering find");
        assertGt(slots[1].shortSince, 0, "while the smaller loss keeps its own clock");

        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey5);
        assertTrue(lens.isBackingIntact(TOKEN1), "and is healed by its own lump");
    }

    function testFuzz_RecoverStray_BringsEveryLumpHome(uint256 countSeed, uint256 lossMask) public {
        uint256 count = bound(countSeed, 2, 6);
        bytes32[] memory set = new bytes32[](count);
        uint16[] memory weights = new uint16[](count);
        uint16 assigned;
        for (uint256 i; i < count; ++i) {
            set[i] = keccak256(abi.encode("fuzz-validator", i));
            if (i + 1 < count) {
                weights[i] = uint16(BPS_BASE / count);
                assigned += weights[i];
            }
        }
        weights[count - 1] = uint16(BPS_BASE - assigned);
        _setValidators(NETUID1, set, weights);
        _depositAndWrap(alice, NETUID1, 30 ether);

        lossMask = bound(lossMask, 1, (1 << count) - 1);
        for (uint256 i; i < count; ++i) {
            if (lossMask & (1 << i) == 0) continue;
            _simulateOffVaultSwap(NETUID1, set[i], keccak256(abi.encode("stray", i)));
        }
        vault.syncBacking(TOKEN1);

        for (uint256 i; i < count; ++i) {
            if (lossMask & (1 << i) == 0) continue;
            vm.prank(bob);
            vault.recoverStray(TOKEN1, keccak256(abi.encode("stray", i)));
        }

        assertTrue(lens.isBackingIntact(TOKEN1), "every loss is healed");
        assertEq(lens.totalStake(TOKEN1), 30 ether, "and the whole deposit is accounted for");
    }

    function test_RecoverStray_HealsALossNobodyRecorded() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        assertEq(lens.frozenUntil(TOKEN1), type(uint256).max, "the loss is visible with no clock");

        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "the find lands without a sighting on file");
        assertEq(lens.frozenUntil(TOKEN1), 0, "and no window ever opened");
        assertEq(vault.recordedSlots(TOKEN1)[0].shortSince, 0, "with no clock ever started");
    }

    function test_RecoverStray_BringsAnEmissionGrownLumpHome() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        uint256 lump = _getStakeForColdkey(hotkey4, coldkey, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, lump + 2 ether);
        vault.syncBacking(TOKEN1);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "the loss is healed");
        assertEq(lens.totalStake(TOKEN1), 32 ether, "and the emissions came home with the lump");
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
        assertTrue(hourLens.isBackingIntact(tokenId), "and the write-off falls due on it too");
    }

    /// @dev This fixture explicitly finalizes through `syncBacking` before rebalancing.
    function test_FinalizedBackingLoss_AllowsRebalancingAndDeposits() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        _runOutRecoveryWindow(TOKEN1);

        vault.rebalance(NETUID1);

        assertTrue(lens.isBackingIntact(TOKEN1), "the settle took the write-off");
        assertEq(lens.frozenUntil(TOKEN1), 0, "and the token is ordinary again");
        _simulateAlphaDeposit(bob, NETUID1, 1 ether);
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey1, 0);
        assertGt(vault.balanceOf(bob, TOKEN1), 0, "deposits resume");
    }

    /// @dev Expiry alone does not write off the expectation; recovery can still restore it.
    function test_RecoverStray_StillAnswersAfterTheDeadline() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _runOutRecoveryWindow(TOKEN1);
        vm.warp(block.timestamp + 2 days);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "the alpha came home in the overtime");
        assertEq(lens.totalStake(TOKEN1), 30 ether, "and the backing is whole again");
    }

    function test_LateFoundAlpha_IsAWindfallForTheCurrentCohort() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 lost = _getVaultStake(hotkey1, NETUID1);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _runOutRecoveryWindow(TOKEN1);
        vault.rebalance(NETUID1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice), 0);
        uint256 bobShares = _depositAndWrap(bob, NETUID1, 10 ether);
        uint256 navBefore = lens.totalStake(TOKEN1);

        vm.prank(alice);
        vault.recoverStray(TOKEN1, hotkey4);

        assertEq(lens.totalStake(TOKEN1), navBefore + lost, "the find is new backing");
        (uint256 bobsAlpha,) = lens.previewUnwrap(TOKEN1, bobShares);
        assertGt(bobsAlpha, 10 ether, "and it belongs to whoever holds shares now");
        assertEq(vault.balanceOf(alice, TOKEN1), 0, "not to the cohort that bore the loss");
    }

    function test_FullWriteOff_RetiresSharesBesideARetiredValidator() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 15 ether);
        bytes32[] memory recordedHotkeys = _hotkeys(hotkey1, hotkey2, hotkey3);
        for (uint256 i; i < recordedHotkeys.length; ++i) {
            _simulateOffVaultSwap(NETUID1, recordedHotkeys[i], keccak256(abi.encode("retired-beside-stray", i)));
        }
        _runOutRecoveryWindow(TOKEN1);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey3, true);

        uint256 burn = aliceShares / 2;
        vm.prank(alice);
        vault.unwrap(TOKEN1, burn, _toSubstrate(alice), 0);

        assertEq(vault.balanceOf(alice, TOKEN1), aliceShares - burn, "the shares were retired");
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 0, "for no alpha");
    }

    function test_FullWriteOff_ZeroMinAlphaOutExplicitlyRetiresShares() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 15 ether);
        uint256 bobShares = _depositAndWrap(bob, NETUID1, 15 ether);
        bytes32[] memory recordedHotkeys = _hotkeys(hotkey1, hotkey2, hotkey3);
        bytes32[] memory strayHotkeys = new bytes32[](recordedHotkeys.length);
        for (uint256 i; i < recordedHotkeys.length; ++i) {
            strayHotkeys[i] = keccak256(abi.encode("full-write-off-stray", i));
            _simulateOffVaultSwap(NETUID1, recordedHotkeys[i], strayHotkeys[i]);
        }
        _runOutRecoveryWindow(TOKEN1);

        (uint256 aliceQuote,) = lens.previewUnwrap(TOKEN1, aliceShares);
        assertEq(aliceQuote, 0, "the written-off shares should quote zero alpha");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, 0));
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice), 1);
        assertEq(vault.balanceOf(alice, TOKEN1), aliceShares, "positive floor did not preserve shares");

        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice), 0);
        assertEq(vault.balanceOf(alice, TOKEN1), 0, "zero floor did not retire shares");
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 0, "zero-backed exit delivered alpha");

        for (uint256 i; i < strayHotkeys.length; ++i) {
            vault.recoverStray(TOKEN1, strayHotkeys[i]);
        }
        (uint256 bobQuote,) = lens.previewUnwrap(TOKEN1, bobShares);
        assertApproxEqAbs(bobQuote, 30 ether, 3, "late recovery belongs to the remaining shares");
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
            uint256 slotBalance = _getVaultStake(recordedHotkeys[i], NETUID1);
            hidden += slotBalance;
            _simulateOffVaultSwap(NETUID1, recordedHotkeys[i], keccak256(abi.encode("stray", i)));
        }

        _runOutRecoveryWindow(TOKEN1);
        cohorts.backingAfterWriteOff = lens.totalStake(TOKEN1);
        cohorts.finalizedWriteOff = cohorts.backingBefore - cohorts.backingAfterWriteOff;
        assertEq(cohorts.finalizedWriteOff, hidden, "the finalized deficit is exactly the hidden principal");

        cohorts.recapitalizationDeposit = cohorts.backingAfterWriteOff == 0
            ? bound(recapitalizationSeed, CHAIN_MIN_STAKE, 1e9)
            : bound(recapitalizationSeed, cohorts.backingAfterWriteOff / 4, cohorts.backingAfterWriteOff * 4);
        _addRecapitalizer(cohorts);
        for (uint256 i; i < hiddenSlotCount; ++i) {
            vm.prank(bob);
            vault.recoverStray(TOKEN1, keccak256(abi.encode("stray", i)));
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

    function test_LateRecovery_GrowthCanPushWindfallPastWriteOff() public {
        LateCohorts memory cohorts = _openIncumbentCohort(30 ether);

        bytes32 stray = keccak256(abi.encode("grown-stray"));
        _simulateOffVaultSwap(NETUID1, hotkey1, stray);
        uint256 hidden = _getVaultStake(stray, NETUID1);
        uint256 growth = hidden * 3;
        MockStaking(STAKING_PRECOMPILE).setStake(stray, _subnetColdkey(NETUID1), NETUID1, hidden + growth);

        _runOutRecoveryWindow(TOKEN1);
        cohorts.backingAfterWriteOff = lens.totalStake(TOKEN1);
        cohorts.finalizedWriteOff = cohorts.backingBefore - cohorts.backingAfterWriteOff;
        assertEq(cohorts.finalizedWriteOff, hidden, "only the previously anchored principal was written off");

        cohorts.recapitalizationDeposit = cohorts.backingAfterWriteOff;
        _addRecapitalizer(cohorts);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, stray);

        assertEq(
            lens.totalStake(TOKEN1),
            cohorts.backingBefore + cohorts.recapitalizationDeposit + growth,
            "the returned balance includes post-anchor growth"
        );
        uint256 recapitalizerRecoveryGain = _assertLateCohortOutcome(cohorts, hidden + growth);
        assertGt(
            recapitalizerRecoveryGain, cohorts.finalizedWriteOff, "growth can make the windfall exceed the write-off"
        );
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

    function test_Wrap_SweptAlongDepositReturnsThroughReclaim() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        address mailbox = vault.getDepositAddress(bob, NETUID1);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, _toSubstrate(mailbox), NETUID1, 1 ether);

        vm.expectRevert(ZeroAmount.selector);
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey1, 0);

        vm.prank(bob);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey4, _toSubstrate(bob));
        assertEq(_getStake(hotkey4, bob, NETUID1), 1 ether, "the deposit came back to its owner");

        _simulateAlphaDepositHotkey(bob, NETUID1, 1 ether, hotkey2);
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey2, 0);
        assertGt(vault.balanceOf(bob, TOKEN1), 0, "the retried deposit lands");
        assertTrue(lens.isBackingIntact(TOKEN1), "with the record accounting for all of it");
    }

    function test_Wrap_LandsOnTheKeyTheRecordFollows() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        _simulateAlphaDepositHotkey(bob, NETUID1, 6 ether, hotkey1);
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey1, 0);

        assertGt(vault.balanceOf(bob, TOKEN1), 0, "the deposit landed off the chosen name");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing was aimed at the retired key");
        assertTrue(lens.isBackingIntact(TOKEN1), "and the record accounts for all of it");
    }

    function test_SecondLoss_GetsItsOwnClock() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);
        uint256 firstDeadline = lens.frozenUntil(TOKEN1);

        vm.warp(block.timestamp + 1 hours);
        _buildSwapTrail(NETUID1, hotkey2, 2);
        vault.syncBacking(TOKEN1);

        assertEq(
            vault.recordedSlots(TOKEN1)[0].shortSince + vault.recoveryWindow(),
            firstDeadline,
            "the first clock did not move"
        );
        assertEq(lens.frozenUntil(TOKEN1), firstDeadline + 1 hours, "and the second got its own");

        vm.warp(firstDeadline);
        vault.syncBacking(TOKEN1);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);

        vm.warp(firstDeadline + 1 hours);
        vault.syncBacking(TOKEN1);
        assertTrue(lens.isBackingIntact(TOKEN1), "both settle once the later window is out");
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
            vm.expectPartialRevert(BackingShortfall.selector);
            lens.totalStake(TOKEN1);
        } else {
            vault.syncBacking(TOKEN1);
            assertTrue(lens.isBackingIntact(TOKEN1), "the loss is booked from the deadline on");
            assertGt(lens.totalStake(TOKEN1), 0, "and the quote answers on what is left");
        }
    }

    function test_PastTheDeadline_OnlySyncBackingBooksTheLoss() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);
        uint256 located = lens.locatedStake(TOKEN1);

        vm.warp(lens.frozenUntil(TOKEN1));
        vm.expectPartialRevert(BackingShortfall.selector);
        lens.totalStake(TOKEN1);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
        vm.prank(alice);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, hotkey1, owed, 0);
        vm.prank(bob);
        vault.syncBacking(TOKEN1);

        assertEq(lens.totalStake(TOKEN1), located, "the quote answers on what is there");
        assertEq(lens.frozenUntil(TOKEN1), 0, "and no clock is left running");
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);
    }

    function test_RevertWhen_RecoveringFromAKeyASlotResolvesTo() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        vm.expectRevert(NothingToRecover.selector);
        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);

        assertEq(_getVaultStake(hotkey4, NETUID1), owed, "the swapped-to key kept its alpha");
        assertTrue(lens.isBackingIntact(TOKEN1), "and the slot it answers for stayed covered");
    }

    function test_RevertWhen_RecoveringFromACoveredSlotsSurplus() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, _getVaultStake(hotkey2, NETUID1) + 4 ether);
        vault.syncBacking(TOKEN1);

        vm.expectRevert(NothingToRecover.selector);
        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey2);
    }

    function test_BookedLoss_LeavesTheRailsAimingAtAnAttestedKey() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey4, "the record persisted the swap");

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, _subnetColdkey(NETUID1), NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);
        _runOutRecoveryWindow(TOKEN1);
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey4, "the booking left the key alone");

        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey1, "the settle anchored the attested validator");
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "and nothing was aimed at the dead key");

        _simulateAlphaDepositHotkey(bob, NETUID1, 5 ether, hotkey2);
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey2, 0);
        assertGt(vault.balanceOf(bob, TOKEN1), 0, "deposits work again");
    }
}
