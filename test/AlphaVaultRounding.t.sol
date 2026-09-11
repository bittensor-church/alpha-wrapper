// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { CHAIN_MIN_STAKE } from "./mocks/MockStaking.sol";
import { VaultMath } from "src/libraries/VaultMath.sol";
import { ClaimBelowNativePrecision, NothingToUnwrap, ZeroAmount } from "src/VaultErrors.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";

contract AlphaVaultRoundingTest is AlphaVaultTestBase {
    // Emissions put the zero-share rounding boundary (~5e6 assets) above the 2e6 stake floor.
    function _inflatedPool() private {
        _simulateAlphaDeposit(alice, NETUID1, CHAIN_MIN_STAKE);
        _wrap(alice, NETUID1);
        _simulateEmissions(NETUID1, 1e22);
    }

    function testFuzz_WrapRevertsWhenDepositRoundsToZeroShares(uint256 dust) public {
        _inflatedPool();
        dust = bound(dust, CHAIN_MIN_STAKE, 2 * CHAIN_MIN_STAKE);

        _simulateAlphaDeposit(bob, NETUID1, dust);
        vm.prank(bob);
        vm.expectRevert(ZeroAmount.selector);
        vault.wrap(NETUID1, hotkey1, 0);

        assertEq(vault.balanceOf(bob, TOKEN1), 0);
    }

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

        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        vault.unwrap(TOKEN1, 1, _toSubstrate(alice), 0);
        assertEq(vault.balanceOf(alice, TOKEN1), shares);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);
        uint256 received = _userStakeAcrossHotkeys(alice, NETUID1);
        assertApproxEqAbs(received, 5 ether, 1e9);
    }

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

        uint256 aliceExpected = _wholeRao((pot * aliceShares) / (aliceShares + bobShares));
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        if (aliceExpected == 0) vm.expectRevert(ClaimBelowNativePrecision.selector);
        vault.unwrap(tokenId, aliceShares, _toSubstrate(alice), 0);
        assertEq(alice.balance - aliceBefore, aliceExpected);

        uint256 bobExpected = _wholeRao(((pot - aliceExpected) * bobShares) / vault.totalSupply(tokenId));
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        if (bobExpected == 0) vm.expectRevert(ClaimBelowNativePrecision.selector);
        vault.unwrap(tokenId, bobShares, _toSubstrate(bob), 0);
        assertEq(bob.balance - bobBefore, bobExpected);

        assertEq(clone.balance, pot - aliceExpected - bobExpected, "every wei is paid out or still in the pot");
        assertLt(clone.balance, 2 * VaultMath.TAO_NATIVE_QUANTUM, "at most one sub-RAO tail per exit stays behind");
    }

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
        if (taoQuote == 0) vm.expectRevert(ClaimBelowNativePrecision.selector);
        vault.unwrap(tokenId, shares, _toSubstrate(alice), 0);
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

        assertEq(clone.balance, 0);
        vm.prank(alice);
        vm.expectRevert(NothingToUnwrap.selector);
        vault.unwrap(tokenId, shares, _toSubstrate(alice), 0);

        vm.deal(clone, 7 ether);
        uint256 before = alice.balance;
        vm.prank(alice);
        vault.unwrap(tokenId, shares, _toSubstrate(alice), 0);
        assertEq(alice.balance - before, 7 ether);
        assertEq(vault.balanceOf(alice, tokenId), 0);
    }
}
