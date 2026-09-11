// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { VaultMath } from "src/libraries/VaultMath.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import {
    InsufficientShares,
    NothingToUnwrap,
    SlippageExceeded,
    SlotMaskOutOfRange,
    WithdrawTooSmall,
    ZeroAmount
} from "src/VaultErrors.sol";
import { MockAlpha } from "./mocks/MockAlpha.sol";
import { CHAIN_MIN_STAKE, MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { ALPHA_PRECOMPILE } from "src/interfaces/IAlpha.sol";
import {
    RefundRejectingReceiver,
    RevertingReceiver,
    UnwrapForTaoReentrantReceiver
} from "./helpers/TaoRailReceivers.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract UnwrapForTaoTest is AlphaVaultTestBase {
    function _depositForAlice(uint256 amount) internal returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID1, amount);
    }

    function test_UnwrapForTao_IgnoresDisabledTransfers() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 100 * ALPHA, 0, 0);
        _setTransfersEnabled(NETUID1, false);

        vault.rebalance(NETUID1);
        assertGt(_getVaultStake(hotkey2, NETUID1), 0, "alignment still moves stake without transfers");
        uint256 before = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);
        assertEq(alice.balance - before, 50 * ALPHA, "and the TAO exit still pays");
    }

    // --- Excluding slots the pool would refuse ------------------------------------------------

    /// @dev A refused quote or sale burns every unit of gas it is given; an excluded slot gets neither.
    function test_UnwrapForTao_LeavesExcludedSlotsUntouched() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 60 * ALPHA, 1, 40 * ALPHA);
        MockAlpha(ALPHA_PRECOMPILE).setSimSwapRefused(1, true);
        MockStaking(STAKING_PRECOMPILE).setRemoveStakeRevertsFor(hotkey2, true);
        MockStaking(STAKING_PRECOMPILE).setConsumeAllGasOnFailure(true);
        uint256 burn = shares * 70 / 100;
        (uint256 assets,) = lens.previewUnwrap(TOKEN1, burn);

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, burn, 0, 1 << 1);

        assertEq(alice.balance - before, assets, "the entitlement sells from the other slots");
        assertEq(_getVaultStake(hotkey2, NETUID1), 1, "the excluded slot is never touched");
        assertEq(vault.balanceOf(alice, TOKEN1), shares - burn, "with nothing to refund");
    }

    function test_UnwrapForTao_FullExitRefundsAnExcludedSlotAsShares() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 60 * ALPHA, 0, 40 * ALPHA);

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0, 1 << 2);

        assertEq(alice.balance - before, 60 * ALPHA, "the allowed slot sells");
        assertEq(_getVaultStake(hotkey3, NETUID1), 40 * ALPHA, "the excluded slot stays");
        assertApproxEqAbs(_positionValue(alice), 40 * ALPHA, 1e9, "and its value comes back as shares");
    }

    function test_UnwrapForTao_PartialRefundKeepsCoHoldersWhole() public {
        _setRemoveStakeRate(1, 1);
        uint256 aliceShares = _depositForAlice(60 * ALPHA);
        _depositAndWrap(bob, NETUID1, 40 * ALPHA);
        _plantVaultStakes(NETUID1, 60 * ALPHA, 0, 40 * ALPHA);
        _donateToClone(vault.subnetClone(TOKEN1), 4 ether);
        uint256 bobValue = _positionValue(bob);
        uint256 bobClaim = lens.claimableTaoOf(bob, TOKEN1);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, aliceShares, 0, 1 << 0);

        assertEq(_positionValue(bob), bobValue, "the co-holder's value is unchanged");
        assertEq(lens.claimableTaoOf(bob, TOKEN1), bobClaim, "and so is the co-holder's TAO claim");
        assertApproxEqAbs(_positionValue(alice), 20 * ALPHA, 1e9, "the unsold part came back as shares");
    }

    function test_RevertWhen_EveryFundedSlotIsExcluded() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 60 * ALPHA, 0, 40 * ALPHA);

        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrapForTao(TOKEN1, shares / 2, 0, (1 << 0) | (1 << 2));
        assertEq(vault.balanceOf(alice, TOKEN1), shares, "shares intact");
        assertEq(_getVaultStake(hotkey1, NETUID1), 60 * ALPHA, "and stake intact");
    }

    function test_RevertWhen_TheMaskNamesASlotTheRecordLacks() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);

        vm.prank(alice);
        vm.expectRevert(SlotMaskOutOfRange.selector);
        vault.unwrapForTao(TOKEN1, shares / 2, 0, 1 << 3);
    }

    function test_UnwrapForTao_ZeroMaskMatchesThePlainCall() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 60 * ALPHA, 1, 40 * ALPHA);
        uint256 before = alice.balance;
        uint256 state = vm.snapshotState();
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);
        uint256 plainPayout = alice.balance - before;
        uint256 plainShares = vault.balanceOf(alice, TOKEN1);
        vm.revertToState(state);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0, 0);

        assertEq(alice.balance - before, plainPayout, "same payout");
        assertEq(vault.balanceOf(alice, TOKEN1), plainShares, "same shares");
    }

    function test_UnwrapForTao_MaskFollowsTheSlotToItsSuccessor() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(90 * ALPHA);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        uint256 successorBalance = _getVaultStake(hotkey4, NETUID1);
        uint256 othersBefore = _getVaultStake(hotkey2, NETUID1) + _getVaultStake(hotkey3, NETUID1);
        uint256 taoBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0, 1 << 0);

        assertEq(_getVaultStake(hotkey4, NETUID1), successorBalance, "the key the slot resolved to is untouched");
        uint256 othersAfter = _getVaultStake(hotkey2, NETUID1) + _getVaultStake(hotkey3, NETUID1);
        assertEq(othersBefore - othersAfter, alice.balance - taoBefore, "the whole sale came from the other slots");
    }

    function test_UnwrapForTao_MaskFollowsTheRecordOrderAtExecution() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(90 * ALPHA);
        _setValidators(
            NETUID1, _hotkeys(hotkey2, hotkey1, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey2, "the record now leads with hotkey2");
        uint256 firstSlot = _getVaultStake(hotkey2, NETUID1);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 4, 0, 1 << 0);

        assertEq(_getVaultStake(hotkey2, NETUID1), firstSlot, "bit 0 excludes whichever slot comes first now");
    }

    function testFuzz_UnwrapForTao_SellsOnlyTheAllowedSlots(uint256 mask, uint256 burnBps) public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 50 * ALPHA, 30 * ALPHA, 20 * ALPHA);
        mask = bound(mask, 0, 7);
        uint256 burn = shares * bound(burnBps, 1000, 9000) / VaultMath.BPS_BASE;
        bytes32[3] memory keys = [hotkey1, hotkey2, hotkey3];
        uint256[3] memory before;
        for (uint256 i; i < 3; ++i) {
            before[i] = _getVaultStake(keys[i], NETUID1);
        }
        uint256 taoBefore = alice.balance;

        vm.prank(alice);
        if (mask == 7) {
            vm.expectRevert(WithdrawTooSmall.selector);
            vault.unwrapForTao(TOKEN1, burn, 0, mask);
            return;
        }
        vault.unwrapForTao(TOKEN1, burn, 0, mask);

        uint256 sold;
        for (uint256 i; i < 3; ++i) {
            uint256 balance = _getVaultStake(keys[i], NETUID1);
            if ((mask >> i) & 1 == 1) assertEq(balance, before[i], "an excluded slot moved");
            sold += before[i] - balance;
        }
        assertEq(alice.balance - taoBefore, sold, "the payout is exactly what the allowed slots sold");
        assertGe(vault.balanceOf(alice, TOKEN1), shares - burn, "unsold entitlement came back as shares");
    }

    function _positionValue(address holder) internal view returns (uint256 alpha) {
        (alpha,) = lens.previewUnwrap(TOKEN1, vault.balanceOf(holder, TOKEN1));
    }

    function _refundValue(address holder, uint256 keptShares) internal view returns (uint256 alpha) {
        (alpha,) = lens.previewUnwrap(TOKEN1, vault.balanceOf(holder, TOKEN1) - keptShares);
    }

    function test_BurnAllShares_PaysFullAlphaAsTao() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);
        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), 0);
        assertEq(alice.balance - aliceBalanceBefore, 100 * ALPHA);
        assertEq(lens.totalStake(TOKEN1), 0);
    }

    function test_FullBurnAfterEmissionGrowth_DrainsSubFloorDust() public {
        uint256 supply = _depositForAlice(3_000_000);
        // Virtual rounding leaves a one-RAO gap; using exact backing is necessary for the full-drain exemption.
        _plantVaultStakes(NETUID1, 3_200_000, 0, 0);
        _setAlphaPrice(NETUID1, 0.5e18);
        _setRemoveStakeRate(0.5e18, VaultMath.ALPHA_PRICE_SCALE);
        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, supply, 1);

        assertEq(vault.balanceOf(alice, TOKEN1), 0);
        assertEq(lens.totalStake(TOKEN1), 0);
        assertGt(alice.balance, aliceBalanceBefore);
    }

    function testFuzz_FullBurn_DrainsWholePosition(uint256 growth, uint256 chainPriceE18) public {
        growth = bound(growth, 0, 1e12);
        chainPriceE18 = bound(chainPriceE18, 1e15, 100e18);
        uint256 supply = _depositForAlice(3_000_000);
        _plantVaultStakes(NETUID1, 3_000_000 + growth, 0, 0);
        _setAlphaPrice(NETUID1, chainPriceE18);
        _setRemoveStakeRate(chainPriceE18, VaultMath.ALPHA_PRICE_SCALE);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, supply, 1);

        assertEq(vault.balanceOf(alice, TOKEN1), 0);
        assertEq(lens.totalStake(TOKEN1), 0);
    }

    // This linear-price mock checks alpha accounting, not real-pool price impact on remaining holders.
    function testFuzz_UnwrapForTao_LeavesOnlyThresholdPinnedDust(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 shareBps,
        uint256 chainPriceE18
    ) public {
        a = bound(a, 0, 1e16);
        b = bound(b, 0, 1e16);
        c = bound(c, 1e10, 1e16);
        shareBps = bound(shareBps, 1, VaultMath.BPS_BASE);
        chainPriceE18 = bound(chainPriceE18, 1, 100e18);
        uint256 supply = _depositForAlice(30 * ALPHA);
        _setAlphaPrice(NETUID1, chainPriceE18);
        _setRemoveStakeRate(chainPriceE18, VaultMath.ALPHA_PRICE_SCALE);
        uint256 total = _plantVaultStakes(NETUID1, a, b, c);
        uint256 shares = (supply * shareBps) / VaultMath.BPS_BASE;
        // Exact backing prices a full-supply burn; only a smaller burn rounds through the virtual offsets.
        uint256 expected = shares == supply ? total : VaultMath.assetsFor(total, supply, shares);
        uint256 read = _alphaPriceRead(NETUID1);
        // Two rounding bounds cost at most 100 RAO each at the price cap, plus one RAO of headroom.
        uint256 unsellableTailBound = DUST_THRESHOLD + CHAIN_MIN_STAKE + 201;
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        (bool ok, bytes memory ret) =
            address(vault).call(abi.encodeWithSignature("unwrapForTao(uint256,uint256,uint256)", TOKEN1, shares, 0));

        // Up to six sells each lose less than one RAO to payout rounding.
        if (ok) {
            uint256 sold = total - lens.totalStake(TOKEN1);
            uint256 paid = alice.balance - balanceBefore;
            assertApproxEqAbs(paid, _expectedTaoFor(sold), 6, "payout is the sold spot value");
            assertLe(paid, _expectedTaoFor(expected) + 6, "payout never exceeds the request's value");
            uint256 leftover = expected - sold;
            assertTrue(
                leftover == 0 || read == 0 || (leftover * read) / VaultMath.ALPHA_PRICE_SCALE < unsellableTailBound,
                "any shortfall is threshold-pinned dust at the read"
            );
        } else {
            assertEq(bytes4(ret), WithdrawTooSmall.selector, "only the nothing-sold revert may fire");
            assertTrue(
                read == 0 || (expected * read) / VaultMath.ALPHA_PRICE_SCALE < unsellableTailBound,
                "nothing sold only when the whole request is an unsellable tail"
            );
            assertEq(lens.totalStake(TOKEN1), total, "nothing moved on revert");
        }
    }

    function test_PartialBurn_PaysProportionalTaoAcrossMultipleHotkeys() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);

        _plantVaultStakes(NETUID1, 60 * ALPHA, 40 * ALPHA, 0);

        uint256 half = shares / 2;
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, half, 0);

        assertEq(alice.balance - balanceBefore, 50 * ALPHA);
    }

    function test_DrainsAlphaUnderHotkeyRotatedOutOfCurrentValidatorSet() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);

        _setValidators(NETUID1, _hotkeys(hotkey4), _weights(VaultMath.BPS_BASE));

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 100 * ALPHA);
    }

    function test_UnwrapForTao_DedupsUnionHotkeys() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);

        _plantVaultStakes(NETUID1, 100 * ALPHA, 0, 0);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 100 * ALPHA);
    }

    function test_MinTaoOutZero_AcceptsAnyRealizedTaoAmount() public {
        _setRemoveStakeRate(1, 100);
        uint256 shares = _depositForAlice(100 * ALPHA);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);
        assertEq(alice.balance - balanceBefore, ALPHA);
    }

    function test_MinTaoOutEqualToRealizedAmount_DoesNotRevert() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);
        uint256 expected = _expectedTaoFor(100 * ALPHA);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, expected);
        assertEq(alice.balance - balanceBefore, expected);
    }

    function test_RevertWhen_SharesIsZero() public {
        _depositForAlice(100 * ALPHA);
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        vault.unwrapForTao(TOKEN1, 0, 0);
    }

    function test_RevertWhen_SharesExceedCallerBalance() public {
        uint256 shares = _depositForAlice(100 * ALPHA);
        vm.prank(alice);
        vm.expectRevert(InsufficientShares.selector);
        vault.unwrapForTao(TOKEN1, shares + 1, 0);
    }

    function test_DissolvedSubnetTaoRefund_NotDrainableViaTaoRail() public {
        uint256 shares = _depositForAlice(100 * ALPHA);
        _simulateNewNetworkRegistered(TOKEN1, 5 ether);

        vm.prank(alice);
        vm.expectRevert(NothingToUnwrap.selector);
        vault.unwrapForTao(TOKEN1, shares, 0);
    }

    // One validator avoids splitting a minimum-size deposit before probing one-share rounding.
    function test_RevertWhen_ProRataAssetsRoundsToZero() public {
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(VaultMath.BPS_BASE));
        _setRemoveStakeRate(1, 1);
        uint256 depositAmount = CHAIN_MIN_STAKE;
        _depositAndWrap(alice, NETUID1, depositAmount);
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        require(shares > 1, "test requires shares > 1 after deposit");

        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        vault.unwrapForTao(TOKEN1, 1, 0);
    }

    function test_RevertWhen_RealizedTaoBelowMinTaoOut() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);
        uint256 expected = _expectedTaoFor(100 * ALPHA);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, expected));
        vault.unwrapForTao(TOKEN1, shares, expected + 1);
    }

    function test_SucceedsWhenAlphaRailBlockedByTransferToggle() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);

        _disableAlphaTransfers();

        bytes32 dest = keccak256("dest");
        vm.prank(alice);
        vm.expectRevert();
        vault.unwrap(TOKEN1, shares, dest, 0);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);
        assertEq(alice.balance - balanceBefore, 100 * ALPHA);
    }

    function test_RevertWhen_AllSellsFail() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);
        _setRemoveStakeReverts(true);

        vm.prank(alice);
        vm.expectRevert("MockStaking: removeStake reverted");
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), shares);
    }

    function test_RevertWhen_OneFullSliceSellFails() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);
        (bytes32[] memory hotkeys,,) = registry.getValidators(NETUID1);
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
        (bytes32[] memory hotkeys,,) = registry.getValidators(NETUID1);
        _plantVaultStakes(NETUID1, 40e6, 20e6, 0);
        _setRemoveStakeRevertsFor(hotkeys[0], true);

        vm.prank(alice);
        vm.expectRevert(bytes("MockStaking: removeStake reverted"));
        vault.unwrapForTao(TOKEN1, shares / 2, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), shares, "shares intact after bubbled failure");
    }

    function test_DonationToClonePriorToCall_DoesNotInflateTaoOut() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);

        address clone = vault.subnetClone(TOKEN1);
        _donateToClone(clone, 5 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 100 * ALPHA);
        assertEq(clone.balance, 5 ether);
    }

    function test_RevertWhen_CallerReceiverRevertsOnReceive() public {
        _setRemoveStakeRate(1, 1);
        RevertingReceiver receiver = new RevertingReceiver();
        _simulateAlphaDeposit(address(receiver), NETUID1, 100 * ALPHA);
        _wrap(address(receiver), NETUID1);
        uint256 shares = vault.balanceOf(address(receiver), TOKEN1);

        vm.prank(address(receiver));
        vm.expectRevert();
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(address(receiver), TOKEN1), shares);
    }

    function test_ReentrantUnwrapForTaoIsRejectedByGuard() public {
        _setRemoveStakeRate(1, 1);
        UnwrapForTaoReentrantReceiver receiver = new UnwrapForTaoReentrantReceiver();
        _simulateAlphaDeposit(address(receiver), NETUID1, 100 * ALPHA);
        _wrap(address(receiver), NETUID1);
        uint256 shares = vault.balanceOf(address(receiver), TOKEN1);
        receiver.arm(vault, TOKEN1, shares);

        vm.prank(address(receiver));
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(receiver.reentryError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertFalse(receiver.reentrySucceeded());
        assertEq(vault.balanceOf(address(receiver), TOKEN1), 0);
    }

    function test_MultipleUsers_ProRataConsistentAcrossSequentialUnwraps() public {
        _setRemoveStakeRate(1, 1);
        uint256 aliceShares = _depositForAlice(100 * ALPHA);

        _simulateAlphaDeposit(bob, NETUID1, 100 * ALPHA);
        _wrap(bob, NETUID1);
        uint256 bobShares = vault.balanceOf(bob, TOKEN1);

        uint256 aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, aliceShares, 0);
        assertEq(alice.balance - aliceBalanceBefore, 100 * ALPHA);

        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        vault.unwrapForTao(TOKEN1, bobShares, 0);
        assertEq(bob.balance - bobBalanceBefore, 100 * ALPHA);
    }

    function test_AlphaRailUnwrapRemainsWorkingAfterTaoUnwrapByDifferentHolder() public {
        _setRemoveStakeRate(1, 1);
        uint256 aliceShares = _depositForAlice(100 * ALPHA);

        _simulateAlphaDeposit(bob, NETUID1, 100 * ALPHA);
        _wrap(bob, NETUID1);
        uint256 bobShares = vault.balanceOf(bob, TOKEN1);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, aliceShares, 0);

        bytes32 bobDest = keccak256("bobDest");
        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, bobDest, 0);

        assertEq(vault.balanceOf(bob, TOKEN1), 0);
        uint256 bobReceived = _userStakeAcrossHotkeys(bobDest, NETUID1);
        assertApproxEqAbs(bobReceived, 100 * ALPHA, 1e9);
    }

    function test_UnwrapForTao_PaysOutAccruedEmissionsAboveOriginalDeposit() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);

        _plantVaultStakes(NETUID1, 60 * ALPHA, 40 * ALPHA, 10 * ALPHA);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        // Virtual offsets and the sweep-safe leftover withhold dust from the nominal total.
        assertApproxEqAbs(alice.balance - balanceBefore, 110 * ALPHA, DUST_THRESHOLD + 2);
    }

    function test_UnwrapForTao_EmitsUnwrappedForTaoEvent() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);
        uint256 expectedTao = _expectedTaoFor(100 * ALPHA);

        vm.expectEmit(true, true, false, true, address(vault));
        emit UnwrappedForTao(alice, TOKEN1, shares, 0, 100 * ALPHA, expectedTao);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);
    }

    function test_PartialBurnAtNonUnitRatePaysScaledProportionalTao() public {
        _setRemoveStakeRate(1, 2);
        uint256 shares = _depositForAlice(100 * ALPHA);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);

        assertEq(alice.balance - balanceBefore, 25 * ALPHA);
    }

    function test_PartialBurn_LeavesUnneededHotkeysUntouched() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);

        _plantVaultStakes(NETUID1, 60 * ALPHA, 40 * ALPHA, 0);

        uint256 sharesForThirty = (shares * 30) / 100;

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, sharesForThirty, 0);

        assertEq(alice.balance - balanceBefore, 30 * ALPHA);
        assertEq(_getVaultStake(hotkey2, NETUID1), 40 * ALPHA);
        assertEq(_getVaultStake(hotkey1, NETUID1), 30 * ALPHA);
    }

    function test_SingleUser_CanUnwrapHalfViaTaoRailThenHalfViaAlphaRail() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);
        uint256 half = shares / 2;

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, half, 0);
        assertEq(alice.balance - balanceBefore, 50 * ALPHA);

        bytes32 dest = keccak256("alice-substrate");
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares - half, dest, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), 0);
        uint256 received = _userStakeAcrossHotkeys(dest, NETUID1);
        assertApproxEqAbs(received, 50 * ALPHA, 1e9);
    }

    function test_RebalanceWorksAfterPartialUnwrapForTao() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);

        vault.rebalance(NETUID1);

        assertApproxEqAbs(lens.totalStake(TOKEN1), 50 * ALPHA, 1e9);
        assertApproxEqAbs(_getVaultStake(hotkey1, NETUID1), _weighted(50 * ALPHA, NETUID1_BPS_HK1), 1e9);
        assertApproxEqAbs(_getVaultStake(hotkey2, NETUID1), _weighted(50 * ALPHA, NETUID1_BPS_HK2), 1e9);
        assertApproxEqAbs(_getVaultStake(hotkey3, NETUID1), _weighted(50 * ALPHA, NETUID1_BPS_HK3), 1e9);
    }

    function test_SubFloorFullDrain_SoldViaFullUnstakeExemption() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 * ALPHA);
        uint256 total = _plantVaultStakes(NETUID1, 1e6, 40 * ALPHA, 0);
        uint256 assets = 1e6 + 5e6;
        uint256 shares = _sharesForExactAssets(TOKEN1, assets, total);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, assets);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "sub-floor full drain sold via the exemption");
        assertEq(_getVaultStake(hotkey2, NETUID1), 40 * ALPHA - 5e6);
    }

    function test_TailOnExactValidatorBoundary_SoldAsFullDrain() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 * ALPHA);
        uint256 total = _plantVaultStakes(NETUID1, 60 * ALPHA, 40 * ALPHA, 0);
        uint256 assets = 60 * ALPHA;
        uint256 shares = _sharesForExactAssets(TOKEN1, assets, total);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, assets);

        assertEq(alice.balance - balanceBefore, assets);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(_getVaultStake(hotkey2, NETUID1), 40 * ALPHA, "later validator untouched");
    }

    function test_RevertWhen_PositionTooSmallToExit() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 * ALPHA);
        uint256 sharesBefore = vault.balanceOf(alice, TOKEN1);
        uint256 total = _plantVaultStakes(NETUID1, 40 * ALPHA, 0, 0);
        uint256 shares = _sharesForExactAssets(TOKEN1, 1e6, total);

        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), sharesBefore, "burn rolled back with the revert");
    }

    function test_SubFloorFinalSlice_RefundsSharesBackingTheUnsoldDust() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 * ALPHA);
        uint256 total = _plantVaultStakes(NETUID1, 5e6, 0, 40 * ALPHA);
        uint256 shares = _sharesForExactAssets(TOKEN1, 5e6 + 1e6, total);
        uint256 sharesBefore = vault.balanceOf(alice, TOKEN1);
        uint256 valueBefore = _positionValue(alice);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 5e6, "delivered the exempt full drain, skipped the dust");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "full drain sold");
        assertEq(_getVaultStake(hotkey3, NETUID1), 40 * ALPHA, "sub-floor remainder left in the pool");
        assertEq(lens.totalStake(TOKEN1), total - 5e6, "only the delivered alpha left the vault");
        assertApproxEqAbs(_refundValue(alice, sharesBefore - shares), 1e6, 1, "refund is worth the unsold dust");
        assertApproxEqAbs(_positionValue(alice), valueBefore - 5e6, 2, "only the sold alpha left the position");
    }

    function test_UnsoldRemainder_LeavesOtherHolderWhole() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 * ALPHA);
        _depositAndWrap(bob, NETUID1, 100 * ALPHA);
        uint256 total = _plantVaultStakes(NETUID1, 5e6, 0, 40 * ALPHA);
        uint256 shares = _sharesForExactAssets(TOKEN1, 5e6 + 1e6, total);
        uint256 bobValueBefore = _positionValue(bob);
        uint256 aliceValueBefore = _positionValue(alice);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertApproxEqAbs(_positionValue(bob), bobValueBefore, 2, "the unsold dust never reached the other holder");
        assertApproxEqAbs(_positionValue(alice), aliceValueBefore - 5e6, 2, "the caller kept every unsold RAO");
    }

    // Linear-price mock only: real TAO sales can lower the pool price for remaining holders.
    function testFuzz_UnsoldRemainder_TransfersNothingToOtherHolders(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 shareBps,
        uint256 chainPriceE18,
        uint256 sellCap
    ) public {
        a = bound(a, 0, 1e16);
        b = bound(b, 0, 1e16);
        c = bound(c, 1e10, 1e16);
        shareBps = bound(shareBps, 1, VaultMath.BPS_BASE);
        chainPriceE18 = bound(chainPriceE18, 1, 100e18);
        sellCap = bound(sellCap, 0, 1e16);
        uint256 aliceShares = _depositForAlice(30 * ALPHA);
        _depositAndWrap(bob, NETUID1, 30 * ALPHA);
        _setAlphaPrice(NETUID1, chainPriceE18);
        _setRemoveStakeRate(chainPriceE18, VaultMath.ALPHA_PRICE_SCALE);
        _plantVaultStakes(NETUID1, a, b, c);
        _setRemoveStakeCap(sellCap);
        uint256 bobValueBefore = _positionValue(bob);

        vm.prank(alice);
        (bool ok,) = address(vault)
            .call(
                abi.encodeWithSignature(
                    "unwrapForTao(uint256,uint256,uint256)", TOKEN1, (aliceShares * shareBps) / VaultMath.BPS_BASE, 0
                )
            );
        ok;

        assertApproxEqAbs(_positionValue(bob), bobValueBefore, 2, "an exit never enriches the holders who stayed");
    }

    function test_UnsoldRemainderAfterDonation_LeavesClaimableTaoIntact() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 * ALPHA);
        _depositAndWrap(bob, NETUID1, 100 * ALPHA);
        address clone = vault.subnetClone(TOKEN1);
        _donateToClone(clone, 8 ether);
        uint256 total = _plantVaultStakes(NETUID1, 5e6, 0, 40 * ALPHA);
        uint256 shares = _sharesForExactAssets(TOKEN1, 5e6 + 1e6, total);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertGe(clone.balance, vault.taoLiability(TOKEN1), "the clone still covers every recognized claim");
        uint256 claims = lens.claimableTaoOf(alice, TOKEN1) + lens.claimableTaoOf(bob, TOKEN1);
        assertApproxEqAbs(claims, 8 ether, 2e9, "the donation is still owed to the holders who earned it");
    }

    function test_RevertWhen_RefundRejectedByCallerHook() public {
        _setRemoveStakeRate(1, 1);
        RefundRejectingReceiver receiver = new RefundRejectingReceiver();
        _simulateAlphaDeposit(address(receiver), NETUID1, 100 * ALPHA);
        _wrap(address(receiver), NETUID1);
        uint256 total = _plantVaultStakes(NETUID1, 5e6, 0, 40 * ALPHA);
        uint256 shares = _sharesForExactAssets(TOKEN1, 5e6 + 1e6, total);
        uint256 sharesBefore = vault.balanceOf(address(receiver), TOKEN1);
        receiver.rejectMints();

        vm.prank(address(receiver));
        vm.expectRevert(bytes("no mints"));
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(address(receiver), TOKEN1), sharesBefore, "the whole exit rolled back");
        assertEq(lens.totalStake(TOKEN1), total, "no alpha left the vault");
    }

    function test_SwapStoppedShortOnFullBurn_RefundsTheReturnedAlpha() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 100 * ALPHA, 0, 0);
        _setRemoveStakeCap(60 * ALPHA);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 60 * ALPHA, "paid only for the alpha the chain swapped");
        assertEq(lens.totalStake(TOKEN1), 40 * ALPHA, "the chain kept the unswapped alpha staked");
        assertApproxEqAbs(_positionValue(alice), 40 * ALPHA, 2, "the caller still owns it, not the vault");
    }

    // At the empty-vault rate, appreciated unsold backing can mint more shares than the exit burned.
    function test_FullBurnShortFillAfterAppreciation_RefundsMoreThanTheBurn() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 300 * ALPHA, 0, 0);
        _setRemoveStakeCap(60 * ALPHA);

        uint256 refund = 240 * ALPHA * VaultMath.VIRTUAL_SHARES;
        uint256 balanceBefore = alice.balance;
        vm.expectEmit(true, true, false, true, address(vault));
        emit UnwrappedForTao(alice, TOKEN1, shares, refund, 60 * ALPHA, 60 * ALPHA);
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 60 * ALPHA, "paid for the alpha the chain swapped");
        assertGt(vault.balanceOf(alice, TOKEN1), shares, "the refund outnumbers the burn");
        assertApproxEqAbs(_positionValue(alice), 240 * ALPHA, 2, "the unsold alpha is still the caller's");
    }

    function testFuzz_FullBurnShortFill_RefundsWhateverStaysStaked(uint256 growth, uint256 fill) public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 * ALPHA);
        uint256 total = bound(growth, 100 * ALPHA, 1000 * ALPHA);
        _plantVaultStakes(NETUID1, total, 0, 0);
        uint256 sold = bound(fill, ALPHA, total - ALPHA);
        _setRemoveStakeCap(sold);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, sold, "paid for the alpha the chain swapped");
        uint256 refund = vault.balanceOf(alice, TOKEN1);
        assertEq(
            refund, (total - sold) * VaultMath.VIRTUAL_SHARES, "the unsold alpha is refunded at the empty-vault rate"
        );
        assertEq(vault.totalSupply(TOKEN1), refund, "the refund is the whole supply");
    }

    function test_FullBurnWithChainRoundingDust_LeavesNoPosition() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 100 * ALPHA, 0, 0);
        // Disable forced sweeping so chain-rounding residue remains staked.
        _setDustThreshold(0);
        _setRemoveStakeCap(100 * ALPHA - 1);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(lens.totalStake(TOKEN1), 1, "the chain kept a RAO back");
        assertEq(vault.balanceOf(alice, TOKEN1), 0, "sub-floor dust mints no position");
        assertEq(vault.totalSupply(TOKEN1), 0, "the position is fully retired");
    }

    function test_PartialBurnWithChainRoundingDust_RefundsTheRemainder() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 100 * ALPHA, 0, 0);
        uint256 half = shares / 2;
        _setRemoveStakeCap(50 * ALPHA - 1);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, half, 0);

        assertApproxEqAbs(_refundValue(alice, shares - half), 1, 1, "the RAO the chain kept came back");
    }

    function test_FullySoldRequest_BurnsEveryRequestedShare() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);
        uint256 half = shares / 2;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, half, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), shares - half, "a fully sold request refunds nothing");
    }

    function test_UnsoldRemainder_EmitsGrossBurnAndRefund() public {
        _setRemoveStakeRate(1, 1);
        uint256 sharesBefore = _depositForAlice(60e6);
        assertEq(sharesBefore, 60e15);
        _plantVaultStakes(NETUID1, 5e6, 0, 55e6);
        uint256 balanceBefore = alice.balance;

        // At the initial share price, the 6-million-alpha request sells 5 million;
        // the sub-minimum million comes back as a refund worth exactly one million shares.
        vm.expectEmit(true, true, false, true, address(vault));
        emit UnwrappedForTao(alice, TOKEN1, 6e15, 1e15, 5e6, 5e6);
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, 6e15, 0);

        assertEq(sharesBefore - vault.balanceOf(alice, TOKEN1), 5e15);
        assertEq(alice.balance - balanceBefore, 5e6);
    }

    function test_RevertWhen_UnsoldRemainderBreaksMinTaoOut() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 * ALPHA);
        uint256 sharesBefore = vault.balanceOf(alice, TOKEN1);
        uint256 total = _plantVaultStakes(NETUID1, 5e6, 0, 40 * ALPHA);
        uint256 shares = _sharesForExactAssets(TOKEN1, 5e6 + 1e6, total);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, 5e6));
        vault.unwrapForTao(TOKEN1, shares, 5e6 + 1e6);

        assertEq(vault.balanceOf(alice, TOKEN1), sharesBefore, "burn rolled back with the slippage revert");
    }

    function test_DustPosition_TopUpEnablesFullValueExit() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 * ALPHA);

        uint256 dustShares = _sharesForExactAssets(TOKEN1, 1e6, 100 * ALPHA);
        vm.prank(alice);
        vault.safeTransferFrom(alice, bob, TOKEN1, shares - dustShares, "");

        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrapForTao(TOKEN1, dustShares, 0);

        _depositAndWrap(alice, NETUID1, 5e6);

        uint256 allShares = vault.balanceOf(alice, TOKEN1);
        (uint256 expectedAssets,) = lens.previewUnwrap(TOKEN1, allShares);
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, allShares, expectedAssets);

        assertEq(alice.balance - balanceBefore, expectedAssets);
        assertEq(vault.balanceOf(alice, TOKEN1), 0, "entire position exited");
        assertGe(expectedAssets, 6e6 - 1, "dust value recovered in full alongside the top-up");
    }

    function test_RevertWhen_PartialSellBelowSimFloor() public {
        _setRemoveStakeRate(999, 1000);
        _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 100 * ALPHA, 0, 0);

        uint256 targetAssets = CHAIN_MIN_STAKE;
        uint256 burnShares = _sharesForExactAssets(TOKEN1, targetAssets, 100 * ALPHA);

        uint256 sharesBefore = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrapForTao(TOKEN1, burnShares, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), sharesBefore, "shares intact after the clean skip");
        assertEq(_getVaultStake(hotkey1, NETUID1), 100 * ALPHA, "the doomed sell was never attempted");
    }

    function test_PartialSell_ShrinksToLeaveSweepSafeLeftover() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 * ALPHA);
        uint256 total = _plantVaultStakes(NETUID1, 50e6, 0, 0);
        uint256 sweepSafeLeftover = DUST_THRESHOLD + 1;
        uint256 shares = _sharesForExactAssets(TOKEN1, 45e6, total);
        uint256 sharesBefore = vault.balanceOf(alice, TOKEN1);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 50e6 - sweepSafeLeftover, "paid only the sweep-safe chunk");
        assertEq(_getVaultStake(hotkey1, NETUID1), sweepSafeLeftover, "slot keeps the sweep-safe minimum");
        assertEq(lens.totalStake(TOKEN1), sweepSafeLeftover, "nothing was force-swept");
        assertApproxEqAbs(
            _refundValue(alice, sharesBefore - shares),
            45e6 - (50e6 - sweepSafeLeftover),
            1,
            "refund is the unsold rest"
        );
    }

    function test_RevertWhen_PartialSellWouldStrandSweepableDust() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 * ALPHA);
        uint256 total = _plantVaultStakes(NETUID1, 15e6, 0, 0);
        uint256 sharesBefore = vault.balanceOf(alice, TOKEN1);
        uint256 shares = _sharesForExactAssets(TOKEN1, 10e6, total);

        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), sharesBefore, "burn rolled back with the revert");
        assertEq(_getVaultStake(hotkey1, NETUID1), 15e6, "slot untouched rather than left sweepable");
    }

    function testFuzz_PartialSell_NeverLeavesSweepableRemainder(uint256 balance, uint256 assets, uint256 priceE18)
        public
    {
        priceE18 = bound(priceE18, 0.5e18, 10e18);
        balance = bound(balance, 1e6, 1e15);
        assets = bound(assets, 1, balance - 1);
        _setAlphaPrice(NETUID1, priceE18);
        _setRemoveStakeRate(priceE18, VaultMath.ALPHA_PRICE_SCALE);
        // A supply this large keeps the virtual offsets from rounding a near-full request past the
        // holder's balance for any slot in range.
        _depositForAlice(1e9 * ALPHA);
        uint256 total = _plantVaultStakes(NETUID1, balance, 0, 0);
        uint256 shares = _sharesForExactAssets(TOKEN1, assets, total);
        uint256 balanceBefore = alice.balance;
        uint256 supplyBefore = vault.balanceOf(alice, TOKEN1);

        vm.prank(alice);
        (bool ok, bytes memory reason) =
            address(vault).call(abi.encodeWithSignature("unwrapForTao(uint256,uint256,uint256)", TOKEN1, shares, 0));

        uint256 slotAfter = _getVaultStake(hotkey1, NETUID1);
        assertTrue(
            slotAfter == balance || (slotAfter * priceE18) / VaultMath.ALPHA_PRICE_SCALE >= DUST_THRESHOLD,
            "slot is untouched or keeps a sweep-safe balance"
        );
        if (ok) {
            assertLe(alice.balance - balanceBefore, _expectedTaoFor(assets) + 2, "no value beyond the request");
        } else {
            assertEq(bytes4(reason), WithdrawTooSmall.selector, "only an unsellable partial request may fail");
            assertEq(vault.balanceOf(alice, TOKEN1), supplyBefore, "refusal preserves the holder's shares");
        }
    }

    function test_ExactFitLaterSlot_PreferredOverEarlierPartial() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 * ALPHA);
        uint256 total = _plantVaultStakes(NETUID1, 25e6, 10e6, 0);
        uint256 shares = _sharesForExactAssets(TOKEN1, 10e6, total);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 10e6, "full delivery from the exact-fit slot");
        assertEq(_getVaultStake(hotkey1, NETUID1), 25e6, "earlier slot untouched");
        assertEq(_getVaultStake(hotkey2, NETUID1), 0, "exact-fit slot drained via the exemption");
    }

    function test_PartialSellBelowSpotFloor_NeverReachesSimSwap() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 * ALPHA);
        uint256 total = _plantVaultStakes(NETUID1, 40 * ALPHA, 0, 0);
        MockAlpha(ALPHA_PRECOMPILE).setSimSwapReverts(true);
        uint256 shares = _sharesForExactAssets(TOKEN1, 1e6, total);

        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrapForTao(TOKEN1, shares, 0);
    }

    function test_PartialSellWithPriceImpact_SkipsWhenLeftoverWouldSweepPostSale() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 * ALPHA);
        uint256 total = _plantVaultStakes(NETUID1, 50e6, 0, 0);
        uint256 shares = _sharesForExactAssets(TOKEN1, 25e6, total);
        // Marginal leftover quote: 44e6 - 25e6 = 19e6, below the 20e6 sweep threshold.
        MockAlpha(ALPHA_PRECOMPILE).setSimSwapQuote(50e6, 44e6);

        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(_getVaultStake(hotkey1, NETUID1), 50e6, "impact-endangered leftover left untouched");
    }

    /// @dev The chain reports stake as a 64-bit amount, so a wider slot exists only in a fixture.
    function test_RevertWhen_PartialSaleSlotExceedsSixtyFourBits() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 * ALPHA);
        uint256 oversized = uint256(type(uint64).max) + 1;
        uint256 total = _plantVaultStakes(NETUID1, oversized, 0, 0);
        uint256 shares = _sharesForExactAssets(TOKEN1, 40 * ALPHA, total);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 64, oversized));
        vault.unwrapForTao(TOKEN1, shares, 0);
    }

    receive() external payable { }
}
