// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { RevertingReceiver, WithdrawForTaoReentrantReceiver } from "./helpers/TaoRailReceivers.sol";

contract WithdrawForTaoTest is AlphaVaultTestBase {
    event WithdrawnForTao(
        address indexed user, uint256 indexed tokenId, uint256 shares, uint256 assetsBurned, uint256 taoOut
    );

    function _depositForAlice(uint256 amount) internal returns (uint256 shares) {
        _simulateAlphaDeposit(alice, NETUID1, amount);
        _processDeposit(alice, NETUID1);
        shares = vault.balanceOf(alice, TOKEN1);
    }

    function test_SingleHotkey_BurnAllShares_PaysFullAlphaAsTao() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);
        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), 0);
        assertEq(alice.balance - aliceBalanceBefore, 100 ether);
        assertEq(vault.totalStake(TOKEN1), 0);
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
        vault.withdrawForTao(TOKEN1, half, 0);

        assertEq(alice.balance - balanceBefore, 50 ether);
    }

    function test_DrainsAlphaUnderHotkeyRotatedOutOfCurrentValidatorSet() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);

        // Re-attest to a new validator without running any state-mutating vault call, so the
        // historical snapshot continues to point at the hotkeys that hold the deposit.
        _setValidators(NETUID1, _hotkeys(hotkey4), _weights(10000));

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 100 ether);
    }

    // A hotkey reachable from both candidate sources must be drained exactly once; if the
    // dedup were broken the second call against the now-empty stake would underflow and revert.
    function test_DedupsHotkeyPresentInBothCurrentSetAndLastSeenSnapshot() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);

        // Consolidate all 100 ether onto hotkey1 and zero out the rest.
        _setVaultStakes(NETUID1, 100 ether, 0, 0);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 100 ether);
    }

    function test_MinTaoOutZero_AcceptsAnyRealizedTaoAmount() public {
        _setRemoveStakeRate(1, 100);
        uint256 shares = _depositForAlice(100 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, shares, 0);
        assertEq(alice.balance - balanceBefore, 1 ether);
    }

    function test_MinTaoOutEqualToRealizedAmount() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);
        uint256 expected = _expectedTaoFor(100 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, shares, expected);
        assertEq(alice.balance - balanceBefore, expected);
    }

    function test_RevertWhen_SharesIsZero() public {
        _depositForAlice(100 ether);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.withdrawForTao(TOKEN1, 0, 0);
    }

    function test_RevertWhen_SharesExceedCallerBalance() public {
        uint256 shares = _depositForAlice(100 ether);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.InsufficientShares.selector);
        vault.withdrawForTao(TOKEN1, shares + 1, 0);
    }

    // After dissolution zeroes the alpha and credits a TAO refund to the clone, this rail must
    // not let a holder drain that refund: only the alpha-rail dissolved-position path may do so.
    function test_DissolvedSubnetTaoRefund_NotDrainableViaTaoRail() public {
        uint256 shares = _depositForAlice(100 ether);
        _simulateNewNetworkRegistered(TOKEN1, 999, 5 ether);

        vm.prank(alice);
        vm.expectRevert(AlphaVault.NothingToWithdraw.selector);
        vault.withdrawForTao(TOKEN1, shares, 0);
    }

    // Single-validator set so the minimum-stake deposit isn't split across slots, then burn
    // one share to trigger the rounding-to-zero edge inherent to the share-price cushion.
    function test_RevertWhen_ProRataAssetsRoundsToZero() public {
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(10000));
        _setRemoveStakeRate(1, 1);
        uint256 depositAmount = vault.minStakeTaoFloor();
        _simulateAlphaDeposit(alice, NETUID1, depositAmount);
        _processDeposit(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        require(shares > 1, "test requires shares > 1 after deposit");

        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.withdrawForTao(TOKEN1, 1, 0);
    }

    function test_RevertWhen_RealizedTaoBelowMinTaoOut() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);
        uint256 expected = _expectedTaoFor(100 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AlphaVault.SlippageExceeded.selector, expected));
        vault.withdrawForTao(TOKEN1, shares, expected + 1);
    }

    function test_SucceedsWhenAlphaRailBlockedByTransferToggle() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);

        _simulateTransferToggleOn();

        bytes32 dest = keccak256("dest");
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(TOKEN1, shares, dest, 0);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, shares, 0);
        assertEq(alice.balance - balanceBefore, 100 ether);
    }

    // Any failure on the underlying swap must roll back the outer call so the caller's
    // shares stay intact and they can retry later.
    function test_RemoveStakeRevertBubblesUp_PreservesCallerShares() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);
        _setRemoveStakeReverts(true);

        vm.prank(alice);
        vm.expectRevert();
        vault.withdrawForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), shares);
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
        vault.withdrawForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 100 ether);
        assertEq(clone.balance, 5 ether);
    }

    // If the caller's receive hook reverts on the TAO payment, the whole call must roll back
    // and leave shares intact.
    function test_RevertWhen_CallerReceiverRevertsOnReceive() public {
        _setRemoveStakeRate(1, 1);
        RevertingReceiver receiver = new RevertingReceiver();
        _simulateAlphaDeposit(address(receiver), NETUID1, 100 ether);
        _processDeposit(address(receiver), NETUID1);
        uint256 shares = vault.balanceOf(address(receiver), TOKEN1);

        vm.prank(address(receiver));
        vm.expectRevert();
        vault.withdrawForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(address(receiver), TOKEN1), shares);
    }

    // The reentrancy guard must stop a recipient whose receive hook tries to call back in.
    function test_RevertWhen_CallerReceiverReentersWithdrawForTao() public {
        _setRemoveStakeRate(1, 1);
        WithdrawForTaoReentrantReceiver receiver = new WithdrawForTaoReentrantReceiver();
        _simulateAlphaDeposit(address(receiver), NETUID1, 100 ether);
        _processDeposit(address(receiver), NETUID1);
        uint256 shares = vault.balanceOf(address(receiver), TOKEN1);
        receiver.arm(vault, TOKEN1, shares);

        vm.prank(address(receiver));
        vm.expectRevert();
        vault.withdrawForTao(TOKEN1, shares, 0);
    }

    function test_MultipleUsers_ProRataConsistentAcrossSequentialWithdrawals() public {
        _setRemoveStakeRate(1, 1);
        uint256 aliceShares = _depositForAlice(100 ether);

        _simulateAlphaDeposit(bob, NETUID1, 100 ether);
        _processDeposit(bob, NETUID1);
        uint256 bobShares = vault.balanceOf(bob, TOKEN1);

        uint256 aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, aliceShares, 0);
        assertEq(alice.balance - aliceBalanceBefore, 100 ether);

        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        vault.withdrawForTao(TOKEN1, bobShares, 0);
        assertEq(bob.balance - bobBalanceBefore, 100 ether);
    }

    function test_AlphaRailWithdrawRemainsWorkingAfterTaoWithdrawByDifferentHolder() public {
        _setRemoveStakeRate(1, 1);
        uint256 aliceShares = _depositForAlice(100 ether);

        _simulateAlphaDeposit(bob, NETUID1, 100 ether);
        _processDeposit(bob, NETUID1);
        uint256 bobShares = vault.balanceOf(bob, TOKEN1);

        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, aliceShares, 0);

        bytes32 bobDest = keccak256("bobDest");
        vm.prank(bob);
        vault.withdraw(TOKEN1, bobShares, bobDest, 0);

        assertEq(vault.balanceOf(bob, TOKEN1), 0);
    }

    // Validator emissions grow the clone's stake above the original deposit; the share-price
    // recalibration must capture this so the withdrawer is paid the appreciated value.
    function test_WithdrawForTao_PaysOutAccruedEmissionsAboveOriginalDeposit() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);

        _setVaultStakes(NETUID1, 60 ether, 40 ether, 10 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, shares, 0);

        // The share-price cushion trims a couple of wei off the nominal 110 ether; the
        // tolerance pins the value while accommodating that rounding.
        assertApproxEqAbs(alice.balance - balanceBefore, 110 ether, 2);
    }

    // Event payload must carry every field off-chain indexers rely on.
    function test_WithdrawForTao_EmitsWithdrawnForTaoEvent() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);
        uint256 expectedTao = _expectedTaoFor(100 ether);

        vm.expectEmit(true, true, false, true, address(vault));
        emit WithdrawnForTao(alice, TOKEN1, shares, 100 ether, expectedTao);

        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, shares, 0);
    }

    function test_WithdrawForTao_NonUnitRate_PaysExactExpectedTao() public {
        _setRemoveStakeRate(1, 2);
        uint256 shares = _depositForAlice(100 ether);
        uint256 expected = _expectedTaoFor(100 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, expected);
        assertEq(expected, 50 ether);
    }

    // Once the requested amount has been drained, later hotkeys must be left untouched.
    function test_PartialBurn_LeavesUnneededHotkeysUntouched() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);

        _setVaultStakes(NETUID1, 60 ether, 40 ether, 0);

        uint256 sharesForThirty = (shares * 30) / 100;

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, sharesForThirty, 0);

        assertEq(alice.balance - balanceBefore, 30 ether);
        assertEq(_getVaultStake(hotkey2, NETUID1), 40 ether);
        assertEq(_getVaultStake(hotkey1, NETUID1), 30 ether);
    }

    // A single user who withdraws half their shares via the TAO rail must be able to
    // withdraw the remainder via the alpha rail without share accounting errors.
    function test_SingleUser_CanWithdrawHalfViaTaoRailThenHalfViaAlphaRail() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);
        uint256 half = shares / 2;

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, half, 0);
        assertEq(alice.balance - balanceBefore, 50 ether);

        bytes32 dest = keccak256("alice-substrate");
        vm.prank(alice);
        vault.withdraw(TOKEN1, shares - half, dest, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), 0);
    }

    // After a partial TAO-rail withdrawal the on-chain stake is reduced; rebalance must
    // still be able to run on the remaining stake without reverting.
    function test_RebalanceWorksAfterPartialWithdrawForTao() public {
        _setRemoveStakeRate(1, 1);
        uint256 shares = _depositForAlice(100 ether);

        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, shares / 2, 0);

        vault.rebalance(NETUID1);
    }

    // Sub-floor tail slices: subtensor rejects partial unstakes worth less than the 2e6
    // min-stake floor but exempts full ones; the planner must never emit an illegal slice.
    // Mock price is 1e18, so alpha amounts equal their TAO value and the floor sits at 2e6
    // with the safety target at 4e6.

    function test_SubFloorTail_GrownToFloorTargetAndShavedOffEarlierSlice() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 ether);
        uint256 total = _setVaultStakes(NETUID1, 60 ether, 0, 40 ether);
        // The 1e6 tail lands on hotkey3 and is grown to the 4e6 target; hotkey1's full
        // drain is shaved by the 3e6 difference.
        uint256 assets = 60 ether + 1e6;
        uint256 shares = _sharesForExactAssets(TOKEN1, assets, total);

        vm.expectEmit(true, true, false, true, address(vault));
        emit WithdrawnForTao(alice, TOKEN1, shares, assets, assets);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, shares, assets);

        assertEq(alice.balance - balanceBefore, assets);
        assertEq(_getVaultStake(hotkey1, NETUID1), 3e6, "shave residue stays on the donor slice");
        assertEq(_getVaultStake(hotkey3, NETUID1), 40 ether - 4e6, "tail sold at the floor target");
        assertEq(vault.totalStake(TOKEN1), total - assets);
    }

    // A tail validator holding less than the 4e6 floor target cannot host a legal partial,
    // so its balance is drained in full (full unstakes are floor-exempt).
    function test_SubFloorTailOnTinyValidator_DrainedInFullViaShave() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 ether);
        uint256 total = _setVaultStakes(NETUID1, 60 ether, 3e6, 0);
        uint256 assets = 60 ether + 1e6;
        uint256 shares = _sharesForExactAssets(TOKEN1, assets, total);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, assets);
        assertEq(_getVaultStake(hotkey2, NETUID1), 0, "tiny tail validator fully vacated");
        assertEq(_getVaultStake(hotkey1, NETUID1), 2e6, "shave residue equals the boost to full");
    }

    // The donor scan must skip a slice too small to stay above the floor after the shave
    // and settle on an earlier one that can absorb it.
    function test_SubFloorTail_ShavedFromNearestEligibleDonor() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 ether);
        uint256 total = _setVaultStakes(NETUID1, 60 ether, 5e6, 40 ether);
        uint256 assets = 60 ether + 6e6;
        uint256 shares = _sharesForExactAssets(TOKEN1, assets, total);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, assets);
        assertEq(_getVaultStake(hotkey1, NETUID1), 3e6, "shave taken from the eligible earlier slice");
        assertEq(_getVaultStake(hotkey2, NETUID1), 0, "ineligible donor still drained in full");
        assertEq(_getVaultStake(hotkey3, NETUID1), 40 ether - 4e6);
    }

    // The 4e6 sizing target is 2x the floor: with a swap rate that halves the TAO output the
    // grown tail still clears subtensor's output-denominated floor check exactly.
    function test_SubFloorTail_FloorTargetHeadroomSurvivesSwapFee() public {
        _setRemoveStakeRate(1, 2);
        _depositForAlice(100 ether);
        uint256 total = _setVaultStakes(NETUID1, 60 ether, 0, 40 ether);
        uint256 assets = 60 ether + 1e6;
        uint256 shares = _sharesForExactAssets(TOKEN1, assets, total);
        uint256 expectedTao = _expectedTaoFor(assets);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, shares, expectedTao);

        assertEq(alice.balance - balanceBefore, expectedTao);
        assertEq(_getVaultStake(hotkey3, NETUID1), 40 ether - 4e6);
    }

    // An ordinary ~0.05% fee, not a crashed pool: the 2.001e6 tail clears the 2e6 spot floor (a
    // spot classifier would wrongly bubble) yet its post-fee output is a hair under the floor, so
    // only the swap-aware classifier recovers the exit.
    function test_SubFloorTail_RecoveredWhenBaseFeeOutputBelowFloor() public {
        _setRemoveStakeRate(9995, 10_000); // 0.05% fee
        _depositForAlice(100 ether);
        uint256 total = _setVaultStakes(NETUID1, 60 ether, 0, 40 ether);
        uint256 assets = 60 ether + 2_001_000;
        uint256 shares = _sharesForExactAssets(TOKEN1, assets, total);
        uint256 expectedTao = _expectedTaoFor(assets);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, shares, expectedTao);

        assertEq(alice.balance - balanceBefore, expectedTao, "full value recovered despite sub-floor output");
        assertEq(_getVaultStake(hotkey3, NETUID1), 40 ether - 4e6, "tail grown to the 4e6 floor target");
        assertEq(vault.totalStake(TOKEN1), total - assets);
    }

    // The bound spans the band where recovery must hold: the 2.001e6 tail's output dips below the
    // floor past ~0.05% fee, while its 4e6 grown size still clears the floor up to 50%. Asserts the
    // invariant (full-value delivery), not a hand-picked split.
    function testFuzz_SubFloorTail_RecoversAcrossFeeBand(uint256 feeBps) public {
        feeBps = bound(feeBps, 5, 5000); // 0.05% .. 50% combined fee+slippage
        _setRemoveStakeRate(10_000 - feeBps, 10_000);
        _depositForAlice(100 ether);
        uint256 total = _setVaultStakes(NETUID1, 60 ether, 0, 40 ether);
        uint256 assets = 60 ether + 2_001_000;
        uint256 shares = _sharesForExactAssets(TOKEN1, assets, total);
        uint256 expectedTao = _expectedTaoFor(assets);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, shares, expectedTao);

        assertEq(alice.balance - balanceBefore, expectedTao, "full value recovered, no under-delivery");
        assertEq(vault.totalStake(TOKEN1), total - assets, "exactly the burned assets left the vault");
    }

    function test_SubFloorTail_BubblesFailureWhoseOutputClearsFloor() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 ether);
        uint256 total = _setVaultStakes(NETUID1, 60 ether, 0, 40 ether);
        uint256 assets = 60 ether + 5e6;
        uint256 shares = _sharesForExactAssets(TOKEN1, assets, total);
        _setRemoveStakeReverts(true);

        vm.prank(alice);
        vm.expectRevert(bytes("MockStaking: removeStake reverted"));
        vault.withdrawForTao(TOKEN1, shares, 0);
    }

    // A full drain below the floor must be sold untouched: subtensor exempts it, and growing
    // it would only waste the exemption.
    function test_SubFloorFullDrain_SoldViaFullUnstakeExemption() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 ether);
        uint256 total = _setVaultStakes(NETUID1, 1e6, 40 ether, 0);
        uint256 assets = 1e6 + 5e6;
        uint256 shares = _sharesForExactAssets(TOKEN1, assets, total);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, assets);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "sub-floor full drain sold via the exemption");
        assertEq(_getVaultStake(hotkey2, NETUID1), 40 ether - 5e6);
    }

    // A split landing exactly on a validator boundary has no partial tail, so no floor probe
    // and no price read are needed.
    function test_TailOnExactValidatorBoundary_SoldAsFullDrain() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 ether);
        uint256 total = _setVaultStakes(NETUID1, 60 ether, 40 ether, 0);
        uint256 assets = 60 ether;
        uint256 shares = _sharesForExactAssets(TOKEN1, assets, total);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, shares, assets);

        assertEq(alice.balance - balanceBefore, assets);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(_getVaultStake(hotkey2, NETUID1), 40 ether, "later validator untouched");
    }

    // A position whose entire pro-rata value sits under the floor occupies the first slice,
    // leaving no earlier slice to shave; the withdrawal must revert rather than forfeit.
    function test_RevertWhen_PositionTooSmallToExit() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 ether);
        uint256 sharesBefore = vault.balanceOf(alice, TOKEN1);
        uint256 total = _setVaultStakes(NETUID1, 40 ether, 0, 0);
        uint256 shares = _sharesForExactAssets(TOKEN1, 1e6, total);

        vm.prank(alice);
        vm.expectRevert(AlphaVault.WithdrawTooSmall.selector);
        vault.withdrawForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), sharesBefore, "burn rolled back with the revert");
    }

    // Every candidate is too thin to absorb the shave: the withdrawal reverts and the burn
    // rolls back, leaving the caller's shares intact.
    function test_RevertWhen_NoSliceCanAbsorbFloorShave() public {
        _setRemoveStakeRate(1, 1);
        _depositForAlice(100 ether);
        uint256 sharesBefore = vault.balanceOf(alice, TOKEN1);
        uint256 total = _setVaultStakes(NETUID1, 5e6, 0, 40 ether);
        uint256 shares = _sharesForExactAssets(TOKEN1, 5e6 + 1e6, total);

        vm.prank(alice);
        vm.expectRevert(AlphaVault.WithdrawTooSmall.selector);
        vault.withdrawForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), sharesBefore, "burn rolled back with the revert");
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
        vault.withdrawForTao(TOKEN1, dustShares, 0);

        _simulateAlphaDeposit(alice, NETUID1, 5e6);
        _processDeposit(alice, NETUID1);

        uint256 allShares = vault.balanceOf(alice, TOKEN1);
        (uint256 expectedAssets,) = vault.previewWithdraw(TOKEN1, allShares);
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, allShares, expectedAssets);

        assertEq(alice.balance - balanceBefore, expectedAssets);
        assertEq(vault.balanceOf(alice, TOKEN1), 0, "entire position exited");
        assertGe(expectedAssets, 6e6 - 1, "dust value recovered in full alongside the top-up");
    }

    receive() external payable { }
}
