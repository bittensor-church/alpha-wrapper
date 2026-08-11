// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { MockStaking } from "./mocks/MockStaking.sol";

contract HotkeyLineageTest is Test {
    MockStaking staking;

    bytes32 constant FROM = keccak256("from");
    bytes32 constant TO = keccak256("to");
    bytes32 constant ROOT = keccak256("root");
    uint16 constant NETUID = 1;

    function setUp() public {
        staking = new MockStaking();
    }

    function test_MockSuccessor_AbsentReturnsFalseZero() public view {
        (bool exists, bytes32 to) = staking.getHotkeySuccessor(FROM, NETUID);
        assertFalse(exists);
        assertEq(to, bytes32(0));
    }

    function test_MockSuccessor_SetRoundTrips() public {
        staking.setHotkeySuccessor(FROM, NETUID, TO);
        (bool exists, bytes32 to) = staking.getHotkeySuccessor(FROM, NETUID);
        assertTrue(exists);
        assertEq(to, TO);
    }

    function test_MockRoot_AbsentReturnsFalseZero() public view {
        (bool exists, bytes32 root) = staking.getHotkeyRoot(FROM, NETUID);
        assertFalse(exists);
        assertEq(root, bytes32(0));
    }

    function test_MockRoot_SetRoundTrips() public {
        staking.setHotkeyRoot(FROM, NETUID, ROOT);
        (bool exists, bytes32 root) = staking.getHotkeyRoot(FROM, NETUID);
        assertTrue(exists);
        assertEq(root, ROOT);
    }
}
