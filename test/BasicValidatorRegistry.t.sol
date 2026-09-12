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

    function test_Constructor_RecordsOwner() public view {
        assertEq(registry.owner(), admin);
    }

    function test_RevertWhen_InitialOwnerIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new BasicValidatorRegistry(address(0));
    }

    function test_RevertWhen_NonOwnerConfiguresSubnet() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        registry.setValidator(NETUID, HOTKEY);
        _assertValidator(NETUID, 0, 0, 0);
    }

    function test_SetValidator_UsesOwnerExistenceFlag() public {
        // Subtensor returns the stored AccountId independently of the existence flag.
        _owner(HOTKEY, true, 0);
        _set(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, 0, 1);
    }

    function test_GetValidators_UnconfiguredSubnetIsEmpty() public view {
        _assertValidator(NETUID, 0, 0, 0);
        _assertValidator(type(uint256).max, 0, 0, 0);
    }

    function test_SetValidator_ImmediatelyRecordsOwnerAndNonce() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit BasicValidatorRegistry.ValidatorUpdated(NETUID, 1, HOTKEY, OWNER);
        _set(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, OWNER, 1);
    }

    function test_SetValidator_ReplacesHotkeyAndOwner() public {
        _set(NETUID, HOTKEY);
        bytes32 nextHotkey = keccak256("next");
        bytes32 nextOwner = keccak256("nextOwner");
        _owner(nextHotkey, true, nextOwner);
        vm.expectEmit(true, false, false, true, address(registry));
        emit BasicValidatorRegistry.ValidatorUpdated(NETUID, 2, nextHotkey, nextOwner);
        _set(NETUID, nextHotkey);
        _assertValidator(NETUID, nextHotkey, nextOwner, 2);
    }

    function test_SetValidator_SameHotkeyRefreshesOwnerAndNonce() public {
        _set(NETUID, HOTKEY);
        _set(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, OWNER, 2);
        bytes32 nextOwner = keccak256("nextOwner");
        _owner(HOTKEY, true, nextOwner);
        _assertValidator(NETUID, HOTKEY, OWNER, 2);
        _set(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, nextOwner, 3);
    }

    function test_GetValidators_PreservesOwnerSnapshot() public {
        _set(NETUID, HOTKEY);
        _owner(HOTKEY, false, 0);
        _assertValidator(NETUID, HOTKEY, OWNER, 1);
        vm.expectRevert(abi.encodeWithSelector(BasicValidatorRegistry.OwnerlessHotkey.selector, HOTKEY));
        _set(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, OWNER, 1);
    }

    function test_SetValidator_SubnetsAreIndependent() public {
        _set(NETUID, HOTKEY);
        _set(2, HOTKEY);
        bytes32 nextHotkey = keccak256("next");
        _owner(nextHotkey, true, OWNER);
        _set(NETUID, nextHotkey);
        _assertValidator(NETUID, nextHotkey, OWNER, 2);
        _assertValidator(2, HOTKEY, OWNER, 1);
        _assertValidator(3, 0, 0, 0);
    }

    function test_SetValidator_AcceptsNetuidBoundaries() public {
        _set(0, HOTKEY);
        _set(type(uint16).max, HOTKEY);
        _assertValidator(0, HOTKEY, OWNER, 1);
        _assertValidator(type(uint16).max, HOTKEY, OWNER, 1);
    }

    function test_RevertWhen_NetuidIsOutOfRange() public {
        vm.expectRevert(NetuidOutOfRange.selector);
        _set(uint256(type(uint16).max) + 1, HOTKEY);
        _assertValidator(uint256(type(uint16).max) + 1, 0, 0, 0);
    }

    function test_RevertWhen_HotkeyIsZero() public {
        _set(NETUID, HOTKEY);
        vm.expectRevert(ZeroHotkey.selector);
        _set(NETUID, 0);
        _assertValidator(NETUID, HOTKEY, OWNER, 1);
    }

    function test_RevertWhen_HotkeyHasNoOwner() public {
        _owner(HOTKEY, false, OWNER);
        vm.expectRevert(abi.encodeWithSelector(BasicValidatorRegistry.OwnerlessHotkey.selector, HOTKEY));
        _set(NETUID, HOTKEY);
        _assertValidator(NETUID, 0, 0, 0);
    }

    function test_RevertWhen_OwnerPrecompileFails() public {
        _set(NETUID, HOTKEY);
        vm.mockCallRevert(
            STAKING_PRECOMPILE, abi.encodeCall(IStaking.getHotkeyOwner, (HOTKEY)), abi.encode("unavailable")
        );
        vm.expectRevert(abi.encode("unavailable"));
        _set(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, OWNER, 1);
    }

    function test_TransferOwnership_RequiresAcceptanceAndPreservesOwnerAuthority() public {
        address successor = makeAddr("successor");
        vm.expectEmit(true, true, false, true, address(registry));
        emit Ownable2Step.OwnershipTransferStarted(admin, successor);
        vm.prank(admin);
        registry.transferOwnership(successor);
        assertEq(registry.owner(), admin);
        assertEq(registry.pendingOwner(), successor);

        vm.prank(successor);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, successor));
        registry.setValidator(NETUID, HOTKEY);
        _set(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, OWNER, 1);
    }

    function test_AcceptOwnership_TransfersUpdateAuthorityWithoutChangingValidators() public {
        address successor = makeAddr("successor");
        _set(NETUID, HOTKEY);
        _set(2, HOTKEY);
        vm.prank(admin);
        registry.transferOwnership(successor);
        vm.expectEmit(true, true, false, true, address(registry));
        emit Ownable.OwnershipTransferred(admin, successor);
        vm.prank(successor);
        registry.acceptOwnership();
        assertEq(registry.owner(), successor);
        assertEq(registry.pendingOwner(), address(0));
        _assertValidator(NETUID, HOTKEY, OWNER, 1);
        _assertValidator(2, HOTKEY, OWNER, 1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        registry.setValidator(NETUID, HOTKEY);
        vm.prank(successor);
        registry.setValidator(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, OWNER, 2);
        _assertValidator(2, HOTKEY, OWNER, 1);
    }

    function test_RevertWhen_NonOwnerNominatesSuccessor() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        registry.transferOwnership(address(this));
        assertEq(registry.owner(), admin);
        assertEq(registry.pendingOwner(), address(0));
    }

    function test_RevertWhen_AcceptingWithoutPendingOwner() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        registry.acceptOwnership();
        assertEq(registry.owner(), admin);
    }

    function test_TransferOwnership_ReplacesPendingOwner() public {
        address first = makeAddr("first successor");
        address second = makeAddr("second successor");
        vm.startPrank(admin);
        registry.transferOwnership(first);
        registry.transferOwnership(second);
        vm.stopPrank();
        assertEq(registry.owner(), admin);
        assertEq(registry.pendingOwner(), second);
        vm.prank(first);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, first));
        registry.acceptOwnership();
        vm.prank(second);
        registry.acceptOwnership();
        assertEq(registry.owner(), second);
        assertEq(registry.pendingOwner(), address(0));
    }

    function test_TransferOwnership_ZeroCancelsPendingTransfer() public {
        address successor = makeAddr("successor");
        vm.startPrank(admin);
        registry.transferOwnership(successor);
        registry.transferOwnership(address(0));
        vm.stopPrank();
        assertEq(registry.owner(), admin);
        assertEq(registry.pendingOwner(), address(0));
        vm.prank(successor);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, successor));
        registry.acceptOwnership();
        _set(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, OWNER, 1);
    }

    function test_RevertWhen_OwnerRenouncesWithPendingSuccessor() public {
        address successor = makeAddr("successor");
        vm.prank(admin);
        registry.transferOwnership(successor);
        vm.prank(admin);
        vm.expectRevert(BasicValidatorRegistry.RenunciationDisabled.selector);
        registry.renounceOwnership();
        assertEq(registry.owner(), admin);
        assertEq(registry.pendingOwner(), successor);
        vm.prank(successor);
        registry.acceptOwnership();
        vm.prank(successor);
        registry.setValidator(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, OWNER, 1);
    }

    function test_RevertWhen_OwnerRenouncesWithoutPendingSuccessor() public {
        vm.prank(admin);
        vm.expectRevert(BasicValidatorRegistry.RenunciationDisabled.selector);
        registry.renounceOwnership();
        assertEq(registry.owner(), admin);
        assertEq(registry.pendingOwner(), address(0));
        _set(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, OWNER, 1);
    }

    function test_RevertWhen_NonOwnerRenounces() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        registry.renounceOwnership();
        assertEq(registry.owner(), admin);
    }

    function testFuzz_RevertWhen_CallerIsNotPendingOwner(address caller) public {
        address successor = makeAddr("successor");
        vm.assume(caller != successor);
        vm.prank(admin);
        registry.transferOwnership(successor);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        registry.acceptOwnership();
        assertEq(registry.owner(), admin);
        assertEq(registry.pendingOwner(), successor);
    }

    function testFuzz_RevertWhen_CallerIsNotOwner(address caller) public {
        vm.assume(caller != admin);
        _set(NETUID, HOTKEY);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        registry.setValidator(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, OWNER, 1);
    }

    function testFuzz_SetValidator_ValidSingleValidator(uint16 netuid, bytes32 hotkey, bytes32 owner) public {
        hotkey = bytes32(bound(uint256(hotkey), 1, type(uint256).max));
        _owner(hotkey, true, owner);
        _set(netuid, hotkey);
        _assertValidator(netuid, hotkey, owner, 1);
    }

    function testFuzz_RevertWhen_NetuidIsOutOfRange(uint256 netuid) public {
        netuid = bound(netuid, uint256(type(uint16).max) + 1, type(uint256).max);
        vm.expectRevert(NetuidOutOfRange.selector);
        _set(netuid, HOTKEY);
        _assertValidator(netuid, 0, 0, 0);
    }
}
