// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { BasicValidatorRegistry } from "src/BasicValidatorRegistry.sol";
import { IValidatorRegistry } from "src/interfaces/IValidatorRegistry.sol";
import { IStaking, STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract BasicValidatorRegistryTest is Test {
    BasicValidatorRegistry internal registry;
    address internal admin = makeAddr("admin");
    bytes32 internal constant HOTKEY = keccak256("hotkey");
    bytes32 internal constant OWNER = keccak256("owner");
    uint256 internal constant NETUID = 1;

    function setUp() public {
        registry = new BasicValidatorRegistry(admin);
        vm.etch(STAKING_PRECOMPILE, hex"00");
        _owner(HOTKEY, true, OWNER);
    }

    function _owner(bytes32 hotkey, bool exists, bytes32 owner) internal {
        vm.mockCall(STAKING_PRECOMPILE, abi.encodeCall(IStaking.getHotkeyOwner, (hotkey)), abi.encode(exists, owner));
    }

    function _set(uint256 netuid, bytes32 hotkey) internal {
        vm.prank(admin);
        registry.setValidator(netuid, hotkey);
    }

    function _assertValidator(uint256 netuid, bytes32 hotkey, bytes32 owner, uint256 nonce) internal view {
        IValidatorRegistry asInterface = IValidatorRegistry(address(registry));
        (bytes32[] memory keys, uint16[] memory weights, bytes32[] memory owners) = asInterface.getValidators(netuid);
        uint256 count = hotkey == bytes32(0) ? 0 : 1;
        assertEq(keys.length, count);
        assertEq(weights.length, count);
        assertEq(owners.length, count);
        if (count != 0) {
            assertEq(keys[0], hotkey);
            assertEq(weights[0], 10_000);
            assertEq(owners[0], owner);
        }
        assertEq(asInterface.nonces(netuid), nonce);
    }

    function test_constructorRecordsAdmin() public view {
        assertEq(registry.admin(), admin);
    }

    function test_constructorRejectsZeroAdmin() public {
        vm.expectRevert(BasicValidatorRegistry.ZeroAddress.selector);
        new BasicValidatorRegistry(address(0));
    }

    function test_nonAdminCannotConfigureAnEmptySubnet() public {
        vm.expectRevert(BasicValidatorRegistry.Unauthorized.selector);
        registry.setValidator(NETUID, HOTKEY);
        _assertValidator(NETUID, 0, 0, 0);
    }

    function test_ownerExistenceUsesThePrecompileFlag() public {
        // Subtensor returns the stored AccountId independently of the existence flag.
        _owner(HOTKEY, true, 0);
        _set(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, 0, 1);
    }

    function test_unconfiguredSubnetReturnsEmptyArraysAndZeroNonce() public view {
        _assertValidator(NETUID, 0, 0, 0);
        _assertValidator(type(uint256).max, 0, 0, 0);
    }

    function test_firstUpdateIsImmediateAndEmitsOwnerAndNonce() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit BasicValidatorRegistry.ValidatorUpdated(NETUID, 1, HOTKEY, OWNER);
        _set(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, OWNER, 1);
    }

    function test_rotationReplacesHotkeyAndOwnerWithoutAppending() public {
        _set(NETUID, HOTKEY);
        bytes32 nextHotkey = keccak256("next");
        bytes32 nextOwner = keccak256("nextOwner");
        _owner(nextHotkey, true, nextOwner);
        vm.expectEmit(true, false, false, true, address(registry));
        emit BasicValidatorRegistry.ValidatorUpdated(NETUID, 2, nextHotkey, nextOwner);
        _set(NETUID, nextHotkey);
        _assertValidator(NETUID, nextHotkey, nextOwner, 2);
    }

    function test_sameHotkeyRefreshesOwnerAndNonce() public {
        _set(NETUID, HOTKEY);
        _set(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, OWNER, 2);
        bytes32 nextOwner = keccak256("nextOwner");
        _owner(HOTKEY, true, nextOwner);
        _assertValidator(NETUID, HOTKEY, OWNER, 2);
        _set(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, nextOwner, 3);
    }

    function test_readsRetainRecordedOwnerWhenHotkeyBecomesOwnerless() public {
        _set(NETUID, HOTKEY);
        _owner(HOTKEY, false, 0);
        _assertValidator(NETUID, HOTKEY, OWNER, 1);
        vm.expectRevert(abi.encodeWithSelector(BasicValidatorRegistry.OwnerlessHotkey.selector, HOTKEY));
        _set(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, OWNER, 1);
    }

    function test_subnetsHaveIndependentValidatorsAndNonces() public {
        _set(NETUID, HOTKEY);
        _set(2, HOTKEY);
        bytes32 nextHotkey = keccak256("next");
        _owner(nextHotkey, true, OWNER);
        _set(NETUID, nextHotkey);
        _assertValidator(NETUID, nextHotkey, OWNER, 2);
        _assertValidator(2, HOTKEY, OWNER, 1);
        _assertValidator(3, 0, 0, 0);
    }

    function test_acceptsNetuidBoundaries() public {
        _set(0, HOTKEY);
        _set(type(uint16).max, HOTKEY);
        _assertValidator(0, HOTKEY, OWNER, 1);
        _assertValidator(type(uint16).max, HOTKEY, OWNER, 1);
    }

    function test_rejectsOutOfRangeNetuid() public {
        vm.expectRevert(BasicValidatorRegistry.NetuidOutOfRange.selector);
        _set(uint256(type(uint16).max) + 1, HOTKEY);
        _assertValidator(uint256(type(uint16).max) + 1, 0, 0, 0);
    }

    function test_rejectsZeroHotkeyWithoutClearingExistingValidator() public {
        _set(NETUID, HOTKEY);
        vm.expectRevert(BasicValidatorRegistry.ZeroHotkey.selector);
        _set(NETUID, 0);
        _assertValidator(NETUID, HOTKEY, OWNER, 1);
    }

    function test_rejectsOwnerlessHotkeyOnFirstUpdate() public {
        _owner(HOTKEY, false, OWNER);
        vm.expectRevert(abi.encodeWithSelector(BasicValidatorRegistry.OwnerlessHotkey.selector, HOTKEY));
        _set(NETUID, HOTKEY);
        _assertValidator(NETUID, 0, 0, 0);
    }

    function test_precompileFailurePreservesExistingValidatorAndNonce() public {
        _set(NETUID, HOTKEY);
        vm.mockCallRevert(
            STAKING_PRECOMPILE, abi.encodeCall(IStaking.getHotkeyOwner, (HOTKEY)), abi.encode("unavailable")
        );
        vm.expectRevert(abi.encode("unavailable"));
        _set(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, OWNER, 1);
    }

    function test_adminCannotBeTransferredOrRenounced() public {
        vm.startPrank(admin);
        (bool transferred,) =
            address(registry).call(abi.encodeWithSignature("transferOwnership(address)", address(this)));
        (bool renounced,) = address(registry).call(abi.encodeWithSignature("renounceOwnership()"));
        vm.stopPrank();
        assertFalse(transferred);
        assertFalse(renounced);
        assertEq(registry.admin(), admin);
        _set(NETUID, HOTKEY);
        vm.expectRevert(BasicValidatorRegistry.Unauthorized.selector);
        registry.setValidator(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, OWNER, 1);
    }

    function testFuzz_onlyAdminCanUpdate(address caller) public {
        vm.assume(caller != admin);
        _set(NETUID, HOTKEY);
        vm.prank(caller);
        vm.expectRevert(BasicValidatorRegistry.Unauthorized.selector);
        registry.setValidator(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, OWNER, 1);
    }

    function testFuzz_validSingleValidator(uint16 netuid, bytes32 hotkey, bytes32 owner) public {
        vm.assume(hotkey != 0);
        _owner(hotkey, true, owner);
        _set(netuid, hotkey);
        _assertValidator(netuid, hotkey, owner, 1);
    }

    function testFuzz_rejectsOutOfRangeNetuid(uint256 netuid) public {
        netuid = bound(netuid, uint256(type(uint16).max) + 1, type(uint256).max);
        vm.expectRevert(BasicValidatorRegistry.NetuidOutOfRange.selector);
        _set(netuid, HOTKEY);
        _assertValidator(netuid, 0, 0, 0);
    }
}
