// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Vm } from "forge-std/Test.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { CloneBase } from "src/CloneBase.sol";
import { DepositMailbox } from "src/DepositMailbox.sol";
import { SubnetClone } from "src/SubnetClone.sol";
import { ValidatorRegistry } from "src/ValidatorRegistry.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { MockStorageQuery } from "./mocks/MockStorageQuery.sol";
import { MockValidatorRegistry } from "./mocks/MockValidatorRegistry.sol";
import { AlphaVaultTestBase, STORAGE_QUERY } from "./AlphaVaultTestBase.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract AlphaVaultTest is AlphaVaultTestBase {
    event DissolvedSubnetUnwrapped(address indexed user, uint256 indexed tokenId, uint256 shares, uint256 taoOut);

    // ────────────────── Constructor ──────────────────────────────────────────

    function test_RevertWhen_ConstructorZeroMailboxLogic() public {
        vm.expectRevert(AlphaVault.ZeroAddress.selector);
        new AlphaVault("https://api.tao20.io/{id}.json", address(0), address(subnetLogic), address(registry));
    }

    function test_RevertWhen_ConstructorZeroSubnetLogic() public {
        vm.expectRevert(AlphaVault.ZeroAddress.selector);
        new AlphaVault("https://api.tao20.io/{id}.json", address(mailboxLogic), address(0), address(registry));
    }

    function test_RevertWhen_ConstructorZeroValidatorRegistry() public {
        vm.expectRevert(AlphaVault.ZeroAddress.selector);
        new AlphaVault("https://api.tao20.io/{id}.json", address(mailboxLogic), address(subnetLogic), address(0));
    }

    // ────────────────── Best Validator Selection ─────────────────────────────

    function test_GetBestValidatorsReturnsThree() public view {
        bytes32[3] memory hks = vault.getBestValidators(NETUID1);
        assertEq(hks[0], hotkey1);
        assertEq(hks[1], hotkey2);
        assertEq(hks[2], hotkey3);
    }

    function test_SingleValidatorNoSplit() public {
        _registerSubnet(99, hotkey4);

        _simulateAlphaDepositHotkey(alice, 99, 10 ether, hotkey4);
        _wrap(alice, 99);

        assertEq(_getVaultStake(hotkey4, 99), 10 ether);
    }

    // ────────────────── Deposit Address ──────────────────────────────────────

    function test_GetDepositAddress() public view {
        address a1 = vault.getDepositAddress(alice, NETUID1);
        address a2 = vault.getDepositAddress(alice, NETUID2);
        address b1 = vault.getDepositAddress(bob, NETUID1);

        assertTrue(a1 != a2);
        assertTrue(a1 != b1);
    }

    // ────────────────── Process Deposit ──────────────────────────────────────

    function test_Wrap() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        assertTrue(vault.balanceOf(alice, TOKEN1) > 0);
        assertEq(vault.totalStake(TOKEN1), 10 ether);
        // Total vault stake across all hotkeys should equal deposit
        uint256 total = _totalVaultStakeAcrossHotkeys(NETUID1);
        assertEq(total, 10 ether);
    }

    function test_WrapMultipleSubnets() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        _simulateAlphaDeposit(alice, NETUID2, 5 ether);
        _wrap(alice, NETUID2);

        assertTrue(vault.balanceOf(alice, TOKEN1) > 0);
        assertTrue(vault.balanceOf(alice, TOKEN2) > 0);
        assertEq(vault.totalStake(TOKEN1), 10 ether);
        assertEq(vault.totalStake(TOKEN2), 5 ether);
    }

    function test_WrapTwice() public {
        _simulateAlphaDeposit(alice, NETUID1, 5 ether);
        _wrap(alice, NETUID1);
        uint256 after1 = vault.balanceOf(alice, TOKEN1);

        _simulateAlphaDeposit(alice, NETUID1, 5 ether);
        _wrap(alice, NETUID1);
        uint256 after2 = vault.balanceOf(alice, TOKEN1);

        assertTrue(after2 > after1);
        assertEq(vault.totalStake(TOKEN1), 10 ether);
    }

    function test_RevertWhen_WrapZero() public {
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.wrap(alice, NETUID1, hotkey1);
    }

    // ────────────────── Share Price ──────────────────────────────────────────

    function test_SharePriceGrowsWithRewards() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        uint256 priceBefore = vault.sharePrice(TOKEN1);
        _simulateEmissions(NETUID1, 5 ether);
        uint256 priceAfter = vault.sharePrice(TOKEN1);

        assertTrue(priceAfter > priceBefore);
    }

    function test_EarlyWrapperCapturesEmissionsOverLateWrapper() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 aliceShares = vault.balanceOf(alice, TOKEN1);

        _simulateEmissions(NETUID1, 10 ether);

        _simulateAlphaDeposit(bob, NETUID1, 10 ether);
        _wrap(bob, NETUID1);
        uint256 bobShares = vault.balanceOf(bob, TOKEN1);

        // Same deposit after emissions buys fewer shares.
        assertLt(bobShares, aliceShares);

        // On exit alice realizes her share of the emission (~20), bob only ~his deposit (~10).
        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice));
        uint256 aliceReceived = _userStakeAcrossHotkeys(alice, NETUID1);

        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, _toSubstrate(bob));
        uint256 bobReceived = _userStakeAcrossHotkeys(bob, NETUID1);

        assertApproxEqAbs(aliceReceived, 20 ether, 1e12);
        assertApproxEqAbs(bobReceived, 10 ether, 1e12);
        assertGt(aliceReceived, bobReceived);
    }

    // ────────────────── Unwrap ─────────────────────────────────────────────

    function test_Unwrap() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        bytes32 aliceSub = _toSubstrate(alice);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceSub);

        assertEq(vault.balanceOf(alice, TOKEN1), 0);
        // Withdrawal comes from hotkeys with vault stake
        uint256 totalReceived = _userStakeAcrossHotkeys(alice, NETUID1);
        assertApproxEqAbs(totalReceived, 10 ether, 1e9);
        assertEq(vault.totalStake(TOKEN1), 0);
    }

    function test_WrapSyncsStakeBeforeMintingShares() public {
        _simulateAlphaDeposit(alice, NETUID1, 100 ether);
        _wrap(alice, NETUID1);
        uint256 aliceShares = vault.balanceOf(alice, TOKEN1);

        // Emissions accrue on the precompile but totalStake is NOT updated
        uint256 currentStake = _getVaultStake(hotkey1, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, currentStake + 100 ether);

        // Bob deposits 100 into a pool now worth 200 on the precompile
        _simulateAlphaDeposit(bob, NETUID1, 100 ether);
        _wrap(bob, NETUID1);
        uint256 bobShares = vault.balanceOf(bob, TOKEN1);

        // Fair shares = alice * 100/200 = alice / 2 (tiny dust from rebalance rounding)
        assertApproxEqAbs(bobShares, aliceShares / 2, 1e9, "bob shares should reflect synced pool value");
        assertLt(bobShares, aliceShares, "bob got too many shares - stale totalStake on deposit");
    }

    function test_FirstWrapDoesNotUnderflowWhenRebalanceRounds() public {
        // moveStake can lose 1 RAO to rounding on the real chain; the post-deposit accounting
        // must clamp instead of underflowing when in-set balances sum below the deposited amount.
        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(1);

        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        assertGt(vault.balanceOf(alice, TOKEN1), 0);

        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(0);
    }

    function test_UnwrapWithRewards() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        _simulateEmissions(NETUID1, 5 ether);

        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceSub);

        uint256 totalReceived = _userStakeAcrossHotkeys(alice, NETUID1);
        assertTrue(totalReceived > 10 ether, "Should receive deposit + rewards");
    }

    function test_RevertWhen_UnwrapOnZero() public {
        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.unwrap(TOKEN1, 0, aliceSub);
    }

    // ────────────────── Mailbox Security ─────────────────────────────────────

    function test_OnlyVaultCanFlush() public {
        _simulateAlphaDeposit(alice, NETUID1, 5 ether);
        _wrap(alice, NETUID1);

        address clone = vault.getDepositAddress(alice, NETUID1);
        _simulateAlphaDeposit(alice, NETUID1, 1 ether);

        vm.prank(bob);
        vm.expectRevert(CloneBase.NotWrapper.selector);
        CloneBase(payable(clone)).flush(bytes32(0), hotkey1, NETUID1, 1 ether);
    }

    function test_MailboxCannotReinitialize() public {
        _simulateAlphaDeposit(alice, NETUID1, 1 ether);
        _wrap(alice, NETUID1);

        address clone = vault.getDepositAddress(alice, NETUID1);
        vm.expectRevert(CloneBase.AlreadyInitialized.selector);
        CloneBase(payable(clone)).initialize(address(0xdead));
    }

    // ────────────────── Preview ──────────────────────────────────────────────

    function testFuzz_PreviewWrapScalesLinearlyOnEmptyVault(uint256 assets) public view {
        // Empty vault: previewWrap = assets * VIRTUAL_SHARES / VIRTUAL_ASSETS = assets * 1e9 (assets bound to u64).
        assets = bound(assets, 0, type(uint64).max);
        assertEq(vault.previewWrap(TOKEN1, assets), assets * 1e9);
    }

    function test_PreviewUnwrap() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 alpha, uint256 tao) = vault.previewUnwrap(TOKEN1, shares);
        assertEq(alpha, 10 ether);
        assertEq(tao, 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //   EDGE CASES
    // ══════════════════════════════════════════════════════════════════════

    // ────────────────── Unwrap partial shares ─────────────────────────

    function test_UnwrapPartialShares() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        bytes32 aliceSub = _toSubstrate(alice);

        // Unwrap half
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, aliceSub);

        // Should still have ~half the shares
        assertApproxEqAbs(vault.balanceOf(alice, TOKEN1), shares / 2, 1);
        // Vault should still have ~half the stake
        assertApproxEqAbs(vault.totalStake(TOKEN1), 5 ether, 0.01 ether);
    }

    // ────────────────── Multiple users deposit/unwrap interleaved ─────

    function test_InterleavedWrapsUnwraps() public {
        // Alice deposits 10
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 aliceShares = vault.balanceOf(alice, TOKEN1);

        // Bob deposits 20
        _simulateAlphaDeposit(bob, NETUID1, 20 ether);
        _wrap(bob, NETUID1);
        uint256 bobShares = vault.balanceOf(bob, TOKEN1);

        // Bob should have ~2x Alice's shares (same price)
        assertApproxEqRel(bobShares, aliceShares * 2, 0.01e18);

        // Alice unwraps everything
        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, aliceSub);
        assertEq(vault.balanceOf(alice, TOKEN1), 0);

        // Bob should still have his shares, totalStake should be ~20
        assertEq(vault.balanceOf(bob, TOKEN1), bobShares);
        assertApproxEqAbs(vault.totalStake(TOKEN1), 20 ether, 0.01 ether);

        // Bob unwraps
        bytes32 bobSub = _toSubstrate(bob);
        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, bobSub);
        assertEq(vault.balanceOf(bob, TOKEN1), 0);
        assertEq(vault.totalStake(TOKEN1), 0);
    }

    // ────────────────── wrap unauthorized ─────────────────────

    function test_WrapUnauthorized() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);

        // Bob (not alice, not owner) should revert
        vm.prank(bob);
        vm.expectRevert(AlphaVault.UnauthorizedCaller.selector);
        vault.wrap(alice, NETUID1, hotkey1);
    }

    function test_SubnetIsolation() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        _simulateAlphaDeposit(alice, NETUID2, 5 ether);
        _wrap(alice, NETUID2);

        // Rewards on NETUID1 should not affect NETUID2 share price
        _simulateEmissions(NETUID1, 10 ether);

        uint256 price1 = vault.sharePrice(TOKEN1);
        uint256 price2 = vault.sharePrice(TOKEN2);
        assertGt(price1, price2, "NETUID1 should have higher share price after rewards");

        // Withdrawing from NETUID2 should return ~5 ether, unaffected by NETUID1 rewards
        uint256 shares2 = vault.balanceOf(alice, TOKEN2);
        (uint256 preview2,) = vault.previewUnwrap(TOKEN2, shares2);
        assertApproxEqAbs(preview2, 5 ether, 0.01 ether);
    }

    // ────────────────── Virtual shares prevent inflation attack ────────

    function test_FirstWrapperInflationAttack() public {
        // Smallest D under default weights [3334, 3333, 3333] and MIN_STAKE_FLOOR = 2e6
        // where every per-slot move (D * 3333 / 10000) clears the floor: D ≥ 6_001_801.
        _simulateAlphaDeposit(alice, NETUID1, 6_001_802);
        _wrap(alice, NETUID1);

        // Inject large reward to inflate share price
        _simulateEmissions(NETUID1, 100 ether);

        // Victim deposits 10 ether
        _simulateAlphaDeposit(bob, NETUID1, 10 ether);
        _wrap(bob, NETUID1);

        // With virtual shares, Bob should still get meaningful shares
        uint256 bobShares = vault.balanceOf(bob, TOKEN1);
        assertGt(bobShares, 0, "Bob should get shares despite inflation attempt");

        // Bob's shares should be worth approximately his deposit
        (uint256 bobValue,) = vault.previewUnwrap(TOKEN1, bobShares);
        assertGt(bobValue, 9 ether, "Bob should not lose significant value to inflation attack");
    }

    // ────────────────── Share price starts at virtual offset ───────────

    function test_RevertWhen_SharePriceForUnregisteredSubnet() public {
        uint256 tokenId = uint256(uint16(42)) | (uint256(100) << 16);
        vm.expectRevert(AlphaVault.SubnetDissolved.selector);
        vault.sharePrice(tokenId);
    }

    function test_RevertWhen_SharePriceWhenSupplyIsZero() public {
        vault.createSubnetProxy(NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        assertEq(vault.totalSupply(tokenId), 0);
        vm.expectRevert(AlphaVault.NoSharesOutstanding.selector);
        vault.sharePrice(tokenId);
    }

    // ══════════════════════════════════════════════════════════════════════
    //   ADDITIONAL COVERAGE TESTS
    // ══════════════════════════════════════════════════════════════════════

    // ────────────────── rebalance() full function ────────────────────────

    function test_RebalanceWithRegistryWeights() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(6000, 4000));

        _simulateAlphaDepositHotkey(alice, NETUID1, 100 ether, hotkey1);
        _wrap(alice, NETUID1);

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, 100 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, _subnetColdkey(NETUID1), NETUID1, 0);

        vault.rebalance(NETUID1);

        assertApproxEqAbs(_getVaultStake(hotkey1, NETUID1), 60 ether, 1);
        assertApproxEqAbs(_getVaultStake(hotkey2, NETUID1), 40 ether, 1);
    }

    function test_RebalanceThreeValidators() public {
        uint16 bpsHk1 = 5000;
        uint16 bpsHk2 = 3000;
        uint16 bpsHk3 = 2000;
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(bpsHk1, bpsHk2, bpsHk3));

        _simulateAlphaDepositHotkey(alice, NETUID1, 100 ether, hotkey1);
        _wrap(alice, NETUID1);

        _setVaultStakes(NETUID1, 100 ether, 0, 0);

        vault.rebalance(NETUID1);

        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1), 100 ether, "Total stake preserved");
        assertEq(_getVaultStake(hotkey1, NETUID1), _weighted(100 ether, bpsHk1));
        assertEq(_getVaultStake(hotkey2, NETUID1), _weighted(100 ether, bpsHk2));
        assertEq(_getVaultStake(hotkey3, NETUID1), _weighted(100 ether, bpsHk3));
    }

    function test_RebalanceNoOpWhenAlreadyBalanced() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));

        _simulateAlphaDepositHotkey(alice, NETUID1, 50 ether, hotkey1);
        _wrap(alice, NETUID1);

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, 50 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, _subnetColdkey(NETUID1), NETUID1, 50 ether);

        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 50 ether);
        assertEq(_getVaultStake(hotkey2, NETUID1), 50 ether);
    }

    function test_RebalanceNoOpWhenCloneNotDeployed() public {
        vm.recordLogs();
        vault.rebalance(NETUID1);

        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0);
        assertEq(vault.subnetClone(TOKEN1), address(0));
        assertEq(vault.totalStake(TOKEN1), 0);
        bytes32[3] memory seen = vault.lastSeenHotkeys(TOKEN1);
        assertEq(seen[0], bytes32(0));
        assertEq(seen[1], bytes32(0));
        assertEq(seen[2], bytes32(0));
    }

    function test_RebalanceEmitsEvent() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(8000, 2000));

        _simulateAlphaDepositHotkey(alice, NETUID1, 100 ether, hotkey1);
        _wrap(alice, NETUID1);

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, 100 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, _subnetColdkey(NETUID1), NETUID1, 0);

        uint256 tokenId = vault.currentTokenId(NETUID1);
        vm.expectEmit(true, true, true, true);
        emit Rebalanced(tokenId, hotkey1, hotkey2, 20 ether);
        vault.rebalance(NETUID1);
    }

    function test_RebalanceSkipsMoveBelowMinStakeTaoFloor() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));

        // Bootstrap with a deposit that clears the min-stake floor, then overwrite balances
        // to a 1-RAO imbalance below the rebalance threshold.
        _simulateAlphaDepositHotkey(alice, NETUID1, 4e6, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, cloneColdkey, NETUID1, 500_001);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, cloneColdkey, NETUID1, 500_000);

        vm.recordLogs();
        vault.rebalance(NETUID1);
        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0);

        // No move took place — balances unchanged.
        assertEq(_getVaultStake(hotkey1, NETUID1), 500_001);
        assertEq(_getVaultStake(hotkey2, NETUID1), 500_000);
    }

    function test_RebalanceMovesAtOrAboveMinStakeTaoFloor() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));

        // Override balances to total 8e6 / 0 with target 4e6 / 4e6, so the move amount of 4e6
        // clears the 2e6 default rebalance threshold.
        _simulateAlphaDepositHotkey(alice, NETUID1, 4e6, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, cloneColdkey, NETUID1, 8e6);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, cloneColdkey, NETUID1, 0);

        uint256 tokenId = vault.currentTokenId(NETUID1);
        vm.expectEmit(true, true, true, true);
        emit Rebalanced(tokenId, hotkey1, hotkey2, 4e6);
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 4e6);
        assertEq(_getVaultStake(hotkey2, NETUID1), 4e6);
    }

    function test_UnwrapEmitsRebalanced() public {
        uint256 deposit = 10 ether;
        _simulateAlphaDepositHotkey(alice, NETUID2, deposit, hotkey2);
        _wrapHotkey(alice, NETUID2, hotkey2);

        uint256 shares = vault.balanceOf(alice, TOKEN2);
        uint256 burned = deposit / 2;
        uint256 expectedMove = _weighted(burned, NETUID2_BPS_HK1);

        vm.expectEmit(true, true, true, true);
        emit Rebalanced(TOKEN2, hotkey1, hotkey2, expectedMove);

        vm.prank(alice);
        vault.unwrap(TOKEN2, shares / 2, _toSubstrate(alice));
    }

    function test_UnwrapEmitsNoRebalancedWhenFullyDrained() public {
        // Single-validator set: the whole position sits on one hotkey, so a full drain is a single
        // transfer with no gather and no re-split - there is nothing to rebalance.
        _registerSubnet(99, hotkey4);
        _simulateAlphaDepositHotkey(alice, 99, 10 ether, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);
        uint256 tokenId = vault.currentTokenId(99);

        uint256 shares = vault.balanceOf(alice, tokenId);
        vm.recordLogs();
        vm.prank(alice);
        vault.unwrap(tokenId, shares, _toSubstrate(alice));
        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0);
    }

    // ────────────────── validatorRegistry (immutable) ────────────────────

    function test_ValidatorRegistry_SetAtConstruction() public view {
        assertEq(address(vault.validatorRegistry()), address(registry));
    }

    // ────────────────── setURI ───────────────────────────────────────────

    function test_SetURI() public {
        vault.setURI("https://new-uri.io/{id}.json");
        assertEq(vault.uri(0), "https://new-uri.io/{id}.json");
    }

    function test_SetURIOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setURI("https://malicious.io/{id}.json");
    }

    function test_RevertWhen_MailboxInitializeForeignWrapper() public {
        address clone = Clones.clone(address(mailboxLogic));
        vm.expectRevert(CloneBase.UnauthorizedInitializer.selector);
        CloneBase(payable(clone)).initialize(address(0xbeef));
    }

    function test_RevertWhen_RegistryWhenNoValidatorsSet() public {
        address[] memory s = new address[](2);
        s[0] = vm.addr(SIGNER_PK_1);
        s[1] = vm.addr(SIGNER_PK_2);
        AlphaVault freshVault = _deployVault(address(new ValidatorRegistry(address(this), s, 2)));

        vm.expectRevert(AlphaVault.NoValidatorFound.selector);
        freshVault.getBestValidators(NETUID1);
    }

    // ────────────────── Validator count boundaries ───────────────────────────

    function test_TotalStakeMatchesDepositAcrossValidatorSetSizes() public {
        _setValidators(91, _hotkeys(hotkey4), _weights(10_000));
        _setRegBlock(91, 91);
        _simulateAlphaDepositHotkey(alice, 91, 30 ether, hotkey4);
        _wrap(alice, 91);
        assertEq(vault.totalStake(vault.currentTokenId(91)), 30 ether);
        assertEq(_getVaultStake(hotkey4, 91), 30 ether);

        _simulateAlphaDeposit(alice, NETUID2, 100 ether);
        _wrap(alice, NETUID2);
        assertEq(vault.totalStake(vault.currentTokenId(NETUID2)), 100 ether);

        _simulateAlphaDeposit(alice, NETUID1, 90 ether);
        _wrap(alice, NETUID1);
        assertEq(vault.totalStake(vault.currentTokenId(NETUID1)), 90 ether);
        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1), 90 ether);
    }

    // ────────────────── _resolveValidators sentinel ──────────────────────────

    /// @dev `weights[0] == 0` is the "subnet not configured" sentinel. `_resolveValidators`
    ///      must revert `NoValidatorFound` whether the registry returns all-zeros or just
    ///      slot-0-zero with non-zero entries elsewhere. The corrupt-but-not-honest case
    ///      cannot be produced by the real registry, so this test deploys a fresh vault
    ///      against the mock.
    function test_RevertWhen_ResolveValidatorsWhenWeightZero() public {
        MockValidatorRegistry mock = new MockValidatorRegistry();
        AlphaVault mockVault = _deployVault(address(mock));

        _setRegBlock(91, 91);
        vm.expectRevert(AlphaVault.NoValidatorFound.selector);
        mockVault.getBestValidators(91);

        bytes32[3] memory corruptHks;
        uint16[3] memory corruptWts;
        corruptHks[1] = hotkey1;
        corruptHks[2] = hotkey2;
        corruptWts[1] = 5_000;
        corruptWts[2] = 5_000;
        mock.setRaw(92, corruptHks, corruptWts);
        _setRegBlock(92, 92);
        vm.expectRevert(AlphaVault.NoValidatorFound.selector);
        mockVault.getBestValidators(92);
    }

    // ────────────────── getBestValidators raw registry resolution ─────────────

    function test_GetBestValidatorsSurfacesCorruptRegistryRawState() public {
        MockValidatorRegistry mock = new MockValidatorRegistry();
        AlphaVault mockVault = _deployVault(address(mock));

        bytes32[3] memory hks;
        uint16[3] memory wts;
        hks[0] = hotkey4;
        wts[0] = 5_000;
        wts[1] = 5_000;
        mock.setRaw(91, hks, wts);
        _setRegBlock(91, 91);

        // _resolveValidators tolerates the corrupt mid-array entry (slot 0 is non-zero,
        // so the "configured" sentinel passes); getBestValidators surfaces the raw state.
        bytes32[3] memory result = mockVault.getBestValidators(91);
        assertEq(result[0], hotkey4);
        assertEq(result[1], bytes32(0));
        assertEq(result[2], bytes32(0));
    }

    // ------------------ Deposit/Unwrap verify state changes ---------

    function test_UnwrapDecreasesTotalStake() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        bytes32 aliceSub = _toSubstrate(alice);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceSub);
        assertEq(vault.totalStake(TOKEN1), 0);
    }

    function test_SubnetCloneCanMoveStake() public {
        vault.createSubnetProxy(NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        address clone = vault.subnetClone(tokenId);
        _setVaultStake(hotkey1, NETUID1, 100 ether);

        vm.prank(address(vault));
        SubnetClone(payable(clone)).moveStake(hotkey1, hotkey2, NETUID1, 100 ether);

        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(_getVaultStake(hotkey2, NETUID1), 100 ether);
    }

    function test_SubnetCloneCanUnwrapTao() public {
        vault.createSubnetProxy(NETUID1);
        address clone = vault.subnetClone(vault.currentTokenId(NETUID1));
        vm.deal(clone, 50 ether);

        uint256 aliceBefore = alice.balance;
        vm.prank(address(vault));
        SubnetClone(payable(clone)).unwrapTao(payable(alice), 50 ether);

        assertEq(address(clone).balance, 0);
        assertEq(alice.balance, aliceBefore + 50 ether);
    }

    function test_OnlyWrapperCanCallMoveStake() public {
        vault.createSubnetProxy(NETUID1);
        address clone = vault.subnetClone(vault.currentTokenId(NETUID1));
        vm.prank(alice);
        vm.expectRevert(CloneBase.NotWrapper.selector);
        SubnetClone(payable(clone)).moveStake(hotkey1, hotkey2, NETUID1, 100 ether);
    }

    function test_OnlyWrapperCanCallUnwrapTao() public {
        vault.createSubnetProxy(NETUID1);
        address clone = vault.subnetClone(vault.currentTokenId(NETUID1));
        vm.deal(clone, 50 ether);
        vm.prank(alice);
        vm.expectRevert(CloneBase.NotWrapper.selector);
        SubnetClone(payable(clone)).unwrapTao(payable(alice), 50 ether);
    }

    function test_ReclaimTaoFromMailboxSkipsDeployForNonExistentMailbox() public {
        address predicted = vault.getDepositAddress(alice, NETUID1);
        assertEq(predicted.code.length, 0);

        // Should revert early without deploying the mailbox
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.reclaimTaoFromMailbox(NETUID1);
        uint256 gasUsed = gasBefore - gasleft();

        // If the clone was deployed inside the reverted call, gas is wasted.
        // A clean early-return should cost under 30k gas. Clone deployment costs ~80k+.
        assertLt(gasUsed, 50_000, "too much gas - mailbox clone deployed unnecessarily before revert");
    }

    function test_ImplementationMailboxRejectsInitialize() public {
        vm.expectRevert(CloneBase.AlreadyInitialized.selector);
        mailboxLogic.initialize(address(this));
    }

    function test_ImplementationSubnetCloneRejectsInitialize() public {
        vm.expectRevert(CloneBase.AlreadyInitialized.selector);
        subnetLogic.initialize(address(this));
    }

    function test_UserCanRetrieveTaoFromMailboxAfterDeregistration() public {
        address userClone = vault.getDepositAddress(alice, NETUID1);

        // Alice sends alpha to her mailbox clone (not yet processed)
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _toSubstrate(userClone), NETUID1, 10 ether);

        // Subnet deregisters — alpha at the mailbox clone converts to TAO
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _toSubstrate(userClone), NETUID1, 0);
        vm.deal(userClone, 10 ether);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.reclaimTaoFromMailbox(NETUID1);

        assertEq(alice.balance, aliceBefore + 10 ether);
        assertEq(userClone.balance, 0);
    }

    function test_ReclaimAlphaFromMailbox() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 ether, hotkey4);
        bytes32 aliceSub = _toSubstrate(alice);

        vm.prank(alice);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey4, aliceSub);

        address mailbox = vault.getDepositAddress(alice, NETUID1);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey4, _toSubstrate(mailbox), NETUID1), 0);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey4, aliceSub, NETUID1), 10 ether);
    }

    function test_RevertWhen_ReclaimAlphaFromMailboxZeroHotkey() public {
        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroHotkey.selector);
        vault.reclaimAlphaFromMailbox(NETUID1, bytes32(0), aliceSub);
    }

    function test_RevertWhen_ReclaimAlphaFromMailboxNoStake() public {
        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey4, aliceSub);
    }

    function test_RevertWhen_ReclaimAlphaFromMailboxZeroColdkey() public {
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroColdkey.selector);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey4, bytes32(0));
    }

    function test_ReclaimAlphaFromMailboxAcceptsInSetHotkey() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 ether, hotkey1);
        bytes32 aliceSub = _toSubstrate(alice);

        vm.prank(alice);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey1, aliceSub);

        address mailbox = vault.getDepositAddress(alice, NETUID1);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, _toSubstrate(mailbox), NETUID1), 0);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, aliceSub, NETUID1), 10 ether);
    }

    function test_ReclaimAlphaCleansStrandedHotkeyAlongsideValidDeposit() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 ether, hotkey1);
        _simulateAlphaDepositHotkey(alice, NETUID1, 5 ether, hotkey4);

        _wrapHotkey(alice, NETUID1, hotkey1);
        assertEq(vault.totalStake(TOKEN1), 10 ether);

        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey4, aliceSub);

        address mailbox = vault.getDepositAddress(alice, NETUID1);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey4, _toSubstrate(mailbox), NETUID1), 0);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey4, aliceSub, NETUID1), 5 ether);
    }

    function test_ReclaimAlphaFromMailboxRecoversAfterSetRotation() public {
        _setNetuid1Set(hotkey1, hotkey2, hotkey4);
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 ether, hotkey4);

        _setNetuid1Set(hotkey1, hotkey2, hotkey3);

        vm.prank(alice);
        vm.expectRevert(AlphaVault.ChosenHotkeyNotInSet.selector);
        vault.wrap(alice, NETUID1, hotkey4);

        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey4, aliceSub);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey4, aliceSub, NETUID1), 10 ether);

        _simulateAlphaDepositHotkey(alice, NETUID1, 10 ether, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);
        assertEq(vault.totalStake(TOKEN1), 10 ether);
    }

    // ───────── currentTokenId ────────────────────────────────────────────────

    function test_CurrentTokenIdReflectsRegBlock() public view {
        uint256 expected1 = uint256(uint16(NETUID1)) | (uint256(100) << 16);
        uint256 expected2 = uint256(uint16(NETUID2)) | (uint256(200) << 16);
        assertEq(vault.currentTokenId(NETUID1), expected1);
        assertEq(vault.currentTokenId(NETUID2), expected2);
    }

    function test_RevertWhen_CurrentTokenIdForUnregisteredNetuid() public {
        vm.expectRevert(AlphaVault.SubnetNotRegistered.selector);
        vault.currentTokenId(42);
    }

    function test_RevertWhen_NetuidOutOfRangeAllEntrypoints() public {
        uint256 oob = uint256(type(uint16).max) + 1;

        vm.expectRevert(AlphaVault.NetuidOutOfRange.selector);
        vault.currentTokenId(oob);

        vm.expectRevert(AlphaVault.NetuidOutOfRange.selector);
        vault.getDepositAddress(alice, oob);

        vm.expectRevert(AlphaVault.NetuidOutOfRange.selector);
        vault.getBestValidators(oob);
    }

    function test_CurrentTokenIdChangesAfterRecycle() public {
        uint256 before = vault.currentTokenId(NETUID1);
        _setRegBlock(NETUID1, 500);
        uint256 afterRecycle = vault.currentTokenId(NETUID1);
        assertTrue(before != afterRecycle);
        assertEq(afterRecycle, uint256(uint16(NETUID1)) | (uint256(500) << 16));
    }

    // ───────── createSubnetProxy ─────────────────────────────────────────────

    function test_RevertWhen_CreateSubnetProxySubnetNotRegistered() public {
        vm.expectRevert(AlphaVault.SubnetNotRegistered.selector);
        vault.createSubnetProxy(42);
    }

    function test_CreateSubnetProxyDeploysClone() public {
        uint256 tokenId = vault.currentTokenId(NETUID1);
        assertEq(vault.subnetClone(tokenId), address(0));

        vm.expectEmit(true, false, false, false);
        emit SubnetProxyCreated(tokenId, address(0));
        vault.createSubnetProxy(NETUID1);

        assertTrue(vault.subnetClone(tokenId) != address(0));
    }

    function test_CreateSubnetProxyNoopForExistingClone() public {
        vault.createSubnetProxy(NETUID1);
        address first = vault.subnetClone(vault.currentTokenId(NETUID1));
        vault.createSubnetProxy(NETUID1);
        assertEq(vault.subnetClone(vault.currentTokenId(NETUID1)), first);
    }

    function test_CreateSubnetProxyDeploysNewCloneAfterRecycle() public {
        vault.createSubnetProxy(NETUID1);
        uint256 oldTokenId = vault.currentTokenId(NETUID1);

        _setRegBlock(NETUID1, 500);
        uint256 newTokenId = vault.currentTokenId(NETUID1);
        vault.createSubnetProxy(NETUID1);

        address oldClone = vault.subnetClone(oldTokenId);
        address newClone = vault.subnetClone(newTokenId);
        assertTrue(oldClone != address(0));
        assertTrue(newClone != address(0));
        assertTrue(oldClone != newClone);
    }

    // ───────── wrap ────────────────────────────────────────────────

    function test_WrapAutoDeploysClone() public {
        uint256 tokenId = vault.currentTokenId(NETUID1);
        assertEq(vault.subnetClone(tokenId), address(0));

        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        assertTrue(vault.subnetClone(tokenId) != address(0));
        assertTrue(vault.balanceOf(alice, tokenId) > 0);
        assertEq(vault.totalStake(tokenId), 10 ether);
    }

    function test_WrapTwoUsersProportionalShares() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        _simulateAlphaDeposit(bob, NETUID1, 30 ether);
        _wrap(bob, NETUID1);

        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 aliceShares = vault.balanceOf(alice, tokenId);
        uint256 bobShares = vault.balanceOf(bob, tokenId);
        assertApproxEqRel(bobShares, aliceShares * 3, 0.01e18);
    }

    function test_RevertWhen_WrapSubnetNotRegistered() public {
        vm.prank(alice);
        vm.expectRevert(AlphaVault.SubnetNotRegistered.selector);
        vault.wrap(alice, 42, hotkey1);
    }

    function test_WrapAfterRecycleDeploysNewCloneAndIsolatesOldShares() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 oldTokenId = vault.currentTokenId(NETUID1);

        _setRegBlock(NETUID1, 500);

        _simulateAlphaDeposit(bob, NETUID1, 5 ether);
        _wrap(bob, NETUID1);
        uint256 newTokenId = vault.currentTokenId(NETUID1);

        assertTrue(vault.balanceOf(alice, oldTokenId) > 0);
        assertEq(vault.balanceOf(alice, newTokenId), 0);
        assertTrue(vault.balanceOf(bob, newTokenId) > 0);
        assertEq(vault.balanceOf(bob, oldTokenId), 0);
        assertTrue(vault.subnetClone(oldTokenId) != vault.subnetClone(newTokenId));
    }

    function test_RevertWhen_UnwrapInsufficientShares() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        vm.prank(alice);
        vm.expectRevert(AlphaVault.InsufficientShares.selector);
        vault.unwrap(tokenId, shares + 1, _toSubstrate(alice));
    }

    // ───────── unwrap (dissolved subnet path) ──────────────────────────────────────────

    function test_UnwrapFromDissolvedSingleHolderDrainsFullPot() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(tokenId, 0);
        _simulateTaoAwardedOnDissolution(tokenId, 50 ether);
        _simulateDissolutionCompleted(NETUID1);

        uint256 aliceBefore = alice.balance;
        vm.expectEmit(true, true, false, true, address(vault));
        emit DissolvedSubnetUnwrapped(alice, tokenId, shares, 50 ether);

        vm.prank(alice);
        vault.unwrap(tokenId, shares, _toSubstrate(alice));
        assertEq(alice.balance - aliceBefore, 50 ether);
        // Full single-holder redemption also burns every share (orthogonal to the payout amount).
        assertEq(vault.totalSupply(tokenId), 0);
    }

    function test_UnwrapFromDissolvedSubnetTwoHoldersProRata() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        _simulateAlphaDeposit(bob, NETUID1, 30 ether);
        _wrap(bob, NETUID1);

        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 aliceShares = vault.balanceOf(alice, tokenId);
        uint256 bobShares = vault.balanceOf(bob, tokenId);
        uint256 supply = aliceShares + bobShares;

        _simulateDissolutionStarted(tokenId, 0);
        _simulateTaoAwardedOnDissolution(tokenId, 80 ether);
        _simulateDissolutionCompleted(NETUID1);

        uint256 aliceExpected = (80 ether * aliceShares) / supply;
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrap(tokenId, aliceShares, _toSubstrate(alice));
        assertEq(alice.balance - aliceBefore, aliceExpected);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        vault.unwrap(tokenId, bobShares, _toSubstrate(bob));
        // bob gets the rest including dust
        assertEq(bob.balance - bobBefore, 80 ether - aliceExpected);
    }

    function test_UnwrapFromDissolvedSubnetAfterNewSubnetRegistered() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateNewNetworkRegistered(tokenId, 500, 5 ether);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrap(tokenId, shares, _toSubstrate(alice));
        assertEq(alice.balance - aliceBefore, 5 ether);
    }

    function test_RevertWhen_UnwrapDuringBlackoutRegardlessOfForceSendDust() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(tokenId, 500);
        vm.deal(vault.subnetClone(tokenId), 1);

        vm.prank(alice);
        vm.expectRevert(AlphaVault.SubnetInDissolutionBlackoutPeriod.selector);
        vault.unwrap(tokenId, shares, _toSubstrate(alice));
    }

    function test_UnwrapSucceedsAfterCleanupCompletesAfterForceSend() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(tokenId, 500);
        vm.deal(vault.subnetClone(tokenId), 1);

        _simulateTaoAwardedOnDissolution(tokenId, 5 ether);

        _simulateDissolutionCompleted(NETUID1);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrap(tokenId, shares, _toSubstrate(alice));

        assertEq(alice.balance - aliceBefore, 5 ether + 1);
    }

    function test_RevertWhen_UnwrapDuringBlackout() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(tokenId, 500);

        vm.prank(alice);
        vm.expectRevert(AlphaVault.SubnetInDissolutionBlackoutPeriod.selector);
        vault.unwrap(tokenId, shares, _toSubstrate(alice));
    }

    // ───────── previewUnwrap ───────────────────────────────────────────────

    function test_PreviewUnwrapDead() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(tokenId, 0);
        _simulateTaoAwardedOnDissolution(tokenId, 40 ether);
        _simulateDissolutionCompleted(NETUID1);

        (uint256 alpha, uint256 tao) = vault.previewUnwrap(tokenId, shares);
        assertEq(alpha, 0);
        assertEq(tao, 40 ether);
    }

    function test_RevertWhen_PreviewUnwrapDuringBlackout() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(tokenId, 500);
        _simulateTaoAwardedOnDissolution(tokenId, 40 ether);

        vm.expectRevert(AlphaVault.SubnetInDissolutionBlackoutPeriod.selector);
        vault.previewUnwrap(tokenId, shares);
    }

    function test_RevertWhen_PreviewUnwrapDuringBlackoutRegardlessOfForceSendDust() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(tokenId, 500);
        vm.deal(vault.subnetClone(tokenId), 1);

        vm.expectRevert(AlphaVault.SubnetInDissolutionBlackoutPeriod.selector);
        vault.previewUnwrap(tokenId, shares);
    }

    function test_PreviewUnwrapUnknownTokenId() public view {
        (uint256 alpha, uint256 tao) = vault.previewUnwrap(0xDEADBEEF, 1000);
        assertEq(alpha, 0);
        assertEq(tao, 0);
    }

    function test_PreviewUnwrapZeroShares() public view {
        (uint256 alpha, uint256 tao) = vault.previewUnwrap(1, 0);
        assertEq(alpha, 0);
        assertEq(tao, 0);
    }

    function test_PreviewUnwrap_AccountsForRotatedOrphan() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);

        // Concentrate the vault's alpha on hotkey3, then rotate hotkey3 out.
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, cloneColdkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, cloneColdkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, cloneColdkey, NETUID1, 30 ether);

        _setNetuid1Set(hotkey1, hotkey2, hotkey4);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 previewAlpha,) = vault.previewUnwrap(TOKEN1, shares);

        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceSub);

        uint256 actualAlpha = _userStakeAcrossHotkeys(alice, NETUID1);

        assertEq(actualAlpha, 30 ether, "unwrap reclaims orphan and pays the full deposit");
        assertEq(previewAlpha, actualAlpha, "preview must match what unwrap actually pays");
    }

    // The roller carries the whole pile through a rotated-out hotkey, so even a sub-floor orphan is
    // consolidated and delivered; previewUnwrap prices the full union, so preview matches delivery.
    function test_PreviewUnwrap_MatchesDeliveryWithSubFloorOrphan() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);

        // Drop hotkey3 one RAO below the floor, then rotate it out: an untransferable orphan.
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, cloneColdkey, NETUID1, MIN_STAKE_FLOOR - 1);

        _setNetuid1Set(hotkey1, hotkey2, hotkey4);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 previewAlpha,) = vault.previewUnwrap(TOKEN1, shares);

        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceSub);

        uint256 actualAlpha = _userStakeAcrossHotkeys(alice, NETUID1);

        assertEq(actualAlpha, previewAlpha, "preview must match delivery when only a sub-floor orphan differs");
    }

    function test_PreviewUnwrapSurvivesFullRegistryRotationWithoutRebalance() public {
        // Start with a single-validator subnet so the entire deposit lands on hotkey4 alone.
        _setValidators(NETUID1, _hotkeys(hotkey4), _weights(10_000));
        _simulateAlphaDepositHotkey(alice, NETUID1, 30 ether, hotkey4);
        _wrapHotkey(alice, NETUID1, hotkey4);

        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(3334, 3333, 3333));

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 previewAlpha,) = vault.previewUnwrap(TOKEN1, shares);

        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceSub);

        uint256 actualAlpha = _userStakeAcrossHotkeys(alice, NETUID1);

        assertEq(actualAlpha, 30 ether, "unwrap reclaims stake from the rotated-out validator");
        assertEq(previewAlpha, actualAlpha, "preview matches what unwrap pays after registry rotation");
    }

    function test_PreviewUnwrapReflectsFreshEmissions() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);

        // Simulate validator rewards accrued on hotkey1 since the last state-mutating call.
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        uint256 hk1Before = _getVaultStake(hotkey1, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, cloneColdkey, NETUID1, hk1Before + 6 ether);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 previewAlpha,) = vault.previewUnwrap(TOKEN1, shares);

        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceSub);

        uint256 actualAlpha = _userStakeAcrossHotkeys(alice, NETUID1);

        assertApproxEqAbs(actualAlpha, 36 ether, 1, "unwrap pays deposit + accrued emissions");
        assertEq(previewAlpha, actualAlpha, "preview reflects fresh on-chain balances incl. emissions");
    }

    function test_PreviewUnwrapReturnsZeroWhenVaultDrained() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);

        // Drain every hotkey the vault currently tracks (current set + rotated-out orphans).
        _setVaultStakes(NETUID1, 0, 0, 0);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 alpha, uint256 tao) = vault.previewUnwrap(TOKEN1, shares);

        assertEq(alpha, 0);
        assertEq(tao, 0);
    }

    function test_RevertWhen_SharePriceForFullyDissolvedTokenId() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);

        _simulateDissolutionStarted(tokenId, 0);
        _simulateTaoAwardedOnDissolution(tokenId, 40 ether);
        _simulateDissolutionCompleted(NETUID1);

        vm.expectRevert(AlphaVault.SubnetDissolved.selector);
        vault.sharePrice(tokenId);
    }

    function test_RevertWhen_SharePriceForReRegisteredSubnetOldTokenId() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 oldTokenId = vault.currentTokenId(NETUID1);

        _simulateNewNetworkRegistered(oldTokenId, 500, 40 ether);

        vm.expectRevert(AlphaVault.SubnetDissolved.selector);
        vault.sharePrice(oldTokenId);
    }

    function test_RevertWhen_SharePriceAndIsNotManipulableByForceSend() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        address clone = vault.subnetClone(tokenId);

        _simulateDissolutionStarted(tokenId, 0);
        _simulateTaoAwardedOnDissolution(tokenId, 40 ether);
        _simulateDissolutionCompleted(NETUID1);

        vm.expectRevert(AlphaVault.SubnetDissolved.selector);
        vault.sharePrice(tokenId);

        vm.deal(clone, clone.balance + 1_000_000 ether);
        vm.expectRevert(AlphaVault.SubnetDissolved.selector);
        vault.sharePrice(tokenId);
    }

    function test_RevertWhen_PreviewWrapForDissolvedTokenId() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);

        _simulateDissolutionStarted(tokenId, 0);
        _simulateTaoAwardedOnDissolution(tokenId, 40 ether);
        _simulateDissolutionCompleted(NETUID1);

        vm.expectRevert(AlphaVault.SubnetDissolved.selector);
        vault.previewWrap(tokenId, 10 ether);
    }

    function test_RevertWhen_PreviewWrapForReRegisteredSubnetOldTokenId() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 oldTokenId = vault.currentTokenId(NETUID1);

        _simulateNewNetworkRegistered(oldTokenId, 500, 40 ether);

        vm.expectRevert(AlphaVault.SubnetDissolved.selector);
        vault.previewWrap(oldTokenId, 10 ether);
        assertGt(vault.previewWrap(vault.currentTokenId(NETUID1), 10 ether), 0);
    }

    function test_ForceSendBeforeDissolvedUnwrapIsDonationToHolders() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);
        address clone = vault.subnetClone(tokenId);

        _simulateDissolutionStarted(tokenId, 0);
        _simulateTaoAwardedOnDissolution(tokenId, 10 ether);
        _simulateDissolutionCompleted(NETUID1);

        // attacker force-sends 5 ether before Alice redeems
        vm.deal(clone, clone.balance + 5 ether);

        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        vault.unwrap(tokenId, shares, _toSubstrate(alice));

        assertEq(alice.balance - aliceBalBefore, 15 ether, "sole holder captures legit refund + attacker's donation");
    }

    function test_ForceSendBetweenPartialDissolvedUnwrapsBenefitsLaterRedeemers() public {
        _simulateAlphaDeposit(alice, NETUID1, 6 ether);
        _wrap(alice, NETUID1);
        _simulateAlphaDeposit(bob, NETUID1, 4 ether);
        _wrap(bob, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        address clone = vault.subnetClone(tokenId);

        _simulateDissolutionStarted(tokenId, 0);
        _simulateTaoAwardedOnDissolution(tokenId, 10 ether);
        _simulateDissolutionCompleted(NETUID1);

        uint256 aliceShares = vault.balanceOf(alice, tokenId);
        uint256 bobShares = vault.balanceOf(bob, tokenId);
        uint256 supplyBefore = aliceShares + bobShares;

        uint256 aliceExpected = (10 ether * aliceShares) / supplyBefore;

        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        vault.unwrap(tokenId, aliceShares, _toSubstrate(alice));
        assertEq(alice.balance - aliceBalBefore, aliceExpected, "alice gets pro-rata of legit pot");

        // attacker donates 3 ether between withdrawals
        vm.deal(clone, clone.balance + 3 ether);

        uint256 bobBalBefore = bob.balance;
        vm.prank(bob);
        vault.unwrap(tokenId, bobShares, _toSubstrate(bob));
        uint256 bobGain = bob.balance - bobBalBefore;

        // Bob as last redeemer captures all residual including attacker's donation.
        assertEq(bobGain, (10 ether - aliceExpected) + 3 ether);
    }

    function test_RevertWhen_PreviewUnwrapBlackoutOfCurrentRegistration() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        uint16[] memory queue = new uint16[](1);
        queue[0] = uint16(NETUID1);
        MockStorageQuery(STORAGE_QUERY).setDissolvedNetworks(queue);

        vm.expectRevert(AlphaVault.SubnetInDissolutionBlackoutPeriod.selector);
        vault.previewUnwrap(tokenId, shares);
    }

    function test_RevertWhen_SharePriceBlackoutOfCurrentRegistration() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);

        uint16[] memory queue = new uint16[](1);
        queue[0] = uint16(NETUID1);
        MockStorageQuery(STORAGE_QUERY).setDissolvedNetworks(queue);

        vm.expectRevert(AlphaVault.SubnetInDissolutionBlackoutPeriod.selector);
        vault.sharePrice(tokenId);
    }

    function test_RevertWhen_PreviewWrapBlackoutOfCurrentRegistration() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);

        uint16[] memory queue = new uint16[](1);
        queue[0] = uint16(NETUID1);
        MockStorageQuery(STORAGE_QUERY).setDissolvedNetworks(queue);

        vm.expectRevert(AlphaVault.SubnetInDissolutionBlackoutPeriod.selector);
        vault.previewWrap(tokenId, 10 ether);
    }

    function test_RevertWhen_PreviewUnwrapDissolvedZeroBalance() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(tokenId, 0);
        _simulateTaoAwardedOnDissolution(tokenId, 0);
        _simulateDissolutionCompleted(NETUID1);

        vm.expectRevert(AlphaVault.SubnetDissolved.selector);
        vault.previewUnwrap(tokenId, shares);
    }

    function test_ForceSendDoesNotAffectAlphaPayout() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);
        address clone = vault.subnetClone(tokenId);

        // attacker force-sends while subnet is live; balance must not leak into payouts
        vm.deal(clone, clone.balance + 100 ether);

        (uint256 alpha, uint256 tao) = vault.previewUnwrap(tokenId, shares);
        assertEq(tao, 0);
        assertApproxEqAbs(alpha, 10 ether, 1);
    }

    // ───────── rebalance ─────────────────────────────────────────────────────

    function test_RebalanceRecycledSubnetSilentNoop() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        uint256 oldTokenId = vault.currentTokenId(NETUID1);
        address oldClone = vault.subnetClone(oldTokenId);
        uint256 oldStakeBefore = _userStakeAcrossHotkeys(oldClone, NETUID1);

        _setRegBlock(NETUID1, 500);
        uint256 newTokenId = vault.currentTokenId(NETUID1);
        assertTrue(newTokenId != oldTokenId);

        vm.recordLogs();
        vault.rebalance(NETUID1);

        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0);
        assertEq(vault.subnetClone(newTokenId), address(0));
        assertEq(vault.totalStake(newTokenId), 0);
        bytes32[3] memory seen = vault.lastSeenHotkeys(newTokenId);
        assertEq(seen[0], bytes32(0));
        assertEq(seen[1], bytes32(0));
        assertEq(seen[2], bytes32(0));

        uint256 oldStakeAfter = _userStakeAcrossHotkeys(oldClone, NETUID1);
        assertEq(oldStakeAfter, oldStakeBefore);
    }

    // ───────── Integration: full lifecycle ───────────────────────────────────

    function test_LifecycleCaseAGovernanceDissolve() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        _simulateAlphaDeposit(bob, NETUID1, 30 ether);
        _wrap(bob, NETUID1);

        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 aliceShares = vault.balanceOf(alice, tokenId);
        uint256 bobShares = vault.balanceOf(bob, tokenId);
        uint256 supply = aliceShares + bobShares;

        _simulateTaoAwardedOnDissolution(tokenId, 80 ether);
        _simulateDissolutionCompleted(NETUID1);

        uint256 aliceExpected = (80 ether * aliceShares) / supply;

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrap(tokenId, aliceShares, _toSubstrate(alice));
        assertEq(alice.balance - aliceBefore, aliceExpected);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        vault.unwrap(tokenId, bobShares, _toSubstrate(bob));
        assertEq(bob.balance - bobBefore, 80 ether - aliceExpected);

        assertEq(vault.subnetClone(tokenId).balance, 0);
        assertEq(vault.totalSupply(tokenId), 0);
    }

    function test_LifecycleCaseBPruneRecycleWithNewSubnet() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 oldTokenId = vault.currentTokenId(NETUID1);

        _simulateNewNetworkRegistered(oldTokenId, 500, 3 ether);

        _simulateAlphaDeposit(bob, NETUID1, 20 ether);
        _wrap(bob, NETUID1);
        uint256 newTokenId = vault.currentTokenId(NETUID1);

        assertTrue(oldTokenId != newTokenId);

        uint256 aliceShares = vault.balanceOf(alice, oldTokenId);
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrap(oldTokenId, aliceShares, _toSubstrate(alice));
        assertEq(alice.balance - aliceBefore, 3 ether);

        uint256 bobShares = vault.balanceOf(bob, newTokenId);
        vm.prank(bob);
        vault.unwrap(newTokenId, bobShares, _toSubstrate(bob));
        uint256 bobTotal = _userStakeAcrossHotkeys(bob, NETUID1);
        assertEq(bobTotal, 20 ether);
    }

    // ══════════════════════════════════════════════════════════════════════
    //   wrap — single-hotkey + on-deposit distribution
    // ══════════════════════════════════════════════════════════════════════

    function test_WrapChosenInSetDistributesProportionally() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 30 ether, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        assertEq(_getVaultStake(hotkey1, NETUID1), _weighted(30 ether, NETUID1_BPS_HK1));
        assertEq(_getVaultStake(hotkey2, NETUID1), _weighted(30 ether, NETUID1_BPS_HK2));
        assertEq(_getVaultStake(hotkey3, NETUID1), _weighted(30 ether, NETUID1_BPS_HK3));
        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1), 30 ether);
        assertEq(vault.totalStake(TOKEN1), 30 ether);
    }

    function test_RevertWhen_WrapChosenOutOfSet() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 30 ether, hotkey4);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ChosenHotkeyNotInSet.selector);
        vault.wrap(alice, NETUID1, hotkey4);
    }

    function test_WrapCount1ChosenIsValidatorNoMoves() public {
        _registerSubnet(99, hotkey4);

        _simulateAlphaDepositHotkey(alice, 99, 10 ether, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), 10 ether);
        assertEq(_getVaultStake(hotkey1, 99), 0);
        assertEq(_getVaultStake(hotkey2, 99), 0);
    }

    function test_RevertWhen_WrapZeroChosenHotkey() public {
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroHotkey.selector);
        vault.wrap(alice, NETUID1, bytes32(0));
    }

    function test_RevertWhen_WrapWhenDepositBelowMinStakeTaoFloor() public {
        // The chain min-stake floor is 2e6; stake one RAO under it.
        _simulateAlphaDepositHotkey(alice, NETUID1, 1_999_999, hotkey1);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.DepositTooSmall.selector);
        vault.wrap(alice, NETUID1, hotkey1);
    }

    function test_WrapAcceptsExactlyMinStakeTaoFloorCount1() public {
        _registerSubnet(99, hotkey4);

        _simulateAlphaDepositHotkey(alice, 99, 2e6, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), 2e6);
    }

    function test_RevertWhen_WrapWhenChosenHasZeroStakeEvenIfOtherHotkeyFunded() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 ether, hotkey1);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.wrap(alice, NETUID1, hotkey2);
    }

    function test_WrapDerivesMailboxColdkeyFromUserClone() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 ether, hotkey1);
        _simulateAlphaDepositHotkey(bob, NETUID1, 5 ether, hotkey1);

        address aliceClone = vault.getDepositAddress(alice, NETUID1);
        address bobClone = vault.getDepositAddress(bob, NETUID1);

        _wrapHotkey(alice, NETUID1, hotkey1);

        // Alice's mailbox drained, bob's mailbox untouched.
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, _toSubstrate(aliceClone), NETUID1), 0);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, _toSubstrate(bobClone), NETUID1), 5 ether);
        // Only alice's 10 ether ended up in the vault accounting.
        assertEq(vault.totalStake(TOKEN1), 10 ether);
    }

    function test_WrapPreservesPriorBalances() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 30 ether, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);
        uint256 hk1After1 = _getVaultStake(hotkey1, NETUID1);
        uint256 hk2After1 = _getVaultStake(hotkey2, NETUID1);
        uint256 hk3After1 = _getVaultStake(hotkey3, NETUID1);

        _simulateAlphaDepositHotkey(bob, NETUID1, 30 ether, hotkey1);
        _wrapHotkey(bob, NETUID1, hotkey1);

        // Each slot grew by the same proportional slice the first deposit added.
        assertEq(_getVaultStake(hotkey1, NETUID1), 2 * hk1After1);
        assertEq(_getVaultStake(hotkey2, NETUID1), 2 * hk2After1);
        assertEq(_getVaultStake(hotkey3, NETUID1), 2 * hk3After1);
        assertEq(vault.totalStake(TOKEN1), 60 ether);
    }

    // ══════════════════════════════════════════════════════════════════════
    //   Validator-set rotation: orphan sweep
    // ══════════════════════════════════════════════════════════════════════

    /// @dev Replace registry's NETUID1 set with [a, b, c] / equal weights.
    function _setNetuid1Set(bytes32 a, bytes32 b, bytes32 c) private {
        _setValidators(NETUID1, _hotkeys(a, b, c), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3));
    }

    function test_LastSeenSnapshot_InitializedOnFirstWrap() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);
        bytes32[3] memory lastSeen = vault.lastSeenHotkeys(TOKEN1);
        assertEq(lastSeen[0], hotkey1);
        assertEq(lastSeen[1], hotkey2);
        assertEq(lastSeen[2], hotkey3);
    }

    function test_RotationSweptOnRebalance() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);
        uint256 hk3Before = _getVaultStake(hotkey3, NETUID1);
        assertGt(hk3Before, MIN_STAKE_FLOOR);

        _setNetuid1Set(hotkey1, hotkey2, hotkey4);

        vm.recordLogs();
        vault.rebalance(NETUID1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "orphan must be drained");
        assertEq(_countRebalancedLogs(logs), 1, "silent sweep; only the post-sweep alignment logs");

        bytes32[3] memory lastSeen = vault.lastSeenHotkeys(TOKEN1);
        assertEq(lastSeen[2], hotkey4, "cleared orphan slot follows the current set");
    }

    function test_RotationSweptOnNextWrap() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);

        _setNetuid1Set(hotkey1, hotkey2, hotkey4);

        _simulateAlphaDepositHotkey(bob, NETUID1, 30 ether, hotkey1);
        _wrapHotkey(bob, NETUID1, hotkey1);

        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "orphan swept before second deposit");
        assertApproxEqAbs(vault.totalStake(TOKEN1), 60 ether, 10);
    }

    function test_RotationSweptOnUnwrap() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);

        _setNetuid1Set(hotkey1, hotkey2, hotkey4);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceSub);

        uint256 received = _userStakeAcrossHotkeys(alice, NETUID1);
        assertApproxEqAbs(received, 30 ether, 10, "user must receive full deposit incl. orphan");
        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "orphan drained as part of unwrap");
    }

    function test_RotationMultipleBacklogAllOrphansSwept() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);
        uint256 hk2Before = _getVaultStake(hotkey2, NETUID1);
        uint256 hk3Before = _getVaultStake(hotkey3, NETUID1);
        assertGt(hk2Before, MIN_STAKE_FLOOR);
        assertGt(hk3Before, MIN_STAKE_FLOOR);

        // Two rotations in a row, no rebalance in between: drop hk3 then drop hk2.
        _setNetuid1Set(hotkey1, hotkey2, hotkey4);
        _setNetuid1Set(hotkey1, hotkey4, hotkey3); // hk3 is back, hk2 dropped
        // Now the snapshot still holds the original [hk1, hk2, hk3]; current = [hk1, hk4, hk3].
        // hk2 should be orphaned. hk3 is back in set so its prior balance should NOT be swept.

        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey2, NETUID1), 0, "hk2 orphan swept");
        assertApproxEqAbs(_getVaultStake(hotkey3, NETUID1), hk3Before, 1, "hk3 stays - back in current set");
    }

    function test_RotationNoChangeIsNoOp() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);
        uint256 hk3 = _getVaultStake(hotkey3, NETUID1);

        vm.recordLogs();
        vault.rebalance(NETUID1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countRebalancedLogs(logs), 0, "no-op rebalance emits nothing");
        assertEq(_getVaultStake(hotkey3, NETUID1), hk3);
    }

    function test_UnwrapSyncsEmissions() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        _simulateEmissions(NETUID1, 5 ether);

        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceSub);

        uint256 received = _userStakeAcrossHotkeys(alice, NETUID1);
        assertApproxEqAbs(received, 35 ether, 1e9, "sole holder receives deposit + emissions");
        assertLt(_totalVaultStakeAcrossHotkeys(NETUID1), 1e9, "no meaningful alpha left after full exit");
    }

    function test_EmissionsShareEquallyAcrossHolders() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);
        _simulateAlphaDeposit(bob, NETUID1, 30 ether);
        _wrap(bob, NETUID1);

        _simulateEmissions(NETUID1, 20 ether);

        uint256 aliceShares = vault.balanceOf(alice, TOKEN1);
        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, aliceSub);

        uint256 aliceReceived = _userStakeAcrossHotkeys(alice, NETUID1);
        assertApproxEqAbs(aliceReceived, 40 ether, 1e9, "alice gets her 30 + half of 20 emissions");

        uint256 bobShares = vault.balanceOf(bob, TOKEN1);
        bytes32 bobSub = _toSubstrate(bob);
        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, bobSub);

        uint256 bobReceived = _userStakeAcrossHotkeys(bob, NETUID1);
        assertApproxEqAbs(bobReceived, 40 ether, 1e9, "bob gets his 30 + half of 20 emissions");
    }

    function test_PartialUnwrapAccountsForEmissions() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);
        uint256 aliceShares = vault.balanceOf(alice, TOKEN1);

        _simulateEmissions(NETUID1, 10 ether);

        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares / 2, aliceSub);

        uint256 aliceReceived = _userStakeAcrossHotkeys(alice, NETUID1);
        assertApproxEqAbs(aliceReceived, 20 ether, 1e9, "alice gets half of 40 = 20");

        uint256 vaultRemaining = _totalVaultStakeAcrossHotkeys(NETUID1);
        assertApproxEqAbs(vaultRemaining, 20 ether, 1e9, "remaining shares back ~20 alpha");
    }

    function test_TotalStake_ReflectsEmissionsWithoutSync() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);
        uint256 priceBefore = vault.sharePrice(TOKEN1);

        _simulateEmissions(NETUID1, 5 ether);

        assertEq(vault.totalStake(TOKEN1), _totalVaultStakeAcrossHotkeys(NETUID1), "totalStake tracks live stake");
        assertEq(vault.totalStake(TOKEN1), 35 ether, "totalStake includes the 5 ether emission");
        assertGt(vault.sharePrice(TOKEN1), priceBefore, "sharePrice rises with emissions");
    }

    function test_EmptyVault_ViewsReturnZeroNotRevert() public {
        AlphaVault fresh = _deployVault(address(registry));
        fresh.createSubnetProxy(NETUID1);
        uint256 tokenId = fresh.currentTokenId(NETUID1);

        assertEq(fresh.totalStake(tokenId), 0, "totalStake returns 0 for a vault with no stake");
        assertEq(fresh.previewWrap(tokenId, 1 ether), 1 ether * 1e9, "previewWrap returns the empty-vault initial rate");
    }

    function test_Rebalance_SingleValidatorSet() public {
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(10_000));

        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);

        _simulateEmissions(NETUID1, 4 ether);
        vault.rebalance(NETUID1);

        assertEq(vault.totalStake(TOKEN1), 34 ether, "single-validator stake stays whole and live");
    }

    function test_WrapRebalancesPreSkewedBalances() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);

        // +40 ether emission on hotkey1 leaves clone balances at [50, 10, 10] ether.
        _simulateEmissions(NETUID1, 40 ether);

        // Bob deposits 30 ether on hotkey1; flush brings clone to [80, 10, 10], total 100 ether.
        _simulateAlphaDepositHotkey(bob, NETUID1, 30 ether, hotkey1);
        _wrapHotkey(bob, NETUID1, hotkey1);

        // Anchor on the literal expected total before checking distribution.
        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1), 100 ether, "total alpha conserved across deposit + rebalance");
        assertEq(vault.totalStake(TOKEN1), 100 ether, "totalStake synced to on-chain total");

        assertEq(_getVaultStake(hotkey1, NETUID1), _weighted(100 ether, NETUID1_BPS_HK1));
        assertEq(_getVaultStake(hotkey2, NETUID1), _weighted(100 ether, NETUID1_BPS_HK2));
        assertEq(_getVaultStake(hotkey3, NETUID1), _weighted(100 ether, NETUID1_BPS_HK3));
    }

    function test_WrapAutoRebalancesTwoValidatorSet() public {
        _simulateAlphaDepositHotkey(alice, NETUID2, 100 ether, hotkey2);
        _wrapHotkey(alice, NETUID2, hotkey2);

        assertEq(_totalVaultStakeAcrossHotkeys(NETUID2), 100 ether, "total alpha conserved");
        assertEq(vault.totalStake(TOKEN2), 100 ether, "totalStake synced");
        assertEq(_getVaultStake(hotkey2, NETUID2), _weighted(100 ether, NETUID2_BPS_HK2));
        assertEq(_getVaultStake(hotkey1, NETUID2), _weighted(100 ether, NETUID2_BPS_HK1));
    }

    function testFuzz_WrapUnwrapRoundTripPreservesAlpha(uint256 d) public {
        // Lower: MIN_STAKE_FLOOR (below this the deposit reverts and the property is moot).
        // Upper: u64 max (on-chain AlphaBalance ceiling; the mailbox holds a single u64 stake entry).
        d = bound(d, MIN_STAKE_FLOOR, type(uint64).max);

        _simulateAlphaDeposit(alice, NETUID1, d);
        _wrap(alice, NETUID1);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        bytes32 aliceSub = _toSubstrate(alice);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceSub);

        uint256 received = _userStakeAcrossHotkeys(alice, NETUID1);

        assertEq(received, d, "round-trip preserves alpha exactly");
    }

    function testFuzz_RebalanceIdempotent(uint256 b1, uint256 b2, uint256 b3) public {
        // Bound to u64 max: the staking precompile returns AlphaBalance (u64) on chain, so
        // per-hotkey balances above ~1.84e19 RAO are impossible. 0 lower bound covers the
        // empty-slot edge case.
        b1 = bound(b1, 0, type(uint64).max);
        b2 = bound(b2, 0, type(uint64).max);
        b3 = bound(b3, 0, type(uint64).max);

        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);

        _setVaultStakes(NETUID1, b1, b2, b3);

        vault.rebalance(NETUID1);
        uint256 b1After = _getVaultStake(hotkey1, NETUID1);
        uint256 b2After = _getVaultStake(hotkey2, NETUID1);
        uint256 b3After = _getVaultStake(hotkey3, NETUID1);

        vm.recordLogs();
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), b1After, "hotkey1 unchanged on second rebalance");
        assertEq(_getVaultStake(hotkey2, NETUID1), b2After, "hotkey2 unchanged on second rebalance");
        assertEq(_getVaultStake(hotkey3, NETUID1), b3After, "hotkey3 unchanged on second rebalance");
        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0, "no Rebalanced events on second call");
    }

    function testFuzz_UnwrapConservesAlpha(uint256 b1, uint256 b2, uint256 b3, uint256 burnPct) public {
        uint256 minAmt = MIN_STAKE_FLOOR;
        // Each component bounded so the aggregated deposit b1+b2+b3 stays within the u64 ceiling
        // of a single on-chain stake entry. Lower: MIN_STAKE_FLOOR (else deposit reverts).
        uint256 perHotkeyMax = type(uint64).max / 3;
        b1 = bound(b1, minAmt, perHotkeyMax);
        b2 = bound(b2, minAmt, perHotkeyMax);
        b3 = bound(b3, minAmt, perHotkeyMax);
        burnPct = bound(burnPct, 1, 99);

        uint256 d = b1 + b2 + b3;
        _simulateAlphaDepositHotkey(alice, NETUID1, d, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        _setVaultStakes(NETUID1, b1, b2, b3);

        uint256 supply = vault.totalSupply(TOKEN1);
        uint256 burnShares = vault.balanceOf(alice, TOKEN1) * burnPct / 100;
        // Mirrors _assetsFor: (shares * (stake + VIRTUAL_ASSETS)) / (supply + VIRTUAL_SHARES).
        // VIRTUAL_ASSETS = 1, VIRTUAL_SHARES = 1e9 in AlphaVault.
        uint256 expectedAssets = (burnShares * ((b1 + b2 + b3) + 1)) / (supply + 1e9);

        bytes32 aliceSub = _toSubstrate(alice);

        // At price 1 the alpha floor equals MIN_STAKE_FLOOR; a request below it has no
        // transferable slice and reverts rather than burning shares for nothing.
        if (expectedAssets < minAmt) {
            vm.prank(alice);
            vm.expectRevert(AlphaVault.WithdrawTooSmall.selector);
            vault.unwrap(TOKEN1, burnShares, aliceSub);
            return;
        }

        vm.prank(alice);
        vault.unwrap(TOKEN1, burnShares, aliceSub);

        uint256 userReceived = _userStakeAcrossHotkeys(alice, NETUID1);
        uint256 vaultAfter = _totalVaultStakeAcrossHotkeys(NETUID1);

        // Delivery is exact: the position is gathered onto one hotkey and the full pro-rata is
        // transferred in a single move (b1 >= floor seeds an above-floor gather on every hop).
        assertEq(userReceived, expectedAssets, "delivers exactly the pro-rata assets");
        assertEq(vaultAfter + userReceived, b1 + b2 + b3, "unwrap conserves total alpha");
    }

    function testFuzz_WrapLandsExactlyOnTargets(uint256 d) public {
        uint256 minAmt = MIN_STAKE_FLOOR;
        // Smallest d such that the smallest weight slice clears the min-rebalance floor:
        //   d * smallestBps / BPS_BASE >= minAmt  =>  d >= ceil(minAmt * BPS_BASE / smallestBps).
        uint16 smallestBps = NETUID1_BPS_HK3;
        uint256 minD = (minAmt * BPS_BASE + (smallestBps - 1)) / smallestBps;
        d = bound(d, minD, type(uint64).max);

        _simulateAlphaDepositHotkey(alice, NETUID1, d, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        uint256 t1 = _weighted(d, NETUID1_BPS_HK1);
        uint256 t2 = _weighted(d, NETUID1_BPS_HK2);
        uint256 t3 = d - t1 - t2;

        assertEq(_getVaultStake(hotkey1, NETUID1), t1, "hotkey1 hits weight target exactly");
        assertEq(_getVaultStake(hotkey2, NETUID1), t2, "hotkey2 hits weight target exactly");
        assertEq(_getVaultStake(hotkey3, NETUID1), t3, "hotkey3 hits weight target exactly");
        assertEq(vault.totalStake(TOKEN1), d, "totalStake synced to deposit amount");
    }

    function testFuzz_OrphanReclaimedAcrossRotation(uint256 b1, uint256 b2, uint256 b3) public {
        // Per-component cap u64max/3 keeps the consolidated total within the u64 ceiling of a single
        // on-chain stake entry. hk1 stays a current hotkey and must clear the floor so it can seed
        // the roll; the roller then carries the whole pile over the floor on every hop. b3 ranges
        // down to 0, covering sub-floor and emptied rotated-out orphans.
        uint256 perCap = type(uint64).max / 3;
        b1 = bound(b1, MIN_STAKE_FLOOR, perCap);
        b2 = bound(b2, 0, perCap);
        b3 = bound(b3, 0, perCap);

        // Seed the vault so _lastSeenHotkeys[TOKEN1] = [hotkey1, hotkey2, hotkey3].
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);

        // Overwrite chain-side balances with fuzzed values; ensure hk4 starts clean.
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, cloneColdkey, NETUID1, b1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, cloneColdkey, NETUID1, b2);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, cloneColdkey, NETUID1, b3);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, cloneColdkey, NETUID1, 0);

        // Rotate hotkey3 out, hotkey4 in. Same weights.
        _setNetuid1Set(hotkey1, hotkey2, hotkey4);

        vault.rebalance(NETUID1);

        uint256 a1 = _getVaultStake(hotkey1, NETUID1);
        uint256 a2 = _getVaultStake(hotkey2, NETUID1);
        uint256 a4 = _getVaultStake(hotkey4, NETUID1);

        // The roller consolidates any orphan, sub-floor or not: hk3 is emptied and the whole backing
        // rests on the current set, snapshot refreshed.
        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "orphan fully consolidated by the roller");
        assertEq(a1 + a2 + a4, b1 + b2 + b3, "active set holds the whole post-roll total");
        assertEq(vault.totalStake(TOKEN1), b1 + b2 + b3, "totalStake counts the consolidated union");

        bytes32[3] memory seen = vault.lastSeenHotkeys(TOKEN1);
        assertEq(seen[0], hotkey1);
        assertEq(seen[1], hotkey2);
        assertEq(seen[2], hotkey4, "snapshot refreshed to the current set");
    }

    function testFuzz_RebalanceConvergesWithinBoundToFloorFixpoint(uint256 b1, uint256 b2, uint256 b3) public {
        b1 = bound(b1, 0, type(uint64).max);
        b2 = bound(b2, 0, type(uint64).max);
        b3 = bound(b3, 0, type(uint64).max);

        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);

        _setVaultStakes(NETUID1, b1, b2, b3);

        uint256 preTotal = b1 + b2 + b3;
        uint256 minAmt = MIN_STAKE_FLOOR;

        vm.recordLogs();
        vault.rebalance(NETUID1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 a1 = _getVaultStake(hotkey1, NETUID1);
        uint256 a2 = _getVaultStake(hotkey2, NETUID1);
        uint256 a3 = _getVaultStake(hotkey3, NETUID1);

        assertEq(a1 + a2 + a3, preTotal, "rebalance conserves total alpha");
        assertEq(vault.totalStake(TOKEN1), preTotal, "totalStake synced to on-chain total");
        assertLe(_countRebalancedLogs(logs), 2, "rebalance loop bounded by N-1 iterations");

        uint256 t1 = _weighted(preTotal, NETUID1_BPS_HK1);
        uint256 t2 = _weighted(preTotal, NETUID1_BPS_HK2);
        uint256 t3 = preTotal - t1 - t2;

        uint256 maxOver;
        uint256 maxUnder;
        if (a1 > t1) {
            uint256 delta = a1 - t1;
            if (delta > maxOver) maxOver = delta;
        } else if (a1 < t1) {
            uint256 delta = t1 - a1;
            if (delta > maxUnder) maxUnder = delta;
        }
        if (a2 > t2) {
            uint256 delta = a2 - t2;
            if (delta > maxOver) maxOver = delta;
        } else if (a2 < t2) {
            uint256 delta = t2 - a2;
            if (delta > maxUnder) maxUnder = delta;
        }
        if (a3 > t3) {
            uint256 delta = a3 - t3;
            if (delta > maxOver) maxOver = delta;
        } else if (a3 < t3) {
            uint256 delta = t3 - a3;
            if (delta > maxUnder) maxUnder = delta;
        }

        uint256 minMatchable = maxOver < maxUnder ? maxOver : maxUnder;
        assertLt(minMatchable, minAmt, "rebalance reaches floor-bounded fixpoint");
    }
}
