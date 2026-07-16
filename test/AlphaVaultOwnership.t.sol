// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";

contract AlphaVaultOwnershipTest is AlphaVaultTestBase {
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public override {
        super.setUp();
    }

    function test_onlyOwnerFunctionFollowsOwnerAcrossTwoStepTransfer() public {
        // Only the owner can start a transfer.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.transferOwnership(alice);

        vault.transferOwnership(alice);

        // Only the pending owner can accept.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        vault.acceptOwnership();

        // Before acceptance: the old owner still controls onlyOwner functions, the pending one doesn't.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setMinStakeTaoFloor(123);
        vault.setMinStakeTaoFloor(123);
        assertEq(vault.minStakeTaoFloor(), 123, "old owner must retain control before acceptance");

        vm.prank(alice);
        vault.acceptOwnership();

        // After acceptance: control flips - old owner is locked out, new owner is in.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vault.setMinStakeTaoFloor(456);
        vm.prank(alice);
        vault.setMinStakeTaoFloor(456);
        assertEq(vault.minStakeTaoFloor(), 456, "new owner must control after acceptance");
    }
}
