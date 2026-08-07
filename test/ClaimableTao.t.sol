// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Tests the vault's claimable-TAO bookkeeping: when a subnet clone receives native TAO that no
// vault operation paid out (forced dust sales on the chain, direct donations), the vault tracks
// who was holding shares at that moment and lets exactly those holders withdraw it later.

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { ClaimDuringTransferReceiver } from "./helpers/TaoRailReceivers.sol";

contract ClaimableTaoTest is AlphaVaultTestBase {
    event TaoClaimed(address indexed user, uint256 indexed tokenId, address recipient, uint256 amount);
    event Unwrapped(address indexed user, uint256 indexed tokenId, uint256 shares, uint256 alphaOut);

    uint256 internal constant DEPOSIT = 30 ether;

    // Native TAO moves in whole multiples of this quantum, so quotes and payouts are floored to it.
    uint256 internal constant NATIVE_TRANSFER_QUANTUM = 1e9;

    function _donateToTokenClone(uint256 tokenId, uint256 amount) internal {
        _donateToClone(vault.subnetClone(tokenId), amount);
    }

    function _claimAs(address user) internal {
        vm.prank(user);
        vault.claimTao(TOKEN1, payable(user));
    }

    function _assertCloneCoversReservedTao(uint256 tokenId) internal view {
        address clone = vault.subnetClone(tokenId);
        assertGe(clone.balance, vault.taoLiability(tokenId));
    }

    // A balance-neutral touch that runs the settlement hook for the caller.
    function _touch(address user, uint256 tokenId) internal {
        vm.prank(user);
        vault.safeTransferFrom(user, user, tokenId, 0, "");
    }

    function _exitCompletely(address user, uint256 tokenId) internal {
        uint256 shares = vault.balanceOf(user, tokenId);
        vm.prank(user);
        vault.unwrap(tokenId, shares, _toSubstrate(user));
    }

    // -------------------- Index accrual ------------------------------------------

    function test_DonationBeforeSecondWrap_AccruesOnlyToFirstHolder() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        uint256 donated = 5 ether;
        _donateToTokenClone(TOKEN1, donated);

        _depositAndWrap(bob, NETUID1, DEPOSIT);

        assertEq(vault.claimableTaoOf(bob, TOKEN1), 0);
        assertApproxEqAbs(vault.claimableTaoOf(alice, TOKEN1), donated, NATIVE_TRANSFER_QUANTUM);
        assertLe(vault.claimableTaoOf(alice, TOKEN1), donated);
        assertLe(vault.taoLiability(TOKEN1), donated);
    }

    function test_TransferAfterDonation_SenderKeepsEarnedEntitlement() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        uint256 donated = 3 ether;
        _donateToTokenClone(TOKEN1, donated);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.safeTransferFrom(alice, bob, TOKEN1, shares, "");

        assertApproxEqAbs(vault.claimableTaoOf(alice, TOKEN1), donated, NATIVE_TRANSFER_QUANTUM);
        assertLe(vault.claimableTaoOf(alice, TOKEN1), donated);
        assertEq(vault.claimableTaoOf(bob, TOKEN1), 0);
    }

    function test_BatchWithDuplicateIds_SettlesEachIdOnce() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        uint256 donated = 4 ether;
        _donateToTokenClone(TOKEN1, donated);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        uint256[] memory ids = new uint256[](2);
        ids[0] = TOKEN1;
        ids[1] = TOKEN1;
        uint256[] memory values = new uint256[](2);
        values[0] = shares / 2;
        values[1] = shares / 2;
        vm.prank(alice);
        vault.safeBatchTransferFrom(alice, bob, ids, values, "");

        assertApproxEqAbs(vault.claimableTaoOf(alice, TOKEN1), donated, NATIVE_TRANSFER_QUANTUM);
        assertEq(vault.claimableTaoOf(bob, TOKEN1), 0);

        _donateToTokenClone(TOKEN1, donated);
        _touch(bob, TOKEN1);
        uint256 bobShare = (donated * vault.balanceOf(bob, TOKEN1)) / vault.totalSupply(TOKEN1);
        assertApproxEqAbs(vault.claimableTaoOf(bob, TOKEN1), bobShare, NATIVE_TRANSFER_QUANTUM);
        assertLe(vault.claimableTaoOf(bob, TOKEN1), bobShare);
    }

    function test_SelfTransfer_LeavesEntitlementUnchanged() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        uint256 donated = 2 ether;
        _donateToTokenClone(TOKEN1, donated);
        uint256 entitlementBefore = vault.claimableTaoOf(alice, TOKEN1);

        _touch(alice, TOKEN1);
        assertEq(vault.claimableTaoOf(alice, TOKEN1), entitlementBefore);

        _touch(alice, TOKEN1);
        assertEq(vault.claimableTaoOf(alice, TOKEN1), entitlementBefore);
    }

    // -------------------- Claims -------------------------------------------------

    function test_ClaimTao_PaysSettledEntitlement() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        uint256 donated = 5 ether;
        _donateToTokenClone(TOKEN1, donated);
        _touch(alice, TOKEN1);

        uint256 expected = vault.claimableTaoOf(alice, TOKEN1);
        uint256 storedBefore = vault.claimableTao(TOKEN1, alice);
        uint256 liabilityBefore = vault.taoLiability(TOKEN1);
        vm.expectEmit(true, true, false, true, address(vault));
        emit TaoClaimed(alice, TOKEN1, alice, expected);
        _claimAs(alice);

        assertEq(alice.balance, expected);
        assertEq(vault.claimableTaoOf(alice, TOKEN1), 0);
        // The sub-quantum remainder is retained for the claimant, not erased with the payout.
        assertEq(vault.claimableTao(TOKEN1, alice), storedBefore - expected);
        assertEq(vault.taoLiability(TOKEN1), liabilityBefore - expected);
        _assertCloneCoversReservedTao(TOKEN1);
    }

    function test_RevertWhen_ClaimingWithNoEntitlement() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        _claimAs(bob);
    }

    function test_RevertWhen_ClaimingSubQuantumEntitlement() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _donateToTokenClone(TOKEN1, NATIVE_TRANSFER_QUANTUM - 1);

        // Too small to deliver: the quote promises nothing and the claim refuses rather than
        // clearing an entitlement no transfer can pay out.
        assertEq(vault.claimableTaoOf(alice, TOKEN1), 0);
        vm.expectRevert(AlphaVault.ClaimBelowNativePrecision.selector);
        _claimAs(alice);
    }

    function test_RevertWhen_ClaimingToZeroAddress() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        vm.expectRevert(AlphaVault.ZeroAddress.selector);
        vm.prank(alice);
        vault.claimTao(TOKEN1, payable(address(0)));
    }

    function test_ClaimAfterFullExit_StillPays() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        uint256 donated = 5 ether;
        _donateToTokenClone(TOKEN1, donated);

        _exitCompletely(alice, TOKEN1);

        assertApproxEqAbs(vault.claimableTaoOf(alice, TOKEN1), donated, NATIVE_TRANSFER_QUANTUM);
        uint256 paid = _claimQuotedAmount(alice, TOKEN1);
        assertApproxEqAbs(paid, donated, NATIVE_TRANSFER_QUANTUM);
        assertLe(paid, donated);
    }

    function test_ReceiverClaimDuringSafeTransfer_GainsNothing() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        uint256 donated = 5 ether;
        _donateToTokenClone(TOKEN1, donated);
        ClaimDuringTransferReceiver receiver = new ClaimDuringTransferReceiver(vault);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.safeTransferFrom(alice, address(receiver), TOKEN1, shares, "");

        assertFalse(receiver.claimSucceeded());
        assertEq(address(receiver).balance, 0);
        assertApproxEqAbs(vault.claimableTaoOf(alice, TOKEN1), donated, NATIVE_TRANSFER_QUANTUM);
    }

    function test_UnwrapForTaoAfterDonation_ExitPaysSaleProceedsOnly() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _depositAndWrap(bob, NETUID1, DEPOSIT);
        uint256 donated = 5 ether;
        _donateToTokenClone(TOKEN1, donated);

        uint256 shares = vault.balanceOf(bob, TOKEN1);
        (uint256 bobAlpha,) = vault.previewUnwrap(TOKEN1, shares);
        vm.prank(bob);
        vault.unwrapForTao(TOKEN1, shares, 0);

        uint256 exitPaid = bob.balance;
        assertGt(exitPaid, 0);
        assertLe(exitPaid, _expectedTaoFor(bobAlpha));
        _assertCloneCoversReservedTao(TOKEN1);
        uint256 keptClaims = vault.claimableTaoOf(alice, TOKEN1) + vault.claimableTaoOf(bob, TOKEN1);
        assertApproxEqAbs(keptClaims, donated, 2 * NATIVE_TRANSFER_QUANTUM);
        assertLe(keptClaims, donated);
    }

    function testFuzz_ClaimsAcrossHolders_ConserveArrivedTao(uint256 donation, uint256 aliceDeposit, uint256 bobDeposit)
        public
    {
        donation = bound(donation, 1, 1_000_000 ether);
        aliceDeposit = bound(aliceDeposit, 1 ether, 1_000_000 ether);
        bobDeposit = bound(bobDeposit, 1 ether, 1_000_000 ether);

        _depositAndWrap(alice, NETUID1, aliceDeposit);
        _depositAndWrap(bob, NETUID1, bobDeposit);
        _donateToTokenClone(TOKEN1, donation);

        // A transfer settles the first donation while the second stays unsynchronized, so the
        // claims exercise both settled storage and the simulated fold of pending TAO.
        uint256 aliceShares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.safeTransferFrom(alice, bob, TOKEN1, aliceShares / 2, "");
        uint256 secondDonation = donation / 3 + 1;
        _donateToTokenClone(TOKEN1, secondDonation);

        uint256 arrived = donation + secondDonation;
        uint256 paid = _claimQuotedAmount(alice, TOKEN1) + _claimQuotedAmount(bob, TOKEN1);
        assertLe(paid, arrived);
        // Each holder retains at most one sub-quantum remainder plus index-flooring wei.
        assertApproxEqAbs(paid, arrived, 2 * NATIVE_TRANSFER_QUANTUM + 8);
        _assertCloneCoversReservedTao(TOKEN1);
    }

    // -------------------- Dissolution seam ---------------------------------------

    function test_DissolutionRefund_NotIndexedToHolders() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        uint256 indexBefore = vault.cumulativeTaoPerShare(TOKEN1);

        _simulateDissolutionStarted(NETUID1);
        _donateToTokenClone(TOKEN1, 5 ether);
        _simulateTaoAwardedOnDissolution(TOKEN1, 20 ether);
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.safeTransferFrom(alice, bob, TOKEN1, shares / 2, "");

        assertEq(vault.cumulativeTaoPerShare(TOKEN1), indexBefore);
        assertEq(vault.taoLiability(TOKEN1), 0);

        _simulateDissolutionCompleted(NETUID1);
        _touch(bob, TOKEN1);

        assertEq(vault.cumulativeTaoPerShare(TOKEN1), indexBefore);
        assertEq(vault.taoLiability(TOKEN1), 0);
        assertEq(vault.claimableTaoOf(alice, TOKEN1), 0);
        assertEq(vault.claimableTaoOf(bob, TOKEN1), 0);
    }

    function test_DissolvedUnwrap_ExcludesReservedTao() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _depositAndWrap(bob, NETUID1, DEPOSIT);
        uint256 donated = 6 ether;
        _donateToTokenClone(TOKEN1, donated);
        _touch(alice, TOKEN1);

        uint256 refund = 20 ether;
        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, refund);
        _simulateDissolutionCompleted(NETUID1);

        uint256 aliceShares = vault.balanceOf(alice, TOKEN1);
        uint256 supply = vault.totalSupply(TOKEN1);
        (, uint256 previewTao) = vault.previewUnwrap(TOKEN1, aliceShares);
        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, bytes32(0));

        assertEq(alice.balance, previewTao);
        assertApproxEqAbs(alice.balance, (refund * aliceShares) / supply, 2);

        _claimQuotedAmount(alice, TOKEN1);
        assertApproxEqAbs(alice.balance, previewTao + donated / 2, NATIVE_TRANSFER_QUANTUM + 4);
        assertLe(alice.balance, previewTao + donated / 2);
    }

    function test_ClaimDuringBlackout_PaysExistingEntitlement() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        uint256 donated = 5 ether;
        _donateToTokenClone(TOKEN1, donated);
        _touch(alice, TOKEN1);

        _simulateDissolutionStarted(NETUID1);

        uint256 paid = _claimQuotedAmount(alice, TOKEN1);
        assertApproxEqAbs(paid, donated, NATIVE_TRANSFER_QUANTUM);
        assertLe(paid, donated);
    }

    // A raised chain threshold can force-sell the whole position while shares remain outstanding;
    // the zero-backing unwrap retires those shares and the sale proceeds stay claimable.
    function test_UnwrapAfterFullSweep_RetiresSharesAndKeepsClaim() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        uint256 proceeds = 7 ether;
        _simulateTaoAwardedOnDissolution(TOKEN1, proceeds);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 previewAlpha, uint256 previewTao) = vault.previewUnwrap(TOKEN1, shares);
        assertEq(previewAlpha, 0);
        assertEq(previewTao, 0);
        vm.expectEmit(true, true, false, true, address(vault));
        emit Unwrapped(alice, TOKEN1, shares, 0);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));

        assertEq(vault.totalSupply(TOKEN1), 0);
        uint256 paid = _claimQuotedAmount(alice, TOKEN1);
        assertApproxEqAbs(paid, proceeds, NATIVE_TRANSFER_QUANTUM);
        assertLe(paid, proceeds);
    }

    // -------------------- Supply bound -------------------------------------------

    // Recapitalizing a fully swept position multiplies share supply; the index must still be
    // able to record the smallest possible native arrival at the inflated supply.
    function test_WrapAfterFullSweep_StaysWithinClaimIndexBound() public {
        uint256 seed = 1e10;
        _depositAndWrap(alice, NETUID1, seed);
        _simulateTaoAwardedOnDissolution(TOKEN1, 5 ether);
        _depositAndWrap(bob, NETUID1, seed);
        assertLe(vault.totalSupply(TOKEN1), 1e45);

        uint256 liabilityBefore = vault.taoLiability(TOKEN1);
        _donateToTokenClone(TOKEN1, 100 * NATIVE_TRANSFER_QUANTUM);
        _touch(bob, TOKEN1);
        assertGt(vault.taoLiability(TOKEN1), liabilityBefore);
        _claimQuotedAmount(bob, TOKEN1);
    }

    function test_RevertWhen_RecapitalizationWouldBreachClaimIndexBound() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _simulateTaoAwardedOnDissolution(TOKEN1, 5 ether);

        bytes32 chosen = vault.getCurrentValidators(NETUID1)[0];
        _simulateAlphaDeposit(bob, NETUID1, DEPOSIT);
        vm.expectRevert(AlphaVault.SupplyCapExceeded.selector);
        vm.prank(bob);
        vault.wrap(NETUID1, chosen);
    }

    // -------------------- Zero-supply arrivals ------------------------------------

    // With no holders at arrival there is no one to attribute the TAO to; it accrues to whoever
    // holds shares at the next synchronization instead of sitting stuck in the clone.
    function test_TaoArrivingAtZeroSupply_AccruesToNextHolders() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _exitCompletely(alice, TOKEN1);
        assertEq(vault.totalSupply(TOKEN1), 0);

        uint256 orphaned = 5 ether;
        _donateToTokenClone(TOKEN1, orphaned);
        _depositAndWrap(bob, NETUID1, DEPOSIT);

        assertEq(vault.claimableTaoOf(alice, TOKEN1), 0);
        assertApproxEqAbs(vault.claimableTaoOf(bob, TOKEN1), orphaned, NATIVE_TRANSFER_QUANTUM);
        _claimQuotedAmount(bob, TOKEN1);
        _assertCloneCoversReservedTao(TOKEN1);
    }
}
