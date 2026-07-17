// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Tests the vault's claimable-TAO bookkeeping: when a subnet clone receives native TAO that no
// vault operation paid out (forced dust sales on the chain, direct donations), the vault tracks
// who was holding shares at that moment and lets exactly those holders withdraw it later.

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { SUBNET_PRECOMPILE } from "src/interfaces/ISubnet.sol";
import { ClaimDuringTransferReceiver } from "./helpers/TaoRailReceivers.sol";

contract ClaimableTaoTest is AlphaVaultTestBase {
    event TaoClaimed(address indexed user, uint256 indexed tokenId, address recipient, uint256 amount);
    event ExcludedTaoRecovered(uint256 indexed tokenId, address recipient, uint256 amount);

    uint256 internal constant DEPOSIT = 30 ether;

    function _donateToTokenClone(uint256 tokenId, uint256 amount) internal returns (address clone) {
        clone = vault.subnetClone(tokenId);
        _donateToClone(clone, amount);
    }

    function _claimAs(address user) internal {
        vm.prank(user);
        vault.claimTao(TOKEN1, payable(user));
    }

    function _assertCloneCoversReservedTao(uint256 tokenId) internal view {
        address clone = vault.subnetClone(tokenId);
        assertGe(clone.balance, vault.taoLiability(tokenId) + vault.excludedTao(tokenId));
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
        assertApproxEqAbs(vault.claimableTaoOf(alice, TOKEN1), donated, 2);
        assertLe(vault.taoLiability(TOKEN1), donated);
    }

    function test_TransferAfterDonation_SenderKeepsEarnedEntitlement() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        uint256 donated = 3 ether;
        _donateToTokenClone(TOKEN1, donated);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.safeTransferFrom(alice, bob, TOKEN1, shares, "");

        assertApproxEqAbs(vault.claimableTaoOf(alice, TOKEN1), donated, 2);
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

        assertApproxEqAbs(vault.claimableTaoOf(alice, TOKEN1), donated, 2);
        assertEq(vault.claimableTaoOf(bob, TOKEN1), 0);

        _donateToTokenClone(TOKEN1, donated);
        _touch(bob, TOKEN1);
        uint256 bobShare = (donated * vault.balanceOf(bob, TOKEN1)) / vault.totalSupply(TOKEN1);
        assertApproxEqAbs(vault.claimableTaoOf(bob, TOKEN1), bobShare, 2);
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

    function testFuzz_IndexAllocation_NeverExceedsArrivedTao(uint256 donation, uint256 secondDonation) public {
        donation = bound(donation, 1, 1_000_000 ether);
        secondDonation = bound(secondDonation, 0, 1_000_000 ether);
        _depositAndWrap(alice, NETUID1, DEPOSIT);

        _donateToTokenClone(TOKEN1, donation);
        _touch(alice, TOKEN1);
        _donateToTokenClone(TOKEN1, secondDonation);
        _touch(alice, TOKEN1);

        assertLe(vault.taoLiability(TOKEN1), donation + secondDonation);
        _assertCloneCoversReservedTao(TOKEN1);
    }

    // -------------------- Claims -------------------------------------------------

    function test_ClaimTao_PaysSettledEntitlement() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        uint256 donated = 5 ether;
        _donateToTokenClone(TOKEN1, donated);
        _touch(alice, TOKEN1);

        uint256 expected = vault.claimableTaoOf(alice, TOKEN1);
        uint256 liabilityBefore = vault.taoLiability(TOKEN1);
        vm.expectEmit(true, true, false, true, address(vault));
        emit TaoClaimed(alice, TOKEN1, alice, expected);
        _claimAs(alice);

        assertEq(alice.balance, expected);
        assertEq(vault.claimableTaoOf(alice, TOKEN1), 0);
        assertEq(vault.taoLiability(TOKEN1), liabilityBefore - expected);
        _assertCloneCoversReservedTao(TOKEN1);
    }

    function test_RevertWhen_ClaimingWithNoEntitlement() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        _claimAs(bob);
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

        assertApproxEqAbs(vault.claimableTaoOf(alice, TOKEN1), donated, 2);
        _claimAs(alice);
        assertApproxEqAbs(alice.balance, donated, 2);
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
        assertApproxEqAbs(vault.claimableTaoOf(alice, TOKEN1), donated, 2);
    }

    function test_UnwrapForTaoAfterDonation_ExitPaysSaleProceedsOnly() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _depositAndWrap(bob, NETUID1, DEPOSIT);
        uint256 donated = 5 ether;
        _donateToTokenClone(TOKEN1, donated);

        uint256 shares = vault.balanceOf(bob, TOKEN1);
        vm.prank(bob);
        vault.unwrapForTao(TOKEN1, shares, 0);

        _assertCloneCoversReservedTao(TOKEN1);
        assertApproxEqAbs(vault.claimableTaoOf(alice, TOKEN1) + vault.claimableTaoOf(bob, TOKEN1), donated, 4);
    }

    function testFuzz_ClaimsAcrossHolders_ConserveArrivedTao(uint256 donation, uint256 aliceDeposit, uint256 bobDeposit)
        public
    {
        donation = bound(donation, 1e9, 1_000_000 ether);
        aliceDeposit = bound(aliceDeposit, 1 ether, 1_000_000 ether);
        bobDeposit = bound(bobDeposit, 1 ether, 1_000_000 ether);

        _depositAndWrap(alice, NETUID1, aliceDeposit);
        _depositAndWrap(bob, NETUID1, bobDeposit);
        _donateToTokenClone(TOKEN1, donation);

        _claimAs(alice);
        _claimAs(bob);

        uint256 paid = alice.balance + bob.balance;
        assertLe(paid, donation);
        assertApproxEqAbs(paid, donation, 4);
    }

    // -------------------- Dissolution seam ---------------------------------------

    function test_DissolutionRefund_NotIndexedToHolders() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        uint256 indexBefore = vault.cumulativeTaoPerShare(TOKEN1);

        _simulateDissolutionStarted(NETUID1);
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

        _claimAs(alice);
        assertApproxEqAbs(alice.balance, previewTao + donated / 2, 4);
    }

    function test_ClaimDuringBlackout_PaysExistingEntitlement() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        uint256 donated = 5 ether;
        _donateToTokenClone(TOKEN1, donated);
        _touch(alice, TOKEN1);

        _simulateDissolutionStarted(NETUID1);

        _claimAs(alice);
        assertApproxEqAbs(alice.balance, donated, 2);
    }

    function test_TransferWithBrokenSubnetPrecompile_PausesIndexing() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _donateToTokenClone(TOKEN1, 5 ether);

        vm.etch(SUBNET_PRECOMPILE, hex"60006000fd");
        _touch(alice, TOKEN1);
        assertEq(vault.taoLiability(TOKEN1), 0);
        assertEq(vault.claimableTaoOf(alice, TOKEN1), 0);

        vm.etch(SUBNET_PRECOMPILE, hex"00");
        _touch(alice, TOKEN1);
        assertEq(vault.taoLiability(TOKEN1), 0);
        assertEq(vault.claimableTaoOf(alice, TOKEN1), 0);

        // A failure that consumes everything forwarded must still leave the transfer enough gas.
        vm.etch(SUBNET_PRECOMPILE, hex"fe");
        _touch(alice, TOKEN1);
        assertEq(vault.taoLiability(TOKEN1), 0);
        assertEq(vault.claimableTaoOf(alice, TOKEN1), 0);
    }

    function test_DonationDuringBlackout_StaysInDissolvedBacking() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _simulateDissolutionStarted(NETUID1);
        _donateToTokenClone(TOKEN1, 5 ether);

        _touch(alice, TOKEN1);

        assertEq(vault.taoLiability(TOKEN1), 0);
        assertEq(vault.claimableTaoOf(alice, TOKEN1), 0);
    }

    // -------------------- Zero-supply quarantine ----------------------------------

    function test_TaoArrivingAtZeroSupply_IsQuarantined() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _exitCompletely(alice, TOKEN1);
        assertEq(vault.totalSupply(TOKEN1), 0);

        uint256 orphaned = 5 ether;
        _donateToTokenClone(TOKEN1, orphaned);
        _depositAndWrap(bob, NETUID1, DEPOSIT);

        assertEq(vault.excludedTao(TOKEN1), orphaned);
        assertEq(vault.claimableTaoOf(bob, TOKEN1), 0);
        assertEq(vault.taoLiability(TOKEN1), 0);
    }

    function test_RecoverAfterDissolution_PaysUnquarantinedRemainder() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _exitCompletely(alice, TOKEN1);
        _simulateDissolutionStarted(NETUID1);
        uint256 orphaned = 5 ether;
        _donateToTokenClone(TOKEN1, orphaned);
        _simulateDissolutionCompleted(NETUID1);

        address treasury = makeAddr("treasury");
        vault.recoverExcludedTao(TOKEN1, payable(treasury));

        assertEq(treasury.balance, orphaned);
    }

    function test_RecoverExcludedTao_PaysRecipient() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _exitCompletely(alice, TOKEN1);
        uint256 orphaned = 5 ether;
        _donateToTokenClone(TOKEN1, orphaned);

        address treasury = makeAddr("treasury");
        vm.expectEmit(true, false, false, true, address(vault));
        emit ExcludedTaoRecovered(TOKEN1, treasury, orphaned);
        vault.recoverExcludedTao(TOKEN1, payable(treasury));

        assertEq(treasury.balance, orphaned);
        assertEq(vault.excludedTao(TOKEN1), 0);
    }

    function test_RevertWhen_RecoverCalledByNonOwner() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        vault.recoverExcludedTao(TOKEN1, payable(alice));
    }

    function test_RevertWhen_RecoveringWithNothingExcluded() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.recoverExcludedTao(TOKEN1, payable(owner));
    }

    function test_RevertWhen_RecoveringForUnknownToken() public {
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.recoverExcludedTao(type(uint256).max, payable(owner));
    }
}
