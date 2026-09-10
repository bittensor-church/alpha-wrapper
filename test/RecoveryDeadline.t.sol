// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { BackingUnchanged } from "src/VaultErrors.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { MockStaking } from "./mocks/MockStaking.sol";

contract RecoveryDeadlineTest is AlphaVaultTestBase {
    function test_NewLossAtAnExpiredDeadline_GetsAFullWindow() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 firstTip = _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);
        uint256 originalDeadline = lens.frozenUntil(TOKEN1);

        vm.warp(originalDeadline - 1);
        uint256 secondStake = _getVaultStake(hotkey2, NETUID1);
        bytes32 secondTip = _buildSwapTrail(NETUID1, hotkey2, 2);
        _simulateOffVaultSwap(NETUID1, firstTip, hotkey1);

        // A returned and C disappeared: the number of missing slots is unchanged.
        vm.warp(originalDeadline);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingShortfallDeclared(TOKEN1, 30 ether, 30 ether - secondStake);
        vault.syncBacking(TOKEN1);
        uint256 renewedDeadline = block.timestamp + vault.recoveryWindow();
        assertEq(lens.frozenUntil(TOKEN1), renewedDeadline);
        assertEq(_parkedStake(NETUID1), 0, "nothing is written off at the old deadline");

        vm.warp(renewedDeadline - 1);
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
        assertEq(lens.frozenUntil(TOKEN1), renewedDeadline, "the same loss cannot extend the clock");

        vm.warp(renewedDeadline);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, 30 ether, 30 ether - secondStake);
        vault.syncBacking(TOKEN1);
        assertEq(_parkedStake(NETUID1), 30 ether - secondStake);
        assertEq(_getVaultStake(secondTip, NETUID1), secondStake);
        assertEq(lens.frozenUntil(TOKEN1), 0);
    }

    function _twoLosses() private returns (bytes32 firstTip, uint256 deadline) {
        _depositAndWrap(alice, NETUID1, 30 ether);
        firstTip = _buildSwapTrail(NETUID1, hotkey1, 2);
        _buildSwapTrail(NETUID1, hotkey2, 2);
        vault.syncBacking(TOKEN1);
        deadline = lens.frozenUntil(TOKEN1);
    }

    function test_ObservedRepair_DoesNotExtendTheWindow() public {
        (bytes32 firstTip, uint256 deadline) = _twoLosses();
        vm.warp(block.timestamp + 1 hours);
        _simulateOffVaultSwap(NETUID1, firstTip, hotkey1);
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
        assertEq(lens.frozenUntil(TOKEN1), deadline, "observing a repaired slot does not restart the window");
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
    }

    function test_RelostSlot_DoesNotExtendTheWindow() public {
        (bytes32 firstTip, uint256 deadline) = _twoLosses();
        _simulateOffVaultSwap(NETUID1, firstTip, hotkey1);
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
        vm.warp(block.timestamp + 1 hours);
        _simulateOffVaultSwap(NETUID1, hotkey1, firstTip);
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
        assertEq(lens.frozenUntil(TOKEN1), deadline);

        vm.warp(deadline);
        uint256 located = lens.locatedStake(TOKEN1);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, 30 ether, located);
        vault.syncBacking(TOKEN1);
        assertEq(_parkedStake(NETUID1), located, "repeated loss cannot prevent write-off at the deadline");
        assertEq(lens.frozenUntil(TOKEN1), 0);
    }

    function test_NewLossWithARepair_DoesNotResetEarlierSlots() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 firstTip = _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);

        vm.warp(lens.frozenUntil(TOKEN1));
        _simulateOffVaultSwap(NETUID1, firstTip, hotkey1);
        _buildSwapTrail(NETUID1, hotkey2, 2);
        vault.syncBacking(TOKEN1);
        uint256 deadline = lens.frozenUntil(TOKEN1);

        // A is absent from the current short mask but has already used its extension.
        _simulateOffVaultSwap(NETUID1, hotkey1, firstTip);
        vm.warp(deadline);
        uint256 located = lens.locatedStake(TOKEN1);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, 30 ether, located);
        vault.syncBacking(TOKEN1);
        assertEq(_parkedStake(NETUID1), located);
        assertEq(lens.frozenUntil(TOKEN1), 0, "A must not be treated as unseen when C extends the window");
    }

    function test_AnnexObservedRepair_GivesARelostSlotAFullWindow() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 tip = _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);
        uint256 deadline = lens.frozenUntil(TOKEN1);

        _simulateOffVaultSwap(NETUID1, tip, hotkey1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey5, _subnetColdkey(NETUID1), NETUID1, 1 ether);
        _simulateHotkeyOwnerPresent(hotkey5);
        vault.recoverStray(TOKEN1, _hotkeys(hotkey5));
        assertEq(lens.frozenUntil(TOKEN1), deadline, "annexing does not clear the shortfall on file");
        assertEq(_getVaultStake(hotkey5, NETUID1), 0, "the unrelated stray was annexed");

        _simulateOffVaultSwap(NETUID1, hotkey1, tip);
        vm.warp(deadline);
        vault.syncBacking(TOKEN1);
        assertEq(lens.frozenUntil(TOKEN1), block.timestamp + vault.recoveryWindow());
        assertEq(_parkedStake(NETUID1), 0, "a loss after observed full coverage must not be written off early");
    }

    function test_ResolvedSuccessor_DoesNotExtendAnExistingShortfall() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);
        uint256 deadline = lens.frozenUntil(TOKEN1);

        vm.warp(block.timestamp + 1 hours);
        _simulateFollowedSwap(NETUID1, hotkey2, hotkey5);
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
        assertEq(lens.frozenUntil(TOKEN1), deadline, "a located swap is not a new loss");
    }

    function testFuzz_NewSlot_ExtendsTheDeadlineFromAnySlotIndex(uint256 rawIndex) public {
        uint256 netuid = 9;
        _setRegBlock(netuid, 400);
        bytes32[] memory hotkeys = _setValidatorCount(netuid, 64);
        _simulateAlphaDepositHotkey(alice, netuid, 64 ether, hotkeys[0]);
        _wrapHotkey(alice, netuid, hotkeys[0]);
        uint256 tokenId = vault.currentTokenId(netuid);
        uint256 index = bound(rawIndex, 1, 63);
        _buildSwapTrail(netuid, hotkeys[0], 2);
        vault.syncBacking(tokenId);

        vm.warp(lens.frozenUntil(tokenId));
        _buildSwapTrail(netuid, hotkeys[index], 2);
        vault.syncBacking(tokenId);
        assertEq(lens.frozenUntil(tokenId), block.timestamp + vault.recoveryWindow());
        assertEq(_parkedStake(netuid), 0);
    }
}
