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
        vault.setURI("ipfs://before");
        vault.setURI("ipfs://before");
        assertEq(vault.uri(TOKEN1), "ipfs://before", "old owner must retain control before acceptance");

        vm.prank(alice);
        vault.acceptOwnership();

        // After acceptance: control flips - old owner is locked out, new owner is in.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vault.setURI("ipfs://after");
        vm.prank(alice);
        vault.setURI("ipfs://after");
        assertEq(vault.uri(TOKEN1), "ipfs://after", "new owner must control after acceptance");
    }
}
