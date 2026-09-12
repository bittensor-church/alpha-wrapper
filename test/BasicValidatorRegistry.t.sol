// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { NetuidOutOfRange, ZeroHotkey } from "src/VaultErrors.sol";
import { Test } from "forge-std/Test.sol";
import { BasicValidatorRegistry } from "src/BasicValidatorRegistry.sol";
import { IValidatorRegistry } from "src/interfaces/IValidatorRegistry.sol";
import { IStaking, STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract BasicValidatorRegistryTest is Test {
    BasicValidatorRegistry internal registry;
    address internal registryOwner = makeAddr("registryOwner");
    bytes32 internal constant HOTKEY = keccak256("hotkey");
    bytes32 internal constant HOTKEY_COLDKEY = keccak256("owner");
    uint256 internal constant NETUID = 1;

    function setUp() public {
        registry = new BasicValidatorRegistry(registryOwner);
        vm.etch(STAKING_PRECOMPILE, hex"00");
        _mockHotkeyOwner(HOTKEY, true, HOTKEY_COLDKEY);
    }

    function _mockHotkeyOwner(bytes32 hotkey, bool exists, bytes32 owner) internal {
        vm.mockCall(STAKING_PRECOMPILE, abi.encodeCall(IStaking.getHotkeyOwner, (hotkey)), abi.encode(exists, owner));
    }

    function _setValidatorAsOwner(uint256 netuid, bytes32 hotkey) internal {
        vm.prank(registryOwner);
        registry.setValidator(netuid, hotkey);
    }

    function _assertValidator(uint256 netuid, bytes32 hotkey, bytes32 owner, uint256 nonce) internal view {
        IValidatorRegistry asInterface = IValidatorRegistry(address(registry));
        (bytes32[] memory keys, uint16[] memory weights, bytes32[] memory owners) = asInterface.getValidators(netuid);
        assertEq(keys.length, 1);
        assertEq(weights.length, 1);
        assertEq(owners.length, 1);
        assertEq(keys[0], hotkey);
        assertEq(weights[0], 10_000);
        assertEq(owners[0], owner);
        assertEq(asInterface.nonces(netuid), nonce);
    }

    function _assertUnconfigured(uint256 netuid) internal view {
        (bytes32[] memory keys, uint16[] memory weights, bytes32[] memory owners) = registry.getValidators(netuid);
        assertEq(keys.length, 0);
        assertEq(weights.length, 0);
        assertEq(owners.length, 0);
        assertEq(registry.nonces(netuid), 0);
    }

    function test_Constructor_RecordsOwner() public view {
        assertEq(registry.owner(), registryOwner);
    }

    function test_RevertWhen_InitialOwnerIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new BasicValidatorRegistry(address(0));
    }

    function test_RevertWhen_NonOwnerConfiguresSubnet() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        registry.setValidator(NETUID, HOTKEY);
        _assertUnconfigured(NETUID);
    }

    function test_SetValidator_UsesOwnerExistenceFlag() public {
        // Subtensor returns the stored AccountId independently of the existence flag.
        _mockHotkeyOwner(HOTKEY, true, 0);
        _setValidatorAsOwner(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, 0, 1);
    }

    function test_GetValidators_UnconfiguredSubnetIsEmpty() public view {
        _assertUnconfigured(NETUID);
        _assertUnconfigured(type(uint256).max);
    }

    function test_SetValidator_ImmediatelyRecordsOwnerAndNonce() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit BasicValidatorRegistry.ValidatorUpdated(NETUID, 1, HOTKEY, HOTKEY_COLDKEY);
        _setValidatorAsOwner(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, HOTKEY_COLDKEY, 1);
    }

    function test_SetValidator_ReplacesHotkeyAndOwner() public {
        _setValidatorAsOwner(NETUID, HOTKEY);
        bytes32 nextHotkey = keccak256("next");
        bytes32 nextOwner = keccak256("nextOwner");
        _mockHotkeyOwner(nextHotkey, true, nextOwner);
        vm.expectEmit(true, false, false, true, address(registry));
        emit BasicValidatorRegistry.ValidatorUpdated(NETUID, 2, nextHotkey, nextOwner);
        _setValidatorAsOwner(NETUID, nextHotkey);
        _assertValidator(NETUID, nextHotkey, nextOwner, 2);
    }

    function test_SetValidator_SameHotkeyRefreshesOwnerAndNonce() public {
        _setValidatorAsOwner(NETUID, HOTKEY);
        _setValidatorAsOwner(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, HOTKEY_COLDKEY, 2);
        bytes32 nextOwner = keccak256("nextOwner");
        _mockHotkeyOwner(HOTKEY, true, nextOwner);
        _assertValidator(NETUID, HOTKEY, HOTKEY_COLDKEY, 2);
        _setValidatorAsOwner(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, nextOwner, 3);
    }

    function test_GetValidators_PreservesOwnerSnapshot() public {
        _setValidatorAsOwner(NETUID, HOTKEY);
        _mockHotkeyOwner(HOTKEY, false, 0);
        _assertValidator(NETUID, HOTKEY, HOTKEY_COLDKEY, 1);
        vm.expectRevert(abi.encodeWithSelector(BasicValidatorRegistry.OwnerlessHotkey.selector, HOTKEY));
        _setValidatorAsOwner(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, HOTKEY_COLDKEY, 1);
    }

    function test_SetValidator_SubnetsAreIndependent() public {
        _setValidatorAsOwner(NETUID, HOTKEY);
        _setValidatorAsOwner(2, HOTKEY);
        bytes32 nextHotkey = keccak256("next");
        _mockHotkeyOwner(nextHotkey, true, HOTKEY_COLDKEY);
        _setValidatorAsOwner(NETUID, nextHotkey);
        _assertValidator(NETUID, nextHotkey, HOTKEY_COLDKEY, 2);
        _assertValidator(2, HOTKEY, HOTKEY_COLDKEY, 1);
        _assertUnconfigured(3);
    }

    function test_SetValidator_AcceptsNetuidBoundaries() public {
        _setValidatorAsOwner(0, HOTKEY);
        _setValidatorAsOwner(type(uint16).max, HOTKEY);
        _assertValidator(0, HOTKEY, HOTKEY_COLDKEY, 1);
        _assertValidator(type(uint16).max, HOTKEY, HOTKEY_COLDKEY, 1);
    }

    function test_RevertWhen_NetuidIsOutOfRange() public {
        vm.expectRevert(NetuidOutOfRange.selector);
        _setValidatorAsOwner(uint256(type(uint16).max) + 1, HOTKEY);
        _assertUnconfigured(uint256(type(uint16).max) + 1);
    }

    function test_RevertWhen_HotkeyIsZero() public {
        _setValidatorAsOwner(NETUID, HOTKEY);
        vm.expectRevert(ZeroHotkey.selector);
        _setValidatorAsOwner(NETUID, 0);
        _assertValidator(NETUID, HOTKEY, HOTKEY_COLDKEY, 1);
    }

    function test_RevertWhen_HotkeyHasNoOwner() public {
        _mockHotkeyOwner(HOTKEY, false, HOTKEY_COLDKEY);
        vm.expectRevert(abi.encodeWithSelector(BasicValidatorRegistry.OwnerlessHotkey.selector, HOTKEY));
        _setValidatorAsOwner(NETUID, HOTKEY);
        _assertUnconfigured(NETUID);
    }

    function test_RevertWhen_OwnerPrecompileFails() public {
        _setValidatorAsOwner(NETUID, HOTKEY);
        vm.mockCallRevert(
            STAKING_PRECOMPILE, abi.encodeCall(IStaking.getHotkeyOwner, (HOTKEY)), abi.encode("unavailable")
        );
        vm.expectRevert(abi.encode("unavailable"));
        _setValidatorAsOwner(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, HOTKEY_COLDKEY, 1);
    }

    function test_TransferOwnership_RequiresAcceptanceAndPreservesOwnerAuthority() public {
        address successor = makeAddr("successor");
        vm.expectEmit(true, true, false, true, address(registry));
        emit Ownable2Step.OwnershipTransferStarted(registryOwner, successor);
        vm.prank(registryOwner);
        registry.transferOwnership(successor);
        assertEq(registry.owner(), registryOwner);
        assertEq(registry.pendingOwner(), successor);

        vm.prank(successor);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, successor));
        registry.setValidator(NETUID, HOTKEY);
        _setValidatorAsOwner(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, HOTKEY_COLDKEY, 1);
    }

    function test_AcceptOwnership_TransfersUpdateAuthorityWithoutChangingValidators() public {
        address successor = makeAddr("successor");
        _setValidatorAsOwner(NETUID, HOTKEY);
        _setValidatorAsOwner(2, HOTKEY);
        vm.prank(registryOwner);
        registry.transferOwnership(successor);
        vm.expectEmit(true, true, false, true, address(registry));
        emit Ownable.OwnershipTransferred(registryOwner, successor);
        vm.prank(successor);
        registry.acceptOwnership();
        assertEq(registry.owner(), successor);
        assertEq(registry.pendingOwner(), address(0));
        _assertValidator(NETUID, HOTKEY, HOTKEY_COLDKEY, 1);
        _assertValidator(2, HOTKEY, HOTKEY_COLDKEY, 1);

        vm.prank(registryOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, registryOwner));
        registry.setValidator(NETUID, HOTKEY);
        vm.prank(successor);
        registry.setValidator(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, HOTKEY_COLDKEY, 2);
        _assertValidator(2, HOTKEY, HOTKEY_COLDKEY, 1);
    }

    function test_RevertWhen_OwnerRenouncesWithoutPendingSuccessor() public {
        vm.prank(registryOwner);
        vm.expectRevert(BasicValidatorRegistry.RenunciationDisabled.selector);
        registry.renounceOwnership();
        assertEq(registry.owner(), registryOwner);
        assertEq(registry.pendingOwner(), address(0));
        _setValidatorAsOwner(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, HOTKEY_COLDKEY, 1);
    }

    function testFuzz_RevertWhen_CallerIsNotOwner(address caller) public {
        vm.assume(caller != registryOwner);
        _setValidatorAsOwner(NETUID, HOTKEY);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        registry.setValidator(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, HOTKEY_COLDKEY, 1);
    }

    function testFuzz_SetValidator_ValidSingleValidator(uint16 netuid, bytes32 hotkey, bytes32 owner) public {
        hotkey = bytes32(bound(uint256(hotkey), 1, type(uint256).max));
        _mockHotkeyOwner(hotkey, true, owner);
        _setValidatorAsOwner(netuid, hotkey);
        _assertValidator(netuid, hotkey, owner, 1);
    }

    function testFuzz_RevertWhen_NetuidIsOutOfRange(uint256 netuid) public {
        netuid = bound(netuid, uint256(type(uint16).max) + 1, type(uint256).max);
        vm.expectRevert(NetuidOutOfRange.selector);
        _setValidatorAsOwner(netuid, HOTKEY);
        _assertUnconfigured(netuid);
    }
}
