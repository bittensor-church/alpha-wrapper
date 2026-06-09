// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { RevertingReceiver, UnwrapForTaoReentrantReceiver } from "./helpers/TaoRailReceivers.sol";

contract UnwrapForTaoTest is AlphaVaultTestBase {
    event UnwrappedForTao(
        address indexed user, uint256 indexed tokenId, uint256 shares, uint256 assetsBurned, uint256 taoOut
    );

    function _depositForAlice(uint256 amount) internal returns (uint256 shares) {
        _simulateAlphaDeposit(alice, NETUID1, amount);
        _wrap(alice, NETUID1);
        shares = vault.balanceOf(alice, TOKEN1);
    }

    function test_SingleHotkey_BurnAllShares_PaysFullAlphaAsTao() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);
        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), 0);
        assertEq(alice.balance - aliceBalanceBefore, 100 ether);
        assertEq(vault.totalStake(TOKEN1), 0);
    }

    // Override the stake distribution after deposit to get a clean 60/40 split between two hotkeys.
    function test_PartialBurn_PaysProportionalTaoAcrossMultipleHotkeys() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);

        bytes32 cloneCk = _subnetColdkey(NETUID1);
        // Overwrite all three hotkeys so the total sums to exactly 100 ether.
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, cloneCk, NETUID1, 60 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, cloneCk, NETUID1, 40 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, cloneCk, NETUID1, 0);

        uint256 half = shares / 2;
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, half, 0);

        assertEq(alice.balance - balanceBefore, 50 ether);
    }

    function test_DrainsAlphaUnderHotkeyRotatedOutOfCurrentValidatorSet() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);

        // Re-attest to a new validator without running any state-mutating vault call, so the
        // historical snapshot continues to point at the hotkeys that hold the deposit.
        _setValidators(NETUID1, _hotkeys(hotkey4), _weights(10000));

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 100 ether);
    }

    // A hotkey reachable from both candidate sources must be drained exactly once; if the
    // dedup were broken the second call against the now-empty stake would underflow and revert.
    function test_DedupsHotkeyPresentInBothCurrentSetAndLastSeenSnapshot() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);

        bytes32 cloneCk = _subnetColdkey(NETUID1);
        // Consolidate all 100 ether onto hotkey1 and zero out the rest.
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, cloneCk, NETUID1, 100 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, cloneCk, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, cloneCk, NETUID1, 0);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 100 ether);
    }

    function test_MinTaoOutZero_AcceptsAnyRealizedTaoAmount() public {
        _setRemoveStakeRate(1, 100);
        uint256 shares = _depositForAlice(100 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);
        assertEq(alice.balance - balanceBefore, 1 ether);
    }

    function test_MinTaoOutEqualToRealizedAmount_DoesNotRevert() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);
        uint256 expected = _expectedTaoFor(100 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, expected);
        assertEq(alice.balance - balanceBefore, expected);
    }

    function test_RevertWhen_SharesIsZero() public {
        _depositForAlice(100 ether);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.unwrapForTao(TOKEN1, 0, 0);
    }

    function test_RevertWhen_SharesExceedCallerBalance() public {
        uint256 shares = _depositForAlice(100 ether);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.InsufficientShares.selector);
        vault.unwrapForTao(TOKEN1, shares + 1, 0);
    }

    // After dissolution zeroes the alpha and credits a TAO refund to the clone, this rail must
    // not let a holder drain that refund: only the alpha-rail dissolved-position path may do so.
    function test_DissolvedSubnetTaoRefund_NotDrainableViaTaoRail() public {
        uint256 shares = _depositForAlice(100 ether);
        _simulateNewNetworkRegistered(TOKEN1, 999, 5 ether);

        vm.prank(alice);
        vm.expectRevert(AlphaVault.NothingToUnwrap.selector);
        vault.unwrapForTao(TOKEN1, shares, 0);
    }

    // Single-validator set so the minimum-stake deposit isn't split across slots, then burn
    // one share to trigger the rounding-to-zero edge inherent to the share-price cushion.
    function test_RevertWhen_ProRataAssetsRoundsToZero() public {
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(10000));
        _setRemoveStakeRate(1, 1);
        uint256 depositAmount = vault.minRebalanceAmt();
        _simulateAlphaDeposit(alice, NETUID1, depositAmount);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        require(shares > 1, "test requires shares > 1 after deposit");

        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.unwrapForTao(TOKEN1, 1, 0);
    }

    function test_RevertWhen_RealizedTaoBelowMinTaoOut() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);
        uint256 expected = _expectedTaoFor(100 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AlphaVault.SlippageExceeded.selector, expected));
        vault.unwrapForTao(TOKEN1, shares, expected + 1);
    }

    function test_SucceedsWhenAlphaRailBlockedByTransferToggle() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);

        _simulateTransferToggleOn();

        bytes32 dest = keccak256("dest");
        vm.prank(alice);
        vm.expectRevert();
        vault.unwrap(TOKEN1, shares, dest);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);
        assertEq(alice.balance - balanceBefore, 100 ether);
    }

    // Any failure on the underlying swap must roll back the outer call so the caller's
    // shares stay intact and they can retry later.
    function test_RemoveStakeRevertBubblesUp_PreservesCallerShares() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);
        _setRemoveStakeReverts(true);

        vm.prank(alice);
        vm.expectRevert();
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), shares);
    }

    // A native TAO gift sent directly to the clone before the call must be excluded from
    // the slippage delta and remain on the clone afterwards.
    function test_DonationToClonePriorToCall_DoesNotInflateTaoOut() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);

        address clone = vault.subnetClone(TOKEN1);
        _donateToClone(clone, 5 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 100 ether);
        assertEq(clone.balance, 5 ether);
    }

    // If the caller's receive hook reverts on the TAO payment, the whole call must roll back
    // and leave shares intact.
    function test_RevertWhen_CallerReceiverRevertsOnReceive() public {
        _setRemoveStakeRate(1, 1);
        RevertingReceiver receiver = new RevertingReceiver();
        _simulateAlphaDeposit(address(receiver), NETUID1, 100 ether);
        _wrap(address(receiver), NETUID1);
        uint256 shares = vault.balanceOf(address(receiver), TOKEN1);

        vm.prank(address(receiver));
        vm.expectRevert();
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(address(receiver), TOKEN1), shares);
    }

    // The reentrancy guard must stop a recipient whose receive hook tries to call back in.
    function test_RevertWhen_CallerReceiverReentersUnwrapForTao() public {
        _setRemoveStakeRate(1, 1);
        UnwrapForTaoReentrantReceiver receiver = new UnwrapForTaoReentrantReceiver();
        _simulateAlphaDeposit(address(receiver), NETUID1, 100 ether);
        _wrap(address(receiver), NETUID1);
        uint256 shares = vault.balanceOf(address(receiver), TOKEN1);
        receiver.arm(vault, TOKEN1, shares);

        vm.prank(address(receiver));
        vm.expectRevert();
        vault.unwrapForTao(TOKEN1, shares, 0);
    }

    function test_MultipleUsers_ProRataConsistentAcrossSequentialUnwraps() public {
        _setRemoveStakeRate(1, 1);
        uint256 aliceShares = _depositForAlice(100 ether);

        _simulateAlphaDeposit(bob, NETUID1, 100 ether);
        _wrap(bob, NETUID1);
        uint256 bobShares = vault.balanceOf(bob, TOKEN1);

        uint256 aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, aliceShares, 0);
        assertEq(alice.balance - aliceBalanceBefore, 100 ether);

        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        vault.unwrapForTao(TOKEN1, bobShares, 0);
        assertEq(bob.balance - bobBalanceBefore, 100 ether);
    }

    function test_AlphaRailUnwrapRemainsWorkingAfterTaoUnwrapByDifferentHolder() public {
        _setRemoveStakeRate(1, 1);
        uint256 aliceShares = _depositForAlice(100 ether);

        _simulateAlphaDeposit(bob, NETUID1, 100 ether);
        _wrap(bob, NETUID1);
        uint256 bobShares = vault.balanceOf(bob, TOKEN1);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, aliceShares, 0);

        bytes32 bobDest = keccak256("bobDest");
        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, bobDest);

        assertEq(vault.balanceOf(bob, TOKEN1), 0);
    }

    // Validator emissions grow the clone's stake above the original deposit; the share-price
    // recalibration must capture this so the unwrapper is paid the appreciated value.
    function test_UnwrapForTao_PaysOutAccruedEmissionsAboveOriginalDeposit() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);

        bytes32 cloneCk = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, cloneCk, NETUID1, 60 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, cloneCk, NETUID1, 40 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, cloneCk, NETUID1, 10 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        // The share-price cushion trims a couple of wei off the nominal 110 ether; the
        // tolerance pins the value while accommodating that rounding.
        assertApproxEqAbs(alice.balance - balanceBefore, 110 ether, 2);
    }

    // Event payload must carry every field off-chain indexers rely on.
    function test_UnwrapForTao_EmitsUnwrappedForTaoEvent() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);
        uint256 expectedTao = _expectedTaoFor(100 ether);

        vm.expectEmit(true, true, false, true, address(vault));
        emit UnwrappedForTao(alice, TOKEN1, shares, 100 ether, expectedTao);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);
    }

    function test_UnwrapForTao_NonUnitRate_PaysExactExpectedTao() public {
        _setRemoveStakeRate(1, 2);
        uint256 shares = _depositForAlice(100 ether);
        uint256 expected = _expectedTaoFor(100 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, expected);
        assertEq(expected, 50 ether);
    }

    // Once the requested amount has been drained, later hotkeys must be left untouched.
    function test_PartialBurn_LeavesUnneededHotkeysUntouched() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);

        bytes32 cloneCk = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, cloneCk, NETUID1, 60 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, cloneCk, NETUID1, 40 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, cloneCk, NETUID1, 0);

        uint256 sharesForThirty = (shares * 30) / 100;

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, sharesForThirty, 0);

        assertEq(alice.balance - balanceBefore, 30 ether);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey2, cloneCk, NETUID1), 40 ether);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, cloneCk, NETUID1), 30 ether);
    }

    // A single user who unwraps half their shares via the TAO rail must be able to
    // unwrap the remainder via the alpha rail without share accounting errors.
    function test_SingleUser_CanUnwrapHalfViaTaoRailThenHalfViaAlphaRail() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);
        uint256 half = shares / 2;

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, half, 0);
        assertEq(alice.balance - balanceBefore, 50 ether);

        bytes32 dest = keccak256("alice-substrate");
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares - half, dest);

        assertEq(vault.balanceOf(alice, TOKEN1), 0);
    }

    // After a partial TAO-rail unwrap the on-chain stake is reduced; rebalance must
    // still be able to run on the remaining stake without reverting.
    function test_RebalanceWorksAfterPartialUnwrapForTao() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);

        vault.rebalance(NETUID1);
    }

    receive() external payable { }
}
