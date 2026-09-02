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
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract AlphaVaultLensTest is AlphaVaultTestBase {
    function test_RevertWhen_ConstructedWithoutAVault() public {
        vm.expectRevert(ZeroAddress.selector);
        new AlphaVaultLens(AlphaVault(address(0)));
    }

    function test_Constructor_RecordsTheVaultItReads() public view {
        assertEq(address(lens.vault()), address(vault));
    }

    /// @dev The price of a share is what a live unwrap of one share unit pays, virtual offsets
    ///      included, so a holder's `balance * sharePrice / 1e18` never overstates their exit.
    function testFuzz_SharePrice_MatchesTheLivePayoutOfOneShareUnit(uint256 deposit, uint256 emissions) public {
        deposit = bound(deposit, 1e7, 1e20);
        emissions = bound(emissions, 0, 1e20);
        _depositAndWrap(alice, NETUID1, deposit);
        _simulateEmissions(NETUID1, emissions);

        (uint256 alpha,) = lens.previewUnwrap(TOKEN1, 1e18);
        assertEq(lens.sharePrice(TOKEN1), alpha);
    }

    /// @dev A position whose shares were all burned still has a clone, and integrators poll it.
    ///      The quote reports nothing left rather than reverting on the division.
    function test_PreviewUnwrap_QuotesZeroAfterTheLastHolderExits() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 ether);

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
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 ether);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));
        _donateToClone(vault.subnetClone(TOKEN1), 5 ether);

        assertEq(lens.claimableTaoOf(alice, TOKEN1), 0);
    }

    /// @dev The lens keeps no state, so a replacement deployed against a live position must agree
    ///      with the original on every quote - including the slots a validator rotation left
    ///      behind and TAO the vault has not folded into its claim index yet.
    function test_SecondLens_AnswersIdenticallyToTheFirst() public {
        uint256 deposit = 100 ether;
        uint256 shares = _depositAndWrap(alice, NETUID1, deposit);

        // Rotate hotkey2 and hotkey3 out without a vault call, so the position's backing is spread
        // across remembered and current validators at the moment of the quote.
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey4), _weights(5_000, 5_000));
        _donateToClone(vault.subnetClone(TOKEN1), 5 ether);

        AlphaVaultLens second = new AlphaVaultLens(vault);

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

    function test_Constructor_ResolvesTheVaultsRegistry() public view {
        assertEq(address(lens.validatorRegistry()), address(vault.validatorRegistry()));
    }

    /// @dev The batch exists only to save the caller round trips, so its answers have to be the
    ///      single-position quotes exactly - including for a position the holder has nothing in,
    ///      and one whose clone was never created.
    function test_BatchClaimableTaoOf_MatchesTheSingleQuotePositionForPosition() public {
        _depositAndWrap(alice, NETUID1, 10 ether);
        _depositAndWrap(alice, NETUID2, 4 ether);
        _donateToClone(vault.subnetClone(TOKEN1), 3 ether);
        _donateToClone(vault.subnetClone(TOKEN2), 1 ether);

        uint256 unseeded = vault.currentTokenId(NETUID2) + 1; // no clone was ever deployed for it
        uint256[] memory ids = new uint256[](3);
        ids[0] = TOKEN1;
        ids[1] = TOKEN2;
        ids[2] = unseeded;

        uint256[] memory batch = lens.batchClaimableTaoOf(alice, ids);
        assertEq(batch.length, ids.length, "one amount per id");
        assertGt(batch[0], 0, "the scenario must leave TAO to quote");
        assertGt(batch[1], 0, "the scenario must leave TAO to quote on the second position");
        assertEq(batch[2], 0, "a position with no clone quotes nothing");
        for (uint256 i = 0; i < ids.length; i++) {
            assertEq(batch[i], lens.claimableTaoOf(alice, ids[i]), "batch diverged from the single quote");
        }
    }

    function test_BatchClaimableTaoOf_QuotesNothingForNoPositions() public view {
        assertEq(lens.batchClaimableTaoOf(alice, new uint256[](0)).length, 0);
    }

    /// @dev Order and repetition must not change an answer: the quote is a pure read of each
    ///      position, so a duplicated id quotes the same both times.
    function testFuzz_BatchClaimableTaoOf_IsOrderAndRepetitionIndependent(uint256 donation) public {
        donation = bound(donation, 1 gwei, 1e6 ether);
        _depositAndWrap(alice, NETUID1, 10 ether);
        _depositAndWrap(alice, NETUID2, 4 ether);
        _donateToClone(vault.subnetClone(TOKEN1), donation);

        uint256[] memory ids = new uint256[](4);
        ids[0] = TOKEN2;
        ids[1] = TOKEN1;
        ids[2] = TOKEN1;
        ids[3] = TOKEN2;

        uint256[] memory batch = lens.batchClaimableTaoOf(alice, ids);
        assertEq(batch[1], batch[2], "the same id quoted twice must agree");
        assertEq(batch[0], batch[3], "the same id quoted twice must agree");
        assertEq(batch[1], lens.claimableTaoOf(alice, TOKEN1), "TOKEN1");
        assertEq(batch[0], lens.claimableTaoOf(alice, TOKEN2), "TOKEN2");
    }

    /// @dev A dissolved position's alpha legitimately became TAO, so no record holds it to
    ///      anything: the reading answers plainly and reports nothing missing.
    function test_DissolvedToken_ReadsWithoutARecordToAnswerTo() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 staked = _totalVaultStakeAcrossHotkeys(NETUID1);

        // A new subnet on the same netuid retires the token id while its alpha stays staked.
        _setRegBlock(NETUID1, 999);

        assertEq(lens.locatedStake(TOKEN1), staked, "the reading counts what the record names");
        assertTrue(lens.isBackingIntact(TOKEN1), "with nothing to be short against");
        assertEq(lens.frozenUntil(TOKEN1), 0, "and nothing holding it shut");
    }

    /// @dev The chain drains balances while a subnet dissolves, so the gap against the record is
    ///      the drain rather than a loss. The watch surface keeps answering with the in-flux
    ///      reading and starts no clock.
    function test_DissolvingSubnet_ReadsTheDrainAsNoLoss() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateDissolutionStarted(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, 0);

        assertTrue(lens.isBackingIntact(TOKEN1), "the drain is not a shortfall");
        assertEq(lens.frozenUntil(TOKEN1), 0, "and starts no clock");
        assertEq(lens.totalStake(TOKEN1), lens.locatedStake(TOKEN1), "the total is the in-flux reading");
        assertLt(lens.totalStake(TOKEN1), 30 ether, "which reflects the drain so far");
    }
}
