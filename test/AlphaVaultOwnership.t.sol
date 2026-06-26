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

    function test_transferOwnership_setsPendingOwnerAndKeepsOwner() public {
        vm.expectEmit(true, true, false, false, address(vault));
        emit OwnershipTransferStarted(owner, alice);
        vault.transferOwnership(alice);

        assertEq(vault.owner(), owner, "owner must not change before acceptance");
        assertEq(vault.pendingOwner(), alice, "pending owner must be set");
    }

    function test_acceptOwnership_transfersToPendingOwner() public {
        vault.transferOwnership(alice);

        vm.expectEmit(true, true, false, false, address(vault));
        emit OwnershipTransferred(owner, alice);
        vm.prank(alice);
        vault.acceptOwnership();

        assertEq(vault.owner(), alice, "owner must update after acceptance");
        assertEq(vault.pendingOwner(), address(0), "pending owner must be cleared");
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
        vault.setMinRebalanceAmt(123);
        vault.setMinRebalanceAmt(123);
        assertEq(vault.minRebalanceAmt(), 123, "old owner must retain control before acceptance");

        vm.prank(alice);
        vault.acceptOwnership();

        // After acceptance: control flips — old owner is locked out, new owner is in.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vault.setMinRebalanceAmt(456);
        vm.prank(alice);
        vault.setMinRebalanceAmt(456);
        assertEq(vault.minRebalanceAmt(), 456, "new owner must control after acceptance");
    }
}
