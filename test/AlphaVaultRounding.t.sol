// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVault } from "src/AlphaVault.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";

/// @dev Rounding-to-zero and empty-state guards for the share math, split out of AlphaVault.t.sol.
///      Shares its setup/helpers with the other suites via the common AlphaVaultTestBase.
contract AlphaVaultRoundingTest is AlphaVaultTestBase {
    // Inflate the pool so the share price sits far above 1 asset/share: alice seeds 2e6 (supply 2e15),
    // then 1e22 of emissions accrue. The rounding boundary for a fresh deposit becomes
    // ~ preStake / supply = 1e22 / 2e15 ≈ 5e6 assets, well above the 2e6 minRebalanceAmt floor.
    function _inflatedPool() private {
        _simulateAlphaDeposit(alice, NETUID1, 2e6);
        _wrap(alice, NETUID1);
        _simulateEmissions(NETUID1, 1e22);
    }

    // Deposits that clear the minRebalanceAmt floor but still price to 0 shares against the inflated
    // pool (≤ 4e6, safely below the ~5e6 boundary) must revert ZeroAmount and mint nothing.
    function testFuzz_WrapRevertsWhenDepositRoundsToZeroShares(uint256 dust) public {
        _inflatedPool();
        dust = bound(dust, vault.minRebalanceAmt(), 4e6);

        _simulateAlphaDeposit(bob, NETUID1, dust);
        vm.prank(bob);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.wrap(bob, NETUID1, hotkey1);

        assertEq(vault.balanceOf(bob, TOKEN1), 0);
    }

    // Deposits past the rounding boundary (≥ 1e7, safely above ~5e6) are accepted and mint real shares.
    function testFuzz_WrapAcceptsDepositsAboveRoundingBoundary(uint256 deposit) public {
        _inflatedPool();
        deposit = bound(deposit, 1e7, type(uint64).max);

        _simulateAlphaDeposit(bob, NETUID1, deposit);
        _wrapHotkey(bob, NETUID1, hotkey1);

        assertGt(vault.balanceOf(bob, TOKEN1), 0);
    }

    function test_UnwrapRejectsDustSharesButPaysRealAmount() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        // 1 share against ~1e28 supply / ~1e19 stake rounds to 0 assets: fires the assets==0
        // guard (not NothingToUnwrap, totalAlpha is still > 0), no shares burned.
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.unwrap(TOKEN1, 1, _toSubstrate(alice));
        assertEq(vault.balanceOf(alice, TOKEN1), shares);

        // A real share amount redeems for its proportional value.
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice));
        uint256 received = _getStake(hotkey1, alice, NETUID1) + _getStake(hotkey2, alice, NETUID1)
            + _getStake(hotkey3, alice, NETUID1);
        assertApproxEqAbs(received, 5 ether, 1e9);
    }

    function test_DissolvedUnwrapRevertsOnZeroTaoButRedeemsWhenFunded() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);
        address clone = vault.subnetClone(tokenId);

        _simulateDissolutionStarted(tokenId, 0);
        _simulateTaoAwardedOnDissolution(tokenId, 0);
        _simulateDissolutionCompleted(NETUID1);

        // Clone holds 0 TAO -> unwrap reverts NothingToUnwrap without burning shares.
        assertEq(clone.balance, 0);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.NothingToUnwrap.selector);
        vault.unwrap(tokenId, shares, _toSubstrate(alice));

        // Shares survived: once the dissolution TAO lands, the same position redeems for it.
        vm.deal(clone, 7 ether);
        uint256 before = alice.balance;
        vm.prank(alice);
        vault.unwrap(tokenId, shares, _toSubstrate(alice));
        assertEq(alice.balance - before, 7 ether);
        assertEq(vault.balanceOf(alice, tokenId), 0);
    }
}
