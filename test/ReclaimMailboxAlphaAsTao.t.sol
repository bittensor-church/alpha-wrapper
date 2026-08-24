// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { NetuidOutOfRange, SlippageExceeded, ZeroAmount, ZeroHotkey } from "src/VaultErrors.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { RevertingReceiver, ReclaimMailboxReentrantReceiver } from "./helpers/TaoRailReceivers.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ReclaimMailboxAlphaAsTaoTest is AlphaVaultTestBase {
    event MailboxAlphaSoldForTao(
        address indexed user, uint256 indexed netuid, bytes32 indexed hotkey, uint256 alpha, uint256 taoOut
    );

    function _seedMailboxAlpha(address user, uint256 netuid, bytes32 hotkey, uint256 amount) internal {
        address predicted = vault.getDepositAddress(user, netuid);
        bytes32 ck = _toSubstrate(predicted);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey, ck, netuid, amount);
    }

    function test_ReclaimMailboxAlphaAsTao_DrainsMailboxAndPaysCallerInTao() public {
        _setRemoveStakeRate(1, 1);
        _seedMailboxAlpha(alice, NETUID1, hotkey1, 50 ether);

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.reclaimMailboxAlphaAsTao(NETUID1, hotkey1, 0);

        assertEq(alice.balance - before, 50 ether);
        address predicted = vault.getDepositAddress(alice, NETUID1);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, _toSubstrate(predicted), NETUID1), 0);
    }

    function test_MinTaoOutZero_AcceptsAnyRealizedAmount() public {
        _setRemoveStakeRate(1, 100);
        _seedMailboxAlpha(alice, NETUID1, hotkey1, 50 ether);

        vm.prank(alice);
        vault.reclaimMailboxAlphaAsTao(NETUID1, hotkey1, 0);
    }

    function test_TwoUsersOnSameNetuid_MailboxesAreIsolated() public {
        _setRemoveStakeRate(1, 1);
        _seedMailboxAlpha(alice, NETUID1, hotkey1, 50 ether);
        _seedMailboxAlpha(bob, NETUID1, hotkey1, 70 ether);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.reclaimMailboxAlphaAsTao(NETUID1, hotkey1, 0);
        assertEq(alice.balance - aliceBefore, 50 ether);

        address bobMailbox = vault.getDepositAddress(bob, NETUID1);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, _toSubstrate(bobMailbox), NETUID1), 70 ether);
    }

    function test_RevertWhen_NetuidExceedsUint16() public {
        vm.prank(alice);
        vm.expectRevert(NetuidOutOfRange.selector);
        vault.reclaimMailboxAlphaAsTao(uint256(type(uint16).max) + 1, hotkey1, 0);
    }

    function test_RevertWhen_HotkeyIsZero() public {
        vm.prank(alice);
        vm.expectRevert(ZeroHotkey.selector);
        vault.reclaimMailboxAlphaAsTao(NETUID1, bytes32(0), 0);
    }

    function test_RevertWhen_NoMailboxStakeForGivenHotkey() public {
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        vault.reclaimMailboxAlphaAsTao(NETUID1, hotkey1, 0);
    }

    function test_RevertWhen_RealizedTaoBelowMinTaoOut() public {
        _setRemoveStakeRate(1, 1);
        _seedMailboxAlpha(alice, NETUID1, hotkey1, 50 ether);
        uint256 expected = _expectedTaoFor(50 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, expected));
        vault.reclaimMailboxAlphaAsTao(NETUID1, hotkey1, expected + 1);
    }

    function test_RemoveStakeRevertBubblesUp_PreservesMailboxAlpha() public {
        _setRemoveStakeRate(1, 1);
        _seedMailboxAlpha(alice, NETUID1, hotkey1, 50 ether);
        _setRemoveStakeReverts(true);

        vm.prank(alice);
        vm.expectRevert();
        vault.reclaimMailboxAlphaAsTao(NETUID1, hotkey1, 0);

        address predicted = vault.getDepositAddress(alice, NETUID1);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, _toSubstrate(predicted), NETUID1), 50 ether);
    }

    // A native TAO gift sent directly to the mailbox must be excluded from the slippage delta
    // and remain on the mailbox afterwards.
    function test_DonationToMailboxPriorToCall_DoesNotInflateTaoOut() public {
        _setRemoveStakeRate(1, 1);
        _seedMailboxAlpha(alice, NETUID1, hotkey1, 50 ether);

        address mailbox = vault.getDepositAddress(alice, NETUID1);
        _donateToClone(mailbox, 3 ether);

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.reclaimMailboxAlphaAsTao(NETUID1, hotkey1, 0);

        assertEq(alice.balance - before, 50 ether);
        assertEq(mailbox.balance, 3 ether);
    }

    // If the caller's receive hook reverts on the TAO payment, the whole call must roll back
    // and leave mailbox alpha intact.
    function test_RevertWhen_CallerReceiverRevertsOnReceive() public {
        _setRemoveStakeRate(1, 1);
        RevertingReceiver receiver = new RevertingReceiver();
        _seedMailboxAlpha(address(receiver), NETUID1, hotkey1, 50 ether);

        vm.prank(address(receiver));
        vm.expectRevert();
        vault.reclaimMailboxAlphaAsTao(NETUID1, hotkey1, 0);

        address predicted = vault.getDepositAddress(address(receiver), NETUID1);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, _toSubstrate(predicted), NETUID1), 50 ether);
    }

    // The reentrancy guard must reject a recipient whose receive hook tries to call back in.
    function test_ReentrantReclaimMailboxAlphaAsTaoIsRejectedByGuard() public {
        _setRemoveStakeRate(1, 1);
        ReclaimMailboxReentrantReceiver receiver = new ReclaimMailboxReentrantReceiver();
        _seedMailboxAlpha(address(receiver), NETUID1, hotkey1, 50 ether);
        receiver.arm(vault, NETUID1, hotkey1);

        vm.prank(address(receiver));
        vault.reclaimMailboxAlphaAsTao(NETUID1, hotkey1, 0);

        // The re-entry was rejected specifically by the guard, not by some incidental revert.
        assertEq(receiver.reentryError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertFalse(receiver.reentrySucceeded());
        // The legitimate (outer) reclaim still completed: the mailbox stake is drained.
        address predicted = vault.getDepositAddress(address(receiver), NETUID1);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, _toSubstrate(predicted), NETUID1), 0);
    }

    // Event payload must carry every field off-chain indexers rely on.
    function test_ReclaimMailboxAlphaAsTao_EmitsMailboxAlphaSoldForTaoEvent() public {
        _setRemoveStakeRate(1, 1);
        _seedMailboxAlpha(alice, NETUID1, hotkey1, 50 ether);
        uint256 expectedTao = _expectedTaoFor(50 ether);

        vm.expectEmit(true, true, true, true, address(vault));
        emit MailboxAlphaSoldForTao(alice, NETUID1, hotkey1, 50 ether, expectedTao);

        vm.prank(alice);
        vault.reclaimMailboxAlphaAsTao(NETUID1, hotkey1, 0);
    }

    receive() external payable { }
}
