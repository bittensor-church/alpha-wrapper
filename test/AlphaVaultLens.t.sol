// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { VaultMath } from "src/libraries/VaultMath.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { AlphaVaultLens } from "src/AlphaVaultLens.sol";
import {
    AlphaTransfersDisabled,
    Parked,
    SharePriceBelowPrecision,
    ShortfallOnFile,
    ZeroAddress
} from "src/VaultErrors.sol";
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

    function testFuzz_SharePrice_AgreesWithThePreviewOfOneShareUnit(uint256 deposit, uint256 emissions, uint256 shares)
        public
    {
        deposit = bound(deposit, 1e7, 1e20);
        emissions = bound(emissions, 0, 1e20);
        shares = bound(shares, 1, _depositAndWrap(alice, NETUID1, deposit));
        _simulateEmissions(NETUID1, emissions);

        uint256 price = lens.sharePrice(TOKEN1);
        (uint256 unitAlpha,) = lens.previewUnwrap(TOKEN1, VaultMath.SHARE_PRICE_SCALE);
        assertEq(price, unitAlpha, "one share unit");
        (uint256 alpha,) = lens.previewUnwrap(TOKEN1, shares);
        assertLe(
            (shares * price) / VaultMath.SHARE_PRICE_SCALE,
            alpha,
            "a balance valued at the price never overstates its exit"
        );
    }

    function test_SharePrice_RefusesToQuoteBelowItsPrecision() public {
        _depositAndWrap(alice, NETUID1, 1e10);
        bytes32[] memory recorded = _hotkeys(hotkey1, hotkey2, hotkey3);
        for (uint256 i; i < recorded.length; ++i) {
            _simulateOffVaultSwap(NETUID1, recorded[i], keccak256(abi.encode("stray", i)));
        }
        _runOutRecoveryWindow(TOKEN1);
        _reattestCurrentSet(NETUID1);
        uint256 bobShares = _depositAndWrap(bob, NETUID1, 1e10);

        (uint256 alpha,) = lens.previewUnwrap(TOKEN1, bobShares);
        assertApproxEqAbs(alpha, 1e10, 2, "the burn quote still prices the position");
        vm.expectRevert(SharePriceBelowPrecision.selector);
        lens.sharePrice(TOKEN1);
    }

    /// @dev Virtual offsets must not imply value when actual backing is zero.
    function testFuzz_SharePrice_QuotesZeroAfterACompleteWriteOff(uint256 deposit) public {
        deposit = bound(deposit, 1e7, 1e20);
        _depositAndWrap(alice, NETUID1, deposit);
        bytes32[] memory recorded = _hotkeys(hotkey1, hotkey2, hotkey3);
        for (uint256 i; i < recorded.length; ++i) {
            _simulateOffVaultSwap(NETUID1, recorded[i], keccak256(abi.encode("stray", i)));
        }
        _runOutRecoveryWindow(TOKEN1);

        assertEq(lens.totalStake(TOKEN1), 0, "the scenario needs the whole backing written off");
        assertEq(lens.sharePrice(TOKEN1), 0);
    }

    function test_PreviewUnwrap_QuotesZeroAfterTheLastHolderExits() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 ether);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        assertEq(vault.totalSupply(TOKEN1), 0, "the exit must retire the whole supply");

        (uint256 alpha, uint256 tao) = lens.previewUnwrap(TOKEN1, 1);
        assertEq(alpha, 0, "alpha");
        assertEq(tao, 0, "tao");
    }

    /// @dev NETUID2 is configured but has no clone.
    function test_ClaimableTaoOf_QuotesZeroBeforeTheCloneExists() public view {
        assertEq(vault.subnetClone(TOKEN2), address(0), "the scenario needs a position with no clone");
        assertEq(lens.claimableTaoOf(alice, TOKEN2), 0);
    }

    function test_ClaimableTaoOf_QuotesZeroWhenTaoArrivesWithNoHolders() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 ether);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        _donateToClone(vault.subnetClone(TOKEN1), 5 ether);

        assertEq(lens.claimableTaoOf(alice, TOKEN1), 0);
    }

    function test_Constructor_ResolvesTheVaultsRegistry() public view {
        assertEq(address(lens.validatorRegistry()), address(vault.validatorRegistry()));
    }

    function test_BatchClaimableTaoOf_MatchesTheSingleQuotePositionForPosition() public {
        _depositAndWrap(alice, NETUID1, 10 ether);
        _depositAndWrap(alice, NETUID2, 4 ether);
        _donateToClone(vault.subnetClone(TOKEN1), 3 ether);
        _donateToClone(vault.subnetClone(TOKEN2), 1 ether);

        uint256 unseeded = vault.currentTokenId(NETUID2) + 1;
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

    function test_ParkedToken_ReportsItsStateAndRefusesTheMintQuote() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        vault.syncBacking(TOKEN1);
        vault.recoverStray(TOKEN1, hotkey4);
        vault.syncBacking(TOKEN1);

        assertTrue(lens.awaitingAttestation(TOKEN1), "the lens reports the parked position");
        assertTrue(lens.isBackingIntact(TOKEN1), "parked backing is whole");
        assertEq(lens.frozenUntil(TOKEN1), 0, "and no clock runs on it");
        assertEq(lens.lastSeenHotkeys(TOKEN1)[0], vault.parkingHotkey(), "the record names the parking hotkey");
        assertGt(lens.sharePrice(TOKEN1), 0, "the position still quotes");
        vm.expectRevert(Parked.selector);
        lens.previewWrap(TOKEN1, 1 ether);

        _reattestCurrentSet(NETUID1);
        assertFalse(lens.awaitingAttestation(TOKEN1), "a newer attestation releases it");
        assertGt(lens.previewWrap(TOKEN1, 1 ether), 0, "and the mint quote answers again");
    }

    function test_DisabledTransfers_RefuseTheAlphaQuotesOnly() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _setTransfersEnabled(NETUID1, false);

        bytes memory refusal = abi.encodeWithSelector(AlphaTransfersDisabled.selector, uint16(NETUID1));
        vm.expectRevert(refusal);
        lens.previewWrap(TOKEN1, 1 ether);
        vm.expectRevert(refusal);
        lens.previewUnwrap(TOKEN1, 1 ether);
        assertGt(lens.sharePrice(TOKEN1), 0, "the position still prices");
    }

    function test_DeclaredShortfall_ReadsAsNotIntactUntilSynced() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        assertEq(lens.frozenUntil(TOKEN1), VaultReads.UNDECLARED_SHORTFALL, "short and not yet declared");
        vault.syncBacking(TOKEN1);
        _simulateOffVaultSwap(NETUID1, hotkey4, hotkey1);

        assertFalse(lens.isBackingIntact(TOKEN1), "the alpha is back but the shortfall is still on file");
        assertEq(lens.frozenUntil(TOKEN1), block.timestamp + RECOVERY_WINDOW, "with its clock still running");
        vm.expectRevert(ShortfallOnFile.selector);
        lens.sharePrice(TOKEN1);
        vm.expectRevert(ShortfallOnFile.selector);
        lens.previewUnwrap(TOKEN1, 1 ether);

        vault.syncBacking(TOKEN1);
        assertTrue(lens.isBackingIntact(TOKEN1), "syncing takes it off file");
        assertEq(lens.frozenUntil(TOKEN1), 0, "and stops the clock");
    }

    function test_DissolvedToken_ReadsWithoutARecordToAnswerTo() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 staked = _totalVaultStakeAcrossHotkeys(NETUID1);

        _reregisterSubnet(NETUID1);

        assertEq(lens.locatedStake(TOKEN1), staked, "the reading counts what the record names");
        assertTrue(lens.isBackingIntact(TOKEN1), "with nothing to be short against");
        assertEq(lens.frozenUntil(TOKEN1), 0, "and nothing holding it shut");
    }

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
