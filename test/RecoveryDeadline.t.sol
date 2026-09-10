// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { BackingUnchanged } from "src/VaultErrors.sol";

contract RecoveryDeadlineTest is AlphaVaultTestBase {
    function test_NewLossAtExpiredDeadlineGetsAFullWindow() public {
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

    function test_ObservedRestorationDoesNotExtendButANewLossOfThatSlotDoes() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 firstTip = _buildSwapTrail(NETUID1, hotkey1, 2);
        _buildSwapTrail(NETUID1, hotkey2, 2);
        vault.syncBacking(TOKEN1);
        uint256 deadline = lens.frozenUntil(TOKEN1);

        vm.warp(block.timestamp + 1 hours);
        _simulateOffVaultSwap(NETUID1, firstTip, hotkey1);
        vault.syncBacking(TOKEN1);
        assertEq(lens.frozenUntil(TOKEN1), deadline, "observing a repaired slot does not restart the window");
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);

        vm.warp(block.timestamp + 1 hours);
        _simulateOffVaultSwap(NETUID1, hotkey1, firstTip);
        vault.syncBacking(TOKEN1);
        assertEq(lens.frozenUntil(TOKEN1), block.timestamp + vault.recoveryWindow());
    }

    function test_ResolvedSuccessorDoesNotExtendAnExistingShortfall() public {
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

    function testFuzz_NewSlotExtendsTheDeadlineAcrossTheFullValidatorSet(uint256 rawIndex) public {
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
