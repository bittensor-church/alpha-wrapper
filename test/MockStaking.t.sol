// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// @dev The mock may only accept what the chain accepts: a vault test that passes here because the
///      fixture is lenient would fail against a real node. These pin the ownership gate every stake
///      operation runs and the rules the coldkey-swap fixture reproduces.
contract MockStakingTest is AlphaVaultTestBase {
    MockStaking internal mock;
    bytes32 internal constant STRAY_HOTKEY = keccak256("stray-hotkey");
    bytes32 internal ownColdkey;

    function setUp() public override {
        super.setUp();
        mock = MockStaking(STAKING_PRECOMPILE);
        ownColdkey = _toSubstrate(address(this));
    }

    receive() external payable { }

    function test_StakeOperations_RefuseAHotkeyWithNoOwnerRecord() public {
        mock.setStake(STRAY_HOTKEY, ownColdkey, NETUID1, 5 ether);
        (bool exists, bytes32 owner) = mock.getHotkeyOwner(STRAY_HOTKEY);
        assertFalse(exists, "an unclaimed hotkey has no owner");
        assertEq(owner, bytes32(0));

        vm.expectRevert(bytes("MockStaking: hotkey has no owner"));
        mock.moveStake(STRAY_HOTKEY, hotkey1, NETUID1, NETUID1, 1 ether);
        vm.expectRevert(bytes("MockStaking: hotkey has no owner"));
        mock.moveStake(hotkey1, STRAY_HOTKEY, NETUID1, NETUID1, 1 ether);
        vm.expectRevert(bytes("MockStaking: hotkey has no owner"));
        mock.transferStake(_toSubstrate(bob), STRAY_HOTKEY, NETUID1, NETUID1, 1 ether);
        vm.expectRevert(bytes("MockStaking: hotkey has no owner"));
        mock.removeStake(STRAY_HOTKEY, 5 ether, NETUID1);
    }

    function test_StakeOperations_AcceptAnAssociatedHotkey() public {
        mock.setStake(STRAY_HOTKEY, ownColdkey, NETUID1, 5 ether);
        mock.associate(STRAY_HOTKEY, ownColdkey);

        (bool exists, bytes32 owner) = mock.getHotkeyOwner(STRAY_HOTKEY);
        assertTrue(exists, "association records an owner");
        assertEq(owner, ownColdkey);

        mock.moveStake(STRAY_HOTKEY, hotkey1, NETUID1, NETUID1, 2 ether);
        mock.transferStake(_toSubstrate(bob), STRAY_HOTKEY, NETUID1, NETUID1, 1 ether);
        mock.removeStake(STRAY_HOTKEY, 2 ether, NETUID1);

        assertEq(mock.getStake(hotkey1, ownColdkey, NETUID1), 2 ether);
        assertEq(mock.getStake(STRAY_HOTKEY, _toSubstrate(bob), NETUID1), 1 ether);
        assertEq(mock.getStake(STRAY_HOTKEY, ownColdkey, NETUID1), 0);
    }

    function test_ColdkeySwap_MovesOwnedHotkeysToTheDestination() public {
        bytes32 source = _toSubstrate(bob);
        bytes32 destination = keccak256("destination-coldkey");
        bytes32 settledHotkey = keccak256("destination-owned-hotkey");
        mock.setHotkeyOwner(STRAY_HOTKEY, source);
        mock.setHotkeyOwner(settledHotkey, destination);
        mock.setStake(STRAY_HOTKEY, source, NETUID1, 5 ether);

        mock.simulateColdkeySwap(source, destination, NETUID1, _hotkeys(STRAY_HOTKEY));

        (bool exists, bytes32 owner) = mock.getHotkeyOwner(STRAY_HOTKEY);
        assertTrue(exists);
        assertEq(owner, destination, "the swapped hotkey answers to the destination");
        bytes32[] memory owned = mock.getOwnedHotkeys(destination);
        assertEq(owned.length, 2, "the destination keeps its own hotkeys and gains the source's");
        assertEq(owned[0], settledHotkey);
        assertEq(owned[1], STRAY_HOTKEY);
        assertEq(mock.getOwnedHotkeys(source).length, 0);
        assertEq(mock.getStake(STRAY_HOTKEY, destination, NETUID1), 5 ether);
        assertEq(mock.getStake(STRAY_HOTKEY, source, NETUID1), 0);
    }

    function test_ColdkeySwap_MovesAHotkeySeededWithoutAnExplicitOwner() public {
        mock.setHotkeyOwned(STRAY_HOTKEY, true);
        bytes32 derivedOwner = mock.ownerOf(STRAY_HOTKEY);
        bytes32 destination = keccak256("fresh-destination-coldkey");

        mock.simulateColdkeySwap(derivedOwner, destination, NETUID1, new bytes32[](0));

        (, bytes32 owner) = mock.getHotkeyOwner(STRAY_HOTKEY);
        assertEq(owner, destination, "the reported owner moves with the swap");
        assertEq(mock.getOwnedHotkeys(derivedOwner).length, 0);
        assertEq(mock.getOwnedHotkeys(destination).length, 1);
    }

    function test_ColdkeySwap_LeavesAReassignedHotkeyWithItsCurrentOwner() public {
        bytes32 first = keccak256("first-owner");
        bytes32 second = keccak256("second-owner");
        bytes32 destination = keccak256("swap-destination");
        mock.setHotkeyOwner(STRAY_HOTKEY, first);
        mock.setHotkeyOwner(STRAY_HOTKEY, second);

        mock.simulateColdkeySwap(first, destination, NETUID1, new bytes32[](0));

        (, bytes32 owner) = mock.getHotkeyOwner(STRAY_HOTKEY);
        assertEq(owner, second, "a swap of the former owner leaves the current owner's key alone");
        assertEq(mock.getOwnedHotkeys(first).length, 0);
        assertEq(mock.getOwnedHotkeys(second).length, 1);
        assertEq(mock.getOwnedHotkeys(destination).length, 0);
    }

    function test_Association_ReplacesTheDeletedOwnersIndexEntry() public {
        bytes32 first = keccak256("first-owner");
        bytes32 second = keccak256("second-owner");
        mock.setHotkeyOwner(STRAY_HOTKEY, first);
        mock.setHotkeyDeleted(STRAY_HOTKEY, true);
        assertEq(mock.getOwnedHotkeys(first).length, 0, "a deleted record leaves the index");

        mock.associate(STRAY_HOTKEY, second);

        (, bytes32 owner) = mock.getHotkeyOwner(STRAY_HOTKEY);
        assertEq(owner, second);
        assertEq(mock.getOwnedHotkeys(first).length, 0);
        assertEq(mock.getOwnedHotkeys(second).length, 1);
    }

    function test_RevertWhen_SwappingIntoAHotkeyAccount() public {
        vm.expectRevert(bytes("MockStaking: NewColdKeyIsHotkey"));
        mock.simulateColdkeySwap(_toSubstrate(bob), hotkey1, NETUID1, _hotkeys(hotkey1));
    }

    function test_RevertWhen_SwappingIntoAColdkeyHoldingStake() public {
        bytes32 destination = keccak256("staked-destination-coldkey");
        mock.setStake(hotkey1, destination, NETUID1, 1 ether);
        vm.expectRevert(bytes("MockStaking: ColdKeyAlreadyAssociated"));
        mock.simulateColdkeySwap(_toSubstrate(bob), destination, NETUID1, _hotkeys(hotkey1));
    }
}
