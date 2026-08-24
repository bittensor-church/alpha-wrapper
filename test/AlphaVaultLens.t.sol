// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Tests the lens contract that answers every question about a vault position: how much alpha
// backs it, what a share is worth, what a deposit or an exit would pay, and how much TAO a
// holder can claim. The lens stores nothing itself, so anyone can deploy their own against the
// same vault and must get the same answers. These tests check that, and that a lens cannot be
// created without a vault to read.

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { AlphaVaultLens } from "src/AlphaVaultLens.sol";
import { ZeroAddress } from "src/VaultErrors.sol";

contract AlphaVaultLensTest is AlphaVaultTestBase {
    function test_RevertWhen_ConstructedWithoutAVault() public {
        vm.expectRevert(ZeroAddress.selector);
        new AlphaVaultLens(AlphaVault(address(0)));
    }

    function test_Constructor_RecordsTheVaultItReads() public view {
        assertEq(address(lens.vault()), address(vault));
    }

    /// @dev A position whose shares were all burned still has a clone, and integrators poll it.
    ///      The quote reports nothing left rather than reverting on the division.
    function test_PreviewUnwrap_QuotesZeroAfterTheLastHolderExits() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));
        assertEq(vault.totalSupply(TOKEN1), 0, "the exit must retire the whole supply");

        (uint256 alpha, uint256 tao) = lens.previewUnwrap(TOKEN1, 1);
        assertEq(alpha, 0, "alpha");
        assertEq(tao, 0, "tao");
    }

    /// @dev NETUID2 is configured but never deposited into, so its clone does not exist yet.
    function test_ClaimableTaoOf_QuotesZeroBeforeTheCloneExists() public view {
        assertEq(vault.subnetClone(TOKEN2), address(0), "the scenario needs a position with no clone");
        assertEq(lens.claimableTaoOf(alice, TOKEN2), 0);
    }

    /// @dev TAO landing on a clone with no holders left has no one to be attributed to, so it
    ///      stays unassigned instead of accruing to whoever exited.
    function test_ClaimableTaoOf_QuotesZeroWhenTaoArrivesWithNoHolders() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));
        _donateToClone(vault.subnetClone(TOKEN1), 5 ether);

        assertEq(lens.claimableTaoOf(alice, TOKEN1), 0);
    }

    /// @dev The lens keeps no state, so a replacement deployed against a live position must agree
    ///      with the original on every quote - including the slots a validator rotation left
    ///      behind and TAO the vault has not folded into its claim index yet.
    function testFuzz_SecondLens_AnswersIdenticallyToTheFirst(uint256 deposit, uint256 donation) public {
        deposit = bound(deposit, 1 ether, 1000 ether);
        // Claim quotes are floored to whole native-transfer quantums, and the per-share index
        // rounds down on the way there, so a donation at the quantum itself quotes as zero.
        donation = bound(donation, 1e12, 100 ether);

        _simulateAlphaDeposit(alice, NETUID1, deposit);
        _wrap(alice, NETUID1);

        // Rotate hotkey2 and hotkey3 out without a vault call, so the position's backing is spread
        // across remembered and current validators at the moment of the quote.
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey4), _weights(5_000, 5_000));
        _donateToClone(vault.subnetClone(TOKEN1), donation);

        AlphaVaultLens second = new AlphaVaultLens(vault);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        assertGt(lens.totalStake(TOKEN1), 0, "the scenario must leave backing to quote");
        assertGt(lens.claimableTaoOf(alice, TOKEN1), 0, "the scenario must leave TAO to claim");

        assertEq(second.totalStake(TOKEN1), lens.totalStake(TOKEN1), "totalStake");
        assertEq(second.sharePrice(TOKEN1), lens.sharePrice(TOKEN1), "sharePrice");
        assertEq(second.previewWrap(TOKEN1, deposit), lens.previewWrap(TOKEN1, deposit), "previewWrap");
        assertEq(second.claimableTaoOf(alice, TOKEN1), lens.claimableTaoOf(alice, TOKEN1), "claimableTaoOf");
        assertEq(second.getCurrentValidators(NETUID1), lens.getCurrentValidators(NETUID1), "getCurrentValidators");

        (uint256 alphaFromSecond, uint256 taoFromSecond) = second.previewUnwrap(TOKEN1, shares);
        (uint256 alphaFromFirst, uint256 taoFromFirst) = lens.previewUnwrap(TOKEN1, shares);
        assertEq(alphaFromSecond, alphaFromFirst, "previewUnwrap alpha");
        assertEq(taoFromSecond, taoFromFirst, "previewUnwrap tao");
    }
}
