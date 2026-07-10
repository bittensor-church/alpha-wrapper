// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { RevertingReceiver, UnwrapForTaoReentrantReceiver } from "./helpers/TaoRailReceivers.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract UnwrapForTaoTest is AlphaVaultTestBase {
    event UnwrappedForTao(
        address indexed user, uint256 indexed tokenId, uint256 shares, uint256 assetsBurned, uint256 taoOut
    );

    function _depositForAlice(uint256 amount) internal returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID1, amount);
    }

    function test_BurnAllShares_PaysFullAlphaAsTao() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);
        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), 0);
        assertEq(alice.balance - aliceBalanceBefore, 100 ether);
        assertEq(vault.totalStake(TOKEN1), 0);
    }

    // Whatever the slot distribution, burn size, and price, the exit realizes everything except an
    // unsellable tail: the payout equals the sold alpha's spot value (the rate is coupled to the
    // price, as on the real chain where output tracks spot within the fee), and anything left
    // short of the request is either zero or sub-floor at the oracle read. A revert may fire only
    // when nothing at all was sellable. Under a rate decoupled far from spot the whole exit can
    // instead revert on the chain's output floor (test_RevertWhen_PartialSellBelowSimFloor).
    function testFuzz_UnwrapForTao_LeavesOnlySubFloorDust(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 shareBps,
        uint256 chainPriceE18
    ) public {
        a = bound(a, 0, 1e16);
        b = bound(b, 0, 1e16);
        c = bound(c, 1e10, 1e16);
        shareBps = bound(shareBps, 1, 10_000);
        chainPriceE18 = bound(chainPriceE18, 1, 100e18);
        uint256 supply = _depositForAlice(30 ether);
        _setAlphaPrice(NETUID1, chainPriceE18);
        _setRemoveStakeRate(chainPriceE18, 1e18);
        uint256 total = _setVaultStakes(NETUID1, a, b, c);
        uint256 shares = (supply * shareBps) / 10_000;
        uint256 expected = (shares * (total + 1)) / (supply + 1e9);
        uint256 read = _alphaPriceRead(NETUID1);
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        (bool ok, bytes memory ret) = address(vault).call(abi.encodeCall(vault.unwrapForTao, (TOKEN1, shares, 0)));

        // Up to six per-slot sells each floor-divide their payout, losing under one RAO apiece.
        if (ok) {
            uint256 sold = total - vault.totalStake(TOKEN1);
            assertApproxEqAbs(
                alice.balance - balanceBefore, (sold * chainPriceE18) / 1e18, 6, "payout is the sold spot value"
            );
            uint256 leftover = expected - sold;
            assertTrue(
                leftover == 0 || read == 0 || (leftover * read) / 1e18 < MIN_STAKE_FLOOR,
                "any shortfall is sub-floor dust at the read"
            );
        } else {
            assertEq(bytes4(ret), AlphaVault.WithdrawTooSmall.selector, "only the nothing-sold revert may fire");
            assertTrue(
                read == 0 || (expected * read) / 1e18 < MIN_STAKE_FLOOR + 6,
                "nothing sold only when the whole request is an unsellable tail"
            );
            assertEq(vault.totalStake(TOKEN1), total, "nothing moved on revert");
        }
    }

    // Override the stake distribution after deposit to get a clean 60/40 split between two hotkeys.
    function test_PartialBurn_PaysProportionalTaoAcrossMultipleHotkeys() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);

        // Overwrite all three hotkeys so the total sums to exactly 100 ether.
        _setVaultStakes(NETUID1, 60 ether, 40 ether, 0);

        uint256 half = shares / 2;
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, half, 0);

        assertEq(alice.balance - balanceBefore, 50 ether);
    }

    function test_DrainsAlphaUnderHotkeyRotatedOutOfCurrentValidatorSet() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);

        // Re-attest to a new validator without running any state-mutating vault call, so the
        // last-seen snapshot continues to hold the hotkeys that hold the deposit.
        _setValidators(NETUID1, _hotkeys(hotkey4), _weights(10000));

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 100 ether);
    }

    // A hotkey reachable from both candidate sources must be drained exactly once; if the
    // dedup were broken the second call against the now-empty stake would underflow and revert.
    function test_UnwrapForTao_DedupsUnionHotkeys() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);

        // Consolidate all 100 ether onto hotkey1 and zero out the rest.
        _setVaultStakes(NETUID1, 100 ether, 0, 0);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 100 ether);
    }

    function test_MinTaoOutZero_AcceptsAnyRealizedTaoAmount() public {
        _setRemoveStakeRate(1, 100);
        uint256 shares = _depositForAlice(100 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);
        assertEq(alice.balance - balanceBefore, 1 ether);
    }

    function test_MinTaoOutEqualToRealizedAmount_DoesNotRevert() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);
        uint256 expected = _expectedTaoFor(100 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, expected);
        assertEq(alice.balance - balanceBefore, expected);
    }

    function test_RevertWhen_SharesIsZero() public {
        _depositForAlice(100 ether);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.unwrapForTao(TOKEN1, 0, 0);
    }

    function test_RevertWhen_SharesExceedCallerBalance() public {
        uint256 shares = _depositForAlice(100 ether);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.InsufficientShares.selector);
        vault.unwrapForTao(TOKEN1, shares + 1, 0);
    }

    // After dissolution zeroes the alpha and credits a TAO refund to the clone, this rail must
    // not let a holder drain that refund: only the alpha-rail dissolved-position path may do so.
    function test_DissolvedSubnetTaoRefund_NotDrainableViaTaoRail() public {
        uint256 shares = _depositForAlice(100 ether);
        _simulateNewNetworkRegistered(TOKEN1, 999, 5 ether);

        vm.prank(alice);
        vm.expectRevert(AlphaVault.NothingToUnwrap.selector);
        vault.unwrapForTao(TOKEN1, shares, 0);
    }

    // Single-validator set so the minimum-stake deposit isn't split across slots, then burn
    // one share to trigger the rounding-to-zero edge inherent to the share-price cushion.
    function test_RevertWhen_ProRataAssetsRoundsToZero() public {
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(10000));
        _setRemoveStakeRate(1, 1);
        uint256 depositAmount = MIN_STAKE_FLOOR;
        _depositAndWrap(alice, NETUID1, depositAmount);
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        require(shares > 1, "test requires shares > 1 after deposit");

        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.unwrapForTao(TOKEN1, 1, 0);
    }

    function test_RevertWhen_RealizedTaoBelowMinTaoOut() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);
        uint256 expected = _expectedTaoFor(100 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AlphaVault.SlippageExceeded.selector, expected));
        vault.unwrapForTao(TOKEN1, shares, expected + 1);
    }

    function test_SucceedsWhenAlphaRailBlockedByTransferToggle() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);

        _simulateTransferToggleOn();

        bytes32 dest = keccak256("dest");
        vm.prank(alice);
        vm.expectRevert();
        vault.unwrap(TOKEN1, shares, dest);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);
        assertEq(alice.balance - balanceBefore, 100 ether);
    }

    // When every sell fails (here the swap precompile reverts), nothing is delivered, so the exit
    // reverts WithdrawTooSmall and the burn rolls back, leaving the caller's shares intact.
    function test_RevertWhen_AllSellsFail() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);
        _setRemoveStakeReverts(true);

        // A full-balance sell that fails is a real fault, so it bubbles instead of being skipped;
        // the revert rolls back the burn and the caller keeps every share.
        vm.prank(alice);
        vm.expectRevert("MockStaking: removeStake reverted");
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), shares);
    }

    // One validator's pool being illiquid (a non-floor sell failure on a full-balance slice) must
    // abort the whole exit and roll back the slices that already cleared, never silently delivering
    // a fraction of fair value and forfeiting the rest to the remaining holders.
    function test_RevertWhen_OneFullSliceSellFails() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);
        (bytes32[3] memory hotkeys,) = registry.getValidators(NETUID1);
        _setRemoveStakeRevertsFor(hotkeys[1], true);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vm.expectRevert("MockStaking: removeStake reverted");
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), shares);
        assertEq(alice.balance, balanceBefore);
    }

    function test_RevertWhen_AboveFloorPartialSellFails() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(60e6);
        (bytes32[3] memory hotkeys,) = registry.getValidators(NETUID1);
        _setVaultStakes(NETUID1, 40e6, 20e6, 0);
        _setRemoveStakeRevertsFor(hotkeys[0], true);

        // Burning half targets ~30e6: slot 0 (40e6 > 30e6) takes the partial branch, which is
        // far above the floor, so the fault must bubble instead of being skipped as dust.
        vm.prank(alice);
        vm.expectRevert(bytes("MockStaking: removeStake reverted"));
        vault.unwrapForTao(TOKEN1, shares / 2, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), shares, "shares intact after bubbled failure");
    }

    // A native TAO gift sent directly to the clone before the call must be excluded from
    // the slippage delta and remain on the clone afterwards.
    function test_DonationToClonePriorToCall_DoesNotInflateTaoOut() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);

        address clone = vault.subnetClone(TOKEN1);
        _donateToClone(clone, 5 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 100 ether);
        assertEq(clone.balance, 5 ether);
    }

    // If the caller's receive hook reverts on the TAO payment, the whole call must roll back
    // and leave shares intact.
    function test_RevertWhen_CallerReceiverRevertsOnReceive() public {
        _setRemoveStakeRate(1, 1);
        RevertingReceiver receiver = new RevertingReceiver();
        _simulateAlphaDeposit(address(receiver), NETUID1, 100 ether);
        _wrap(address(receiver), NETUID1);
        uint256 shares = vault.balanceOf(address(receiver), TOKEN1);

        vm.prank(address(receiver));
        vm.expectRevert();
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(address(receiver), TOKEN1), shares);
    }

    // The reentrancy guard must reject a recipient whose receive hook tries to call back in.
    function test_ReentrantUnwrapForTaoIsRejectedByGuard() public {
        _setRemoveStakeRate(1, 1);
        UnwrapForTaoReentrantReceiver receiver = new UnwrapForTaoReentrantReceiver();
        _simulateAlphaDeposit(address(receiver), NETUID1, 100 ether);
        _wrap(address(receiver), NETUID1);
        uint256 shares = vault.balanceOf(address(receiver), TOKEN1);
        receiver.arm(vault, TOKEN1, shares);

        vm.prank(address(receiver));
        vault.unwrapForTao(TOKEN1, shares, 0);

        // The re-entry was rejected specifically by the guard, not by some incidental revert.
        assertEq(receiver.reentryError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertFalse(receiver.reentrySucceeded());
        // The legitimate (outer) unwrap still completed: all shares were burned.
        assertEq(vault.balanceOf(address(receiver), TOKEN1), 0);
    }

    function test_MultipleUsers_ProRataConsistentAcrossSequentialUnwraps() public {
        _setRemoveStakeRate(1, 1);
        uint256 aliceShares = _depositForAlice(100 ether);

        _simulateAlphaDeposit(bob, NETUID1, 100 ether);
        _wrap(bob, NETUID1);
        uint256 bobShares = vault.balanceOf(bob, TOKEN1);

        uint256 aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, aliceShares, 0);
        assertEq(alice.balance - aliceBalanceBefore, 100 ether);

        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        vault.unwrapForTao(TOKEN1, bobShares, 0);
        assertEq(bob.balance - bobBalanceBefore, 100 ether);
    }

    function test_AlphaRailUnwrapRemainsWorkingAfterTaoUnwrapByDifferentHolder() public {
        _setRemoveStakeRate(1, 1);
        uint256 aliceShares = _depositForAlice(100 ether);

        _simulateAlphaDeposit(bob, NETUID1, 100 ether);
        _wrap(bob, NETUID1);
        uint256 bobShares = vault.balanceOf(bob, TOKEN1);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, aliceShares, 0);

        bytes32 bobDest = keccak256("bobDest");
        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, bobDest);

        assertEq(vault.balanceOf(bob, TOKEN1), 0);
        uint256 bobReceived = _userStakeAcrossHotkeys(bobDest, NETUID1);
        assertApproxEqAbs(bobReceived, 100 ether, 1e9);
    }

    // Validator emissions grow the clone's stake above the original deposit; the share-price
    // recalibration must capture this so the withdrawer is paid the appreciated value.
    function test_UnwrapForTao_PaysOutAccruedEmissionsAboveOriginalDeposit() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);

        _setVaultStakes(NETUID1, 60 ether, 40 ether, 10 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        // The share-price cushion trims a couple of wei off the nominal 110 ether; the
        // tolerance pins the value while accommodating that rounding.
        assertApproxEqAbs(alice.balance - balanceBefore, 110 ether, 2);
    }

    // Event payload must carry every field off-chain indexers rely on.
    function test_UnwrapForTao_EmitsUnwrappedForTaoEvent() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);
        uint256 expectedTao = _expectedTaoFor(100 ether);

        vm.expectEmit(true, true, false, true, address(vault));
        emit UnwrappedForTao(alice, TOKEN1, shares, 100 ether, expectedTao);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);
    }

    function test_PartialBurnAtNonUnitRatePaysScaledProportionalTao() public {
        _setRemoveStakeRate(1, 2);
        uint256 shares = _depositForAlice(100 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);

        // Half the shares realize ~50 ether of alpha; the 1/2 rate scales that to 25 ether TAO.
        assertEq(alice.balance - balanceBefore, 25 ether);
    }

    // Once the requested amount has been drained, later hotkeys must be left untouched.
    function test_PartialBurn_LeavesUnneededHotkeysUntouched() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);

        _setVaultStakes(NETUID1, 60 ether, 40 ether, 0);

        uint256 sharesForThirty = (shares * 30) / 100;

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, sharesForThirty, 0);

        assertEq(alice.balance - balanceBefore, 30 ether);
        assertEq(_getVaultStake(hotkey2, NETUID1), 40 ether);
        assertEq(_getVaultStake(hotkey1, NETUID1), 30 ether);
    }

    // A single user who unwraps half their shares via the TAO rail must be able to
    // unwrap the remainder via the alpha rail without share accounting errors.
    function test_SingleUser_CanUnwrapHalfViaTaoRailThenHalfViaAlphaRail() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);
        uint256 half = shares / 2;

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, half, 0);
        assertEq(alice.balance - balanceBefore, 50 ether);

        bytes32 dest = keccak256("alice-substrate");
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares - half, dest);

        assertEq(vault.balanceOf(alice, TOKEN1), 0);
        uint256 received = _userStakeAcrossHotkeys(dest, NETUID1);
        assertApproxEqAbs(received, 50 ether, 1e9);
    }

    // After a partial TAO-rail withdrawal the on-chain stake is reduced; rebalance must
    // still be able to run on the remaining stake without reverting.
    function test_RebalanceWorksAfterPartialUnwrapForTao() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);

        vault.rebalance(NETUID1);

        assertApproxEqAbs(vault.totalStake(TOKEN1), 50 ether, 1e9);
        assertApproxEqAbs(_getVaultStake(hotkey1, NETUID1), _weighted(50 ether, NETUID1_BPS_HK1), 1e9);
        assertApproxEqAbs(_getVaultStake(hotkey2, NETUID1), _weighted(50 ether, NETUID1_BPS_HK2), 1e9);
        assertApproxEqAbs(_getVaultStake(hotkey3, NETUID1), _weighted(50 ether, NETUID1_BPS_HK3), 1e9);
    }

    // A sub-floor full drain sells untouched: a full unstake is floor-exempt, so dust on a
    // fully-drained validator still exits.
    function test_SubFloorFullDrain_SoldViaFullUnstakeExemption() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 ether);
        uint256 total = _setVaultStakes(NETUID1, 1e6, 40 ether, 0);
        uint256 assets = 1e6 + 5e6;
        uint256 shares = _sharesForExactAssets(TOKEN1, assets, total);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, assets);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "sub-floor full drain sold via the exemption");
        assertEq(_getVaultStake(hotkey2, NETUID1), 40 ether - 5e6);
    }

    // A split landing exactly on a validator boundary needs no partial slice.
    function test_TailOnExactValidatorBoundary_SoldAsFullDrain() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 ether);
        uint256 total = _setVaultStakes(NETUID1, 60 ether, 40 ether, 0);
        uint256 assets = 60 ether;
        uint256 shares = _sharesForExactAssets(TOKEN1, assets, total);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, assets);

        assertEq(alice.balance - balanceBefore, assets);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(_getVaultStake(hotkey2, NETUID1), 40 ether, "later validator untouched");
    }

    // A position whose only sellable slice is a sub-floor partial sells nothing, so the exit
    // reverts and the burn rolls back rather than forfeiting the shares.
    function test_RevertWhen_PositionTooSmallToExit() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 ether);
        uint256 sharesBefore = vault.balanceOf(alice, TOKEN1);
        uint256 total = _setVaultStakes(NETUID1, 40 ether, 0, 0);
        uint256 shares = _sharesForExactAssets(TOKEN1, 1e6, total);

        vm.prank(alice);
        vm.expectRevert(AlphaVault.WithdrawTooSmall.selector);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), sharesBefore, "burn rolled back with the revert");
    }

    // A sub-floor final slice is skipped: the exempt full drain is delivered, the dust remainder
    // stays in the pool, and the caller is paid the reduced amount (minTaoOut is slack here).
    function test_SubFloorFinalSlice_UnderDeliversBoundedDust() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 ether);
        uint256 total = _setVaultStakes(NETUID1, 5e6, 0, 40 ether);
        // 5e6 full-drains hotkey1 (exempt); the 1e6 remainder on hotkey3 is a sub-floor partial.
        uint256 shares = _sharesForExactAssets(TOKEN1, 5e6 + 1e6, total);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 5e6, "delivered the exempt full drain, skipped the dust");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "full drain sold");
        assertEq(_getVaultStake(hotkey3, NETUID1), 40 ether, "sub-floor remainder left in the pool");
        assertEq(vault.totalStake(TOKEN1), total - 5e6, "only the delivered alpha left the vault");
    }

    // minTaoOut guards the caller against that under-delivery: demanding the full assets reverts
    // and the burn rolls back.
    function test_RevertWhen_UnderDeliveryBreaksMinTaoOut() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 ether);
        uint256 sharesBefore = vault.balanceOf(alice, TOKEN1);
        uint256 total = _setVaultStakes(NETUID1, 5e6, 0, 40 ether);
        uint256 shares = _sharesForExactAssets(TOKEN1, 5e6 + 1e6, total);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AlphaVault.SlippageExceeded.selector, 5e6));
        vault.unwrapForTao(TOKEN1, shares, 5e6 + 1e6);

        assertEq(vault.balanceOf(alice, TOKEN1), sharesBefore, "burn rolled back with the slippage revert");
    }

    // Documented escape hatch for a dust position: top up with one more deposit to lift the
    // position above the floor, then exit everything in a single withdrawal at full value.
    function test_DustPosition_TopUpEnablesFullValueExit() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);

        // Alice keeps a dust position worth 1e6 and parts with the rest of her shares.
        uint256 dustShares = _sharesForExactAssets(TOKEN1, 1e6, 100 ether);
        vm.prank(alice);
        vault.safeTransferFrom(alice, bob, TOKEN1, shares - dustShares, "");

        vm.prank(alice);
        vm.expectRevert(AlphaVault.WithdrawTooSmall.selector);
        vault.unwrapForTao(TOKEN1, dustShares, 0);

        _depositAndWrap(alice, NETUID1, 5e6);

        uint256 allShares = vault.balanceOf(alice, TOKEN1);
        (uint256 expectedAssets,) = vault.previewUnwrap(TOKEN1, allShares);
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, allShares, expectedAssets);

        assertEq(alice.balance - balanceBefore, expectedAssets);
        assertEq(vault.balanceOf(alice, TOKEN1), 0, "entire position exited");
        assertGe(expectedAssets, 6e6 - 1, "dust value recovered in full alongside the top-up");
    }

    // The spot floor and the chain's realized-output floor disagree in a narrow band: a partial
    // remainder can clear the spot floor yet be rejected once the swap fee is applied. The sell is
    // bare, so the rejection bubbles and the whole exit reverts with shares intact.
    function test_RevertWhen_PartialSellBelowSimFloor() public {
        _setRemoveStakeRate(999, 1000);
        _depositForAlice(100 ether);
        // Concentrate everything on one hotkey so the first slice is a partial sell.
        _setVaultStakes(NETUID1, 100 ether, 0, 0);

        uint256 targetAssets = MIN_STAKE_FLOOR; // clears the spot floor, but not after the sim fee
        uint256 burnShares = _sharesForExactAssets(TOKEN1, targetAssets, 100 ether);

        uint256 sharesBefore = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vm.expectRevert(bytes("MockStaking: AmountTooLow"));
        vault.unwrapForTao(TOKEN1, burnShares, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), sharesBefore, "shares intact after the bubbled sim-floor rejection");
    }

    receive() external payable { }
}
