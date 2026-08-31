// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { NothingToUnwrap, ZeroAmount } from "src/VaultErrors.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { VaultMath } from "src/libraries/VaultMath.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { MockStaking, CHAIN_MIN_STAKE } from "./mocks/MockStaking.sol";

/// @dev Rounding-to-zero and empty-state guards for the share math, split out of AlphaVault.t.sol.
///      Shares its setup/helpers with the other suites via the common AlphaVaultTestBase.
contract AlphaVaultRoundingTest is AlphaVaultTestBase {
    // Inflate the pool so the share price sits far above 1 asset/share: alice seeds 2e6 (supply 2e15),
    // then 1e22 of emissions accrue. The rounding boundary for a fresh deposit becomes
    // ~ preStake / supply = 1e22 / 2e15 ~ 5e6 assets, well above the 2e6 minimum-stake floor.
    function _inflatedPool() private {
        _simulateAlphaDeposit(alice, NETUID1, 2e6);
        _wrap(alice, NETUID1);
        _simulateEmissions(NETUID1, 1e22);
    }

    // Deposits that clear the 2e6 minimum-stake floor but still price to 0 shares against the inflated
    // pool (<= 4e6, safely below the ~5e6 boundary) must revert ZeroAmount and mint nothing.
    function testFuzz_WrapRevertsWhenDepositRoundsToZeroShares(uint256 dust) public {
        _inflatedPool();
        dust = bound(dust, 2e6, 4e6);

        _simulateAlphaDeposit(bob, NETUID1, dust);
        vm.prank(bob);
        vm.expectRevert(ZeroAmount.selector);
        vault.wrap(NETUID1, hotkey1);

        assertEq(vault.balanceOf(bob, TOKEN1), 0);
    }

    // Deposits past the rounding boundary (>= 1e7, safely above ~5e6) are accepted and mint real shares.
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
        vm.expectRevert(ZeroAmount.selector);
        vault.unwrap(TOKEN1, 1, _toSubstrate(alice));
        assertEq(vault.balanceOf(alice, TOKEN1), shares);

        // A real share amount pays out its proportional value.
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice));
        uint256 received = _userStakeAcrossHotkeys(alice, NETUID1);
        assertApproxEqAbs(received, 5 ether, 1e9);
    }

    function testFuzz_FullLiveUnwrap_DrainsAllBackingAfterEmissions(uint256 deposit, uint256 emissions) public {
        deposit = bound(deposit, CHAIN_MIN_STAKE, type(uint64).max / 2);
        emissions = bound(emissions, 1, type(uint64).max / 2);

        _simulateAlphaDeposit(alice, NETUID1, deposit);
        _wrap(alice, NETUID1);
        _simulateEmissions(NETUID1, emissions);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        uint256 backing = lens.totalStake(TOKEN1);
        uint256 virtualShareQuote = VaultMath.assetsFor(backing, vault.totalSupply(TOKEN1), shares);
        assertLt(virtualShareQuote, backing, "fixture must expose the terminal virtual-share residue");

        (uint256 previewAlpha, uint256 previewTao) = lens.previewUnwrap(TOKEN1, shares);
        assertEq(previewAlpha, backing, "a full live burn quotes every backed alpha");
        assertEq(previewTao, 0);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), backing, "the terminal holder receives every backed alpha");
        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1), 0, "a zero-supply position retains no alpha");
        assertEq(vault.totalSupply(TOKEN1), 0);
    }

    function test_FullLiveUnwrap_DeliversPostConsolidationBalanceWhenMovesRoundDown() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);
        _simulateEmissions(NETUID1, 5 ether);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(1);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 previewAlpha,) = lens.previewUnwrap(TOKEN1, shares);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));

        uint256 delivered = _userStakeAcrossHotkeys(alice, NETUID1);
        assertEq(previewAlpha - delivered, 2, "two consolidation hops each lose one RAO");
        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1), 0);
        assertEq(vault.totalSupply(TOKEN1), 0);
    }

    function test_PreviewUnwrap_CapsSharesAboveSupplyOnLiveAndDissolvedPaths() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        uint256 supply = vault.totalSupply(TOKEN1);
        uint256 alphaBacking = lens.totalStake(TOKEN1);
        (uint256 alphaQuote, uint256 taoQuote) = lens.previewUnwrap(TOKEN1, supply + 1);
        assertEq(alphaQuote, alphaBacking);
        assertEq(taoQuote, 0);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, 40 ether);
        _simulateDissolutionCompleted(NETUID1);

        (alphaQuote, taoQuote) = lens.previewUnwrap(TOKEN1, supply + 1);
        assertEq(alphaQuote, 0);
        assertEq(taoQuote, 40 ether);
    }

    // The dissolved payout floors each holder's pro-rata cut, so earlier exits can round down;
    // whatever they leave behind must land with the last holder and never exceed the pot. A
    // one-wei pot also pins that a cut rounding to 0 still burns the shares and pays nothing.
    function testFuzz_DissolvedUnwrapConservesRefundPot(uint256 aliceDeposit, uint256 bobDeposit, uint256 pot) public {
        aliceDeposit = bound(aliceDeposit, 1e7, 1e20);
        bobDeposit = bound(bobDeposit, 1e7, 1e20);
        pot = bound(pot, 1, 1e24);

        _simulateAlphaDeposit(alice, NETUID1, aliceDeposit);
        _wrap(alice, NETUID1);
        _simulateAlphaDeposit(bob, NETUID1, bobDeposit);
        _wrap(bob, NETUID1);

        uint256 tokenId = vault.currentTokenId(NETUID1);
        address clone = vault.subnetClone(tokenId);
        uint256 aliceShares = vault.balanceOf(alice, tokenId);
        uint256 bobShares = vault.balanceOf(bob, tokenId);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(tokenId, pot);
        _simulateDissolutionCompleted(NETUID1);

        uint256 aliceExpected = (pot * aliceShares) / (aliceShares + bobShares);
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrap(tokenId, aliceShares, _toSubstrate(alice));
        assertEq(alice.balance - aliceBefore, aliceExpected);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        vault.unwrap(tokenId, bobShares, _toSubstrate(bob));
        assertEq(bob.balance - bobBefore, pot - aliceExpected);

        assertEq(clone.balance, 0);
        assertEq(vault.totalSupply(tokenId), 0);
    }

    // A quoted dissolved payout is a commitment: unwrapping the same shares must pay exactly it.
    function testFuzz_PreviewUnwrapMatchesDissolvedPayout(uint256 deposit, uint256 pot, uint256 shares) public {
        deposit = bound(deposit, 1e7, 1e20);
        pot = bound(pot, 1, 1e24);

        _simulateAlphaDeposit(alice, NETUID1, deposit);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        shares = bound(shares, 1, vault.balanceOf(alice, tokenId));

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(tokenId, pot);
        _simulateDissolutionCompleted(NETUID1);

        (uint256 alphaQuote, uint256 taoQuote) = lens.previewUnwrap(tokenId, shares);
        assertEq(alphaQuote, 0);

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.unwrap(tokenId, shares, _toSubstrate(alice));
        assertEq(alice.balance - before, taoQuote);
    }

    function test_DissolvedUnwrap_RevertsOnZeroTaoThenPaysOnceFunded() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);
        address clone = vault.subnetClone(tokenId);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(tokenId, 0);
        _simulateDissolutionCompleted(NETUID1);

        // Clone holds 0 TAO -> unwrap reverts NothingToUnwrap without burning shares.
        assertEq(clone.balance, 0);
        vm.prank(alice);
        vm.expectRevert(NothingToUnwrap.selector);
        vault.unwrap(tokenId, shares, _toSubstrate(alice));

        // Shares survived: once the dissolution TAO lands, the same position pays out.
        vm.deal(clone, 7 ether);
        uint256 before = alice.balance;
        vm.prank(alice);
        vault.unwrap(tokenId, shares, _toSubstrate(alice));
        assertEq(alice.balance - before, 7 ether);
        assertEq(vault.balanceOf(alice, tokenId), 0);
    }
}
