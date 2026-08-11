// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { HotkeyLineage } from "src/HotkeyLineage.sol";
import { IStaking } from "src/interfaces/IStaking.sol";

/// @dev Libraries are not callable from `vm` directly; this exposes the internal helpers externally.
contract LineageHarness {
    function walk(IStaking staking, bytes32 hotkey, uint16 netuid, bytes32 vaultColdkey, uint256 tracked, uint8 bound)
        external
        view
        returns (bool, bytes32)
    {
        return HotkeyLineage.walk(staking, hotkey, netuid, vaultColdkey, tracked, bound);
    }

    function sameRoot(IStaking staking, bytes32 a, bytes32 b, uint16 netuid) external view returns (bool) {
        return HotkeyLineage.sameRoot(staking, a, b, netuid);
    }

    function successorLeadsTo(IStaking staking, bytes32 from, bytes32 candidate, uint16 evidenceNetuid)
        external
        view
        returns (bool)
    {
        return HotkeyLineage.successorLeadsTo(staking, from, candidate, evidenceNetuid);
    }
}

contract HotkeyLineageTest is Test {
    MockStaking staking;
    IStaking iStaking;
    LineageHarness harness;

    bytes32 constant FROM = keccak256("from");
    bytes32 constant TO = keccak256("to");
    bytes32 constant ROOT = keccak256("root");
    bytes32 constant VAULT_COLDKEY = keccak256("vault-coldkey");
    uint16 constant NETUID = 1;
    uint8 constant WALK_BOUND = 3;

    function setUp() public {
        staking = new MockStaking();
        iStaking = IStaking(address(staking));
        harness = new LineageHarness();
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

    function test_Walk_OneHopHealsToSuccessor() public {
        bytes32 a = keccak256("A");
        bytes32 b = keccak256("B");
        uint256 tracked = 100e6;
        staking.setHotkeySuccessor(a, NETUID, b);
        staking.setStake(b, VAULT_COLDKEY, NETUID, tracked);
        (bool healed, bytes32 newHotkey) = harness.walk(iStaking, a, NETUID, VAULT_COLDKEY, tracked, WALK_BOUND);
        assertTrue(healed);
        assertEq(newHotkey, b);
    }

    function testFuzz_Walk_HealsWithinBound(uint8 rawHops, uint256 tracked) public {
        uint8 hops = uint8(bound(rawHops, 1, WALK_BOUND));
        tracked = bound(tracked, 1, 1e18);
        bytes32 start = keccak256("start");
        bytes32 h = start;
        bytes32 tip;
        for (uint8 i; i < hops; ++i) {
            bytes32 next = keccak256(abi.encodePacked("hop", i));
            staking.setHotkeySuccessor(h, NETUID, next);
            h = next;
            tip = next;
        }
        staking.setStake(tip, VAULT_COLDKEY, NETUID, tracked);
        (bool healed, bytes32 newHotkey) = harness.walk(iStaking, start, NETUID, VAULT_COLDKEY, tracked, WALK_BOUND);
        assertTrue(healed);
        assertEq(newHotkey, tip);
    }

    function test_Walk_ChecksStakeEveryHop() public {
        bytes32 a = keccak256("A");
        bytes32 b = keccak256("B");
        bytes32 c = keccak256("C");
        uint256 tracked = 50e6;
        staking.setHotkeySuccessor(a, NETUID, b);
        staking.setHotkeySuccessor(b, NETUID, c);
        staking.setStake(b, VAULT_COLDKEY, NETUID, tracked);
        (bool healed, bytes32 newHotkey) = harness.walk(iStaking, a, NETUID, VAULT_COLDKEY, tracked, WALK_BOUND);
        assertTrue(healed);
        assertEq(newHotkey, b);
    }

    function test_Walk_DeadEndReturnsFalse() public view {
        bytes32 a = keccak256("A");
        (bool healed, bytes32 newHotkey) = harness.walk(iStaking, a, NETUID, VAULT_COLDKEY, 1, WALK_BOUND);
        assertFalse(healed);
        assertEq(newHotkey, bytes32(0));
    }

    function test_Walk_ExceedsBoundReturnsFalse() public {
        uint256 tracked = 10e6;
        bytes32 start = keccak256("start");
        bytes32 h = start;
        bytes32 tip;
        uint8 chainLength = WALK_BOUND + 1;
        for (uint8 i; i < chainLength; ++i) {
            bytes32 next = keccak256(abi.encodePacked("hop", i));
            staking.setHotkeySuccessor(h, NETUID, next);
            h = next;
            tip = next;
        }
        staking.setStake(tip, VAULT_COLDKEY, NETUID, tracked);
        (bool healed, bytes32 newHotkey) = harness.walk(iStaking, start, NETUID, VAULT_COLDKEY, tracked, WALK_BOUND);
        assertFalse(healed);
        assertEq(newHotkey, bytes32(0));
    }

    function test_SameRoot_AbsentFoldsToSelfBothSides() public {
        bytes32 a = keccak256("A");
        bytes32 b = keccak256("B");
        bytes32 x = keccak256("X");
        staking.setHotkeyRoot(b, NETUID, a);
        assertTrue(harness.sameRoot(iStaking, a, b, NETUID));
        assertFalse(harness.sameRoot(iStaking, a, x, NETUID));
    }

    function test_SameRoot_ForkSharesRoot() public {
        bytes32 a = keccak256("A");
        bytes32 b = keccak256("B");
        bytes32 c = keccak256("C");
        staking.setHotkeyRoot(b, NETUID, a);
        staking.setHotkeyRoot(c, NETUID, a);
        assertTrue(harness.sameRoot(iStaking, b, c, NETUID));
    }

    function test_SuccessorLeadsTo_DirectEdge() public {
        bytes32 from = keccak256("from-edge");
        bytes32 candidate = keccak256("candidate-edge");
        staking.setHotkeySuccessor(from, NETUID, candidate);
        assertTrue(harness.successorLeadsTo(iStaking, from, candidate, NETUID));
        assertFalse(harness.successorLeadsTo(iStaking, from, keccak256("unrelated"), NETUID));
    }

    function test_SuccessorLeadsTo_ViaRoot() public {
        bytes32 from = keccak256("from-root");
        bytes32 candidate = keccak256("candidate-root");
        bytes32 root = keccak256("shared-root");
        staking.setHotkeyRoot(from, NETUID, root);
        staking.setHotkeyRoot(candidate, NETUID, root);
        assertTrue(harness.successorLeadsTo(iStaking, from, candidate, NETUID));
    }
}
