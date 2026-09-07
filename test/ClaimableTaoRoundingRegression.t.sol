// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { ZeroAmount } from "src/VaultErrors.sol";

contract ClaimableTaoRoundingRegressionTest is AlphaVaultTestBase {
    /// @dev Arithmetic stress regression. Exact effective inputs from the original shrunk trace;
    ///      independent of handler seed mapping and future changes to fuzz bounds.
    function test_TinyTransfersAndNearFullExitsPreservePreviouslyEarnedClaims() public {
        address carol = makeAddr("carol");
        _depositAndWrap(alice, NETUID1, 50 ether);
        _depositAndWrap(bob, NETUID1, 50 ether);
        _depositAndWrap(carol, NETUID1, 50 ether);
        address clone = vault.subnetClone(TOKEN1);

        _donateToClone(clone, 813_676_692_912_666_046_992);
        _transfer(carol, alice, 2827);
        _donateToClone(clone, 102_142_341_534_152);
        _sell(alice, 29_673_993_276_002_729_355_177_199_998);
        _sell(carol, 80_000_000_000_000_000_000);
        _transfer(alice, carol, 13_107_892_645_965_101_188);
        _donateToClone(clone, 96_059_874);
        _sell(carol, vault.balanceOf(carol, TOKEN1) - 2);
        _sell(alice, vault.balanceOf(alice, TOKEN1) - 1);
        _sell(bob, vault.balanceOf(bob, TOKEN1) - 2);
        _transfer(bob, carol, 40_000_000);
        _transfer(alice, carol, 1);
        _claimQuotedAmount(bob, TOKEN1);

        vm.expectRevert(ZeroAmount.selector);
        _sell(carol, 17_820);
        _claimQuotedAmount(carol, TOKEN1);
        _donateToClone(clone, 4359);

        uint256 paid = _claimQuotedAmount(alice, TOKEN1);
        // The holders started equal; the 2,827-share transfer shifts less than one wei of the
        // second large gift. Bound the later small gifts by their entire value, without replaying
        // the production index arithmetic.
        uint256 earlyGifts = 813_676_692_912_666_046_992 + 102_142_341_534_152;
        assertApproxEqAbs(paid, earlyGifts / 3, 1e9 + 96_059_874 + 4359, "Alice keeps her historical third");
        assertGe(clone.balance, vault.taoLiability(TOKEN1));
    }

    function _transfer(address from, address to, uint256 shares) private {
        vm.prank(from);
        vault.safeTransferFrom(from, to, TOKEN1, shares, "");
    }

    function _sell(address holder, uint256 shares) private {
        vm.prank(holder);
        vault.unwrapForTao(TOKEN1, shares, 0);
    }
}
