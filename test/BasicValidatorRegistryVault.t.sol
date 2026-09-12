// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { BasicValidatorRegistry } from "src/BasicValidatorRegistry.sol";
import { ChosenHotkeyNotInSet } from "src/VaultErrors.sol";

contract BasicValidatorRegistryVaultTest is AlphaVaultTestBase {
    BasicValidatorRegistry private basicRegistry;

    function setUp() public override {
        super.setUp();
        basicRegistry = new BasicValidatorRegistry(address(this));
        basicRegistry.setValidator(NETUID1, hotkey1);
        basicRegistry.setValidator(NETUID2, hotkey2);
        (vault, lens) = _deployVaultAndLens(address(basicRegistry));
    }

    function test_wrapAllocatesEverythingToTheSoleValidator() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        assertEq(_getVaultStake(hotkey1, NETUID1), 10 * ALPHA);
        assertEq(_getVaultStake(hotkey2, NETUID1), 0);
        assertEq(lens.totalStake(TOKEN1), 10 * ALPHA);
        assertEq(_lastSeen(TOKEN1).length, 1);
    }

    function test_wrapRejectsAnUnlistedHotkeyWithoutCollectingTheDeposit() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 * ALPHA, hotkey2);
        vm.expectRevert(ChosenHotkeyNotInSet.selector);
        _wrapHotkey(alice, NETUID1, hotkey2);
        assertEq(_getStakeForColdkey(hotkey2, _mailboxColdkey(alice, NETUID1), NETUID1), 10 * ALPHA);
        assertEq(vault.balanceOf(alice, TOKEN1), 0);
    }

    function test_rotationRebalancesWithoutChangingSharesOrOtherSubnet() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        _depositAndWrap(bob, NETUID2, 20 * ALPHA);
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        basicRegistry.setValidator(NETUID1, hotkey3);
        vault.rebalance(NETUID1);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(_getVaultStake(hotkey3, NETUID1), 10 * ALPHA);
        assertEq(vault.balanceOf(alice, TOKEN1), shares);
        assertEq(_getVaultStake(hotkey2, NETUID2), 20 * ALPHA);
        assertEq(_lastSeen(TOKEN1).length, 1);
    }

    function test_alphaExitConsolidatesTheRotatedValidator() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        basicRegistry.setValidator(NETUID1, hotkey3);
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 1);
        assertEq(vault.balanceOf(alice, TOKEN1), 0);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(_getStakeForColdkey(hotkey3, _toSubstrate(alice), NETUID1), 10 * ALPHA);
    }

    function test_taoExitDrainsTheRotatedValidator() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        basicRegistry.setValidator(NETUID1, hotkey3);
        uint256 balanceBefore = alice.balance;
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);
        assertEq(vault.balanceOf(alice, TOKEN1), 0);
        assertEq(lens.totalStake(TOKEN1), 0);
        assertGt(alice.balance, balanceBefore);
    }

    function test_freshAdminUpdateReleasesRecoveredParking() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        vault.syncBacking(TOKEN1);
        vault.recoverStray(TOKEN1, hotkey4);
        vault.syncBacking(TOKEN1);
        assertTrue(lens.awaitingAttestation(TOKEN1));
        assertEq(_parkedStake(NETUID1), 10 * ALPHA);

        _recordHotkeyOwner(hotkey4);
        basicRegistry.setValidator(NETUID1, hotkey4);
        assertFalse(lens.awaitingAttestation(TOKEN1));
        vault.rebalance(NETUID1);
        assertEq(_parkedStake(NETUID1), 0);
        assertEq(_getVaultStake(hotkey4, NETUID1), 10 * ALPHA);
        assertEq(vault.balanceOf(alice, TOKEN1), shares);
        assertTrue(lens.isBackingIntact(TOKEN1));
    }
}
