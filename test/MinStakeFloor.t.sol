// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { ConsolidationBelowFloor, DepositTooSmall, GatherBelowFloor, WithdrawTooSmall } from "src/VaultErrors.sol";
import { CHAIN_MIN_STAKE, CHAIN_MIN_TRANSFER, MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// @dev Exercises the TAO-denominated min-stake floor: the wrap/withdraw labels, the best-effort
///      rebalance skip, exact-or-revert delivery, and that the floor follows the chain's own value.
contract MinStakeFloorTest is AlphaVaultTestBase {
    uint256 private constant PRICE_HALF = 0.5e18;

    function _setChainMinStake(uint256 minStakeTao) private {
        MockStaking(STAKING_PRECOMPILE).setChainMinStake(minStakeTao);
    }

    function test_RevertWhen_WrapDepositBelowTaoFloor() public {
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, PRICE_HALF);

        // 3e6 alpha = 1.5e6 tao, below the 2e6 floor.
        _simulateAlphaDepositHotkey(alice, 99, 3e6, hotkey4);
        vm.prank(alice);
        vm.expectRevert(DepositTooSmall.selector);
        vault.wrap(99, hotkey4);
    }

    function test_Wrap_SucceedsAtTaoFloorBoundaryUnderLowPrice() public {
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, PRICE_HALF);

        // 4e6 alpha = 2e6 tao, exactly the floor.
        _simulateAlphaDepositHotkey(alice, 99, 4e6, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), 4e6);
        assertGt(vault.balanceOf(alice, vault.currentTokenId(99)), 0);
    }

    function test_Rebalance_SkipsSubFloorMove() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, NETUID1, 8e6, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        _setAlphaPrice(NETUID1, PRICE_HALF);
        // Target is 4e6 / 4e6; the corrective move of 2e6 alpha is only 1e6 tao, below the floor.
        _setVaultStake(hotkey1, NETUID1, 6e6);
        _setVaultStake(hotkey2, NETUID1, 2e6);

        vm.recordLogs();
        vault.rebalance(NETUID1);
        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0, "sub-floor move skipped pre-call");
        assertEq(_getVaultStake(hotkey1, NETUID1), 6e6);
        assertEq(_getVaultStake(hotkey2, NETUID1), 2e6);
    }

    // The floor is the only rejection the pre-check can rule out, so anything else is exceptional
    // and must bubble; catching it could not help, because a rejected precompile call has already
    // consumed the forwarded gas.
    function test_RevertWhen_RebalanceMoveFailsAboveFloor() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, NETUID1, 8e6, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        // The corrective move of 2e6 clears the floor, yet the chain rejects it; the fault bubbles.
        _setVaultStake(hotkey1, NETUID1, 6e6);
        _setVaultStake(hotkey2, NETUID1, 2e6);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeReverts(true);

        vm.expectRevert(bytes("MockStaking: moveStake reverted"));
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 6e6, "balances unchanged after the bubbled failure");
        assertEq(_getVaultStake(hotkey2, NETUID1), 2e6);
    }

    // The 1% corrective move is worth 3e4 tao, under the chain's own bar, so the armed all-gas
    // failure is reachable: the wrap fits its budget only if the move is skipped, never attempted.
    function test_Wrap_SkipsSubFloorRebalanceWithinGasBudget() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(9900, 100));
        MockStaking(STAKING_PRECOMPILE).setConsumeAllGasOnFailure(true);
        _setAlphaPrice(NETUID1, PRICE_HALF);

        // 6e6 alpha = 3e6 tao clears the deposit floor; the 6e4-alpha split move is 3e4 tao.
        _simulateAlphaDepositHotkey(alice, NETUID1, 6e6, hotkey1);
        vm.recordLogs();
        vm.prank(alice);
        vault.wrap{ gas: 1_500_000 }(NETUID1, hotkey1);

        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0, "doomed move never attempted");
        assertGt(vault.balanceOf(alice, TOKEN1), 0, "wrap completed within the fixed gas budget");
    }

    // Every slot is individually below the floor while the request clears it, so no gather hop can
    // be vouched for and the vault refuses up front.
    function test_RevertWhen_UnwrapWithAllSlotsSubFloor() public {
        _depositAndWrap(alice, NETUID1, 4_500_000);
        _setVaultStakes(NETUID1, 1_500_000, 1_500_000, 1_500_000);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vm.expectRevert(GatherBelowFloor.selector);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));
    }

    function test_RevertWhen_UnwrapRequestBelowFloor() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, NETUID1, 40e6, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        _setAlphaPrice(NETUID1, PRICE_HALF);
        uint256 burnShares = vault.balanceOf(alice, TOKEN1) * 5 / 100;

        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrap(TOKEN1, burnShares, _toSubstrate(alice));
    }

    function test_Unwrap_DeliversExactlyAtFloorValue() public {
        _depositAndWrap(alice, NETUID1, 40e6);
        uint256 shares = _sharesForExactAssets(TOKEN1, CHAIN_MIN_STAKE, 40e6);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), CHAIN_MIN_STAKE, "a request worth exactly the floor delivers");
    }

    // A chain upgrade binds the gate at its new value, with no vault-side action.
    function test_RevertWhen_DepositBelowRaisedChainFloor() public {
        _setChainMinStake(5e6);
        _registerSubnet(99, hotkey4);

        // 3e6 tao cleared the chain's previous 2e6 minimum but not the raised one.
        _simulateAlphaDepositHotkey(alice, 99, 3e6, hotkey4);
        vm.prank(alice);
        vm.expectRevert(DepositTooSmall.selector);
        vault.wrap(99, hotkey4);
    }

    function test_RevertWhen_UnwrapBelowRaisedChainFloor() public {
        _depositAndWrap(alice, NETUID1, 40e6);
        _setChainMinStake(5e6);

        // A 3e6-value request cleared the previous minimum; the raised one now refuses it.
        uint256 shares = _sharesForExactAssets(TOKEN1, 3e6, 40e6);
        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));
    }

    // The chain would move this deposit; the vault refuses it, because the only minimum it can
    // read is the higher one.
    function test_RevertWhen_WrapBetweenTheMoveAndUnstakeMinimums() public {
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, 1e18);
        uint256 deposit = (CHAIN_MIN_TRANSFER + CHAIN_MIN_STAKE) / 2;
        _simulateAlphaDepositHotkey(alice, 99, deposit, hotkey4);

        vm.prank(alice);
        vm.expectRevert(DepositTooSmall.selector);
        vault.wrap(99, hotkey4);

        _setChainMinStake(CHAIN_MIN_TRANSFER);
        _wrapHotkey(alice, 99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), deposit, "the chain takes it once the vault stops refusing");
    }

    // Slots large enough that a tenth is served by a checked partial rather than a full drain,
    // which is floor-exempt, and leaves a remainder clear of the dust threshold.
    function test_UnwrapForTao_FollowsRaisedChainFloor() public {
        _depositAndWrap(alice, NETUID1, 300e6);
        uint256 tenth = vault.balanceOf(alice, TOKEN1) / 10;
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, tenth, 0);
        assertGt(alice.balance, balanceBefore, "the partial sale clears the current minimum");

        _setChainMinStake(50e6);
        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrapForTao(TOKEN1, tenth, 0);
    }

    function test_Rebalance_SkipsEveryMoveBelowRaisedChainFloor() public {
        _depositAndWrap(alice, NETUID1, 40e6);
        _setVaultStakes(NETUID1, 20e6, 10e6, 10e6);
        _setChainMinStake(50e6);

        vm.recordLogs();
        vault.rebalance(NETUID1);

        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0, "a raised minimum stops every corrective move");
        assertEq(_getVaultStake(hotkey1, NETUID1), 20e6, "the split is left drifted");
    }

    function test_Rebalance_FollowsLoweredChainFloor() public {
        _depositAndWrap(alice, NETUID1, 40e6);
        _setAlphaPrice(NETUID1, PRICE_HALF);
        _setVaultStakes(NETUID1, 16e6, 12e6, 12e6);

        vault.rebalance(NETUID1);
        assertEq(_getVaultStake(hotkey1, NETUID1), 16e6, "the corrective move is under the current minimum");

        _setChainMinStake(5e5);
        vault.rebalance(NETUID1);

        assertLt(_getVaultStake(hotkey1, NETUID1), 16e6, "it lands once the minimum drops below it");
    }

    // The other direction: the vault never over-refuses after a chain change either.
    function test_Wrap_FollowsLoweredChainFloor() public {
        _registerSubnet(99, hotkey4);
        _simulateAlphaDepositHotkey(alice, 99, 1e6, hotkey4);

        vm.prank(alice);
        vm.expectRevert(DepositTooSmall.selector);
        vault.wrap(99, hotkey4);

        _setChainMinStake(5e5);
        _wrapHotkey(alice, 99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), 1e6, "deposit lands once the chain minimum drops below it");
    }

    // With nothing to skip, every guard stops refusing and the chain alone decides - which is what
    // the guards were standing in for all along.
    function test_Wrap_ChainMinimumOfZeroLeavesTheGateOpen() public {
        _setChainMinStake(0);
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, 1e18);
        _simulateAlphaDepositHotkey(alice, 99, CHAIN_MIN_TRANSFER, hotkey4);

        _wrapHotkey(alice, 99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), CHAIN_MIN_TRANSFER, "a zero minimum admits whatever the chain will move");
    }

    // The gate must track any value the chain could report, not just today's.
    function testFuzz_Wrap_GateBindsAtTheChainMinimum(uint256 chainMinStake, uint256 deposit) public {
        chainMinStake = bound(chainMinStake, 1, 50e6);
        deposit = bound(deposit, 1, 100e6);
        _setChainMinStake(chainMinStake);
        _registerSubnet(99, hotkey4);
        // At unit price the deposit is its own tao value, so the boundary is exactly `chainMinStake`.
        _setAlphaPrice(99, 1e18);
        _simulateAlphaDepositHotkey(alice, 99, deposit, hotkey4);

        vm.prank(alice);
        (bool ok, bytes memory ret) = address(vault).call(abi.encodeCall(vault.wrap, (99, hotkey4)));

        // The deposit must clear both bars to land: the vault's gate, then the chain's own minimum
        // for moving it out of the mailbox. The gate is checked first, so it names the refusal.
        bool clearsVaultGate = deposit >= chainMinStake;
        bool chainWillMoveIt = deposit >= CHAIN_MIN_TRANSFER;
        assertEq(ok, clearsVaultGate && chainWillMoveIt, "the gate binds exactly at the chain's reported minimum");

        if (!ok) {
            bytes memory expectedRefusal = clearsVaultGate
                ? abi.encodeWithSignature("Error(string)", "MockStaking: AmountTooLow")
                : abi.encodeWithSelector(DepositTooSmall.selector);
            assertEq(keccak256(ret), keccak256(expectedRefusal), "the refusal came from the bar that binds first");
            assertEq(_getVaultStake(hotkey4, 99), 0, "nothing staked behind the refusal");
            assertEq(vault.balanceOf(alice, vault.currentTokenId(99)), 0, "no shares minted behind the refusal");
        }
    }

    // The gather guard reads the same chain value: a raised minimum refuses a gather that used to
    // run, even though the request itself still clears the new minimum.
    function test_RevertWhen_GatherBelowRaisedChainFloor() public {
        _depositAndWrap(alice, NETUID1, 40e6);
        _setVaultStakes(NETUID1, 15e6, 15e6, 10e6);
        _setChainMinStake(20e6);

        // 25e6 clears the raised minimum, but no single slot covers it and the richest holds 15e6.
        uint256 shares = _sharesForExactAssets(TOKEN1, 25e6, 40e6);
        vm.prank(alice);
        vm.expectRevert(GatherBelowFloor.selector);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));
    }

    // The alpha rail quotes dust it will not deliver: previewUnwrap prices the shares while unwrap
    // of the same shares reverts, pointing the holder at unwrapForTao.
    function test_PreviewUnwrap_QuotesWhatDustUnwrapRefuses() public {
        _depositAndWrap(alice, NETUID1, 40e6);
        _setAlphaPrice(NETUID1, PRICE_HALF);

        // 3e6 alpha = 1.5e6 tao: above zero, below the floor.
        uint256 shares = _sharesForExactAssets(TOKEN1, 3e6, 40e6);
        (uint256 previewAlpha,) = lens.previewUnwrap(TOKEN1, shares);
        assertEq(previewAlpha, 3e6, "preview quotes the pro-rata alpha");

        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));
    }

    // The skip decision is exact across the whole (price, balances) plane: a move the label passes
    // always clears the chain's full-precision floor (the read only rounds down), so rebalance can
    // never trip the chain's AmountTooLow - it skips or it lands.
    function testFuzz_Rebalance_NeverTripsChainFloor(uint256 chainPriceE18, uint256 a, uint256 b, uint256 c) public {
        chainPriceE18 = bound(chainPriceE18, 1, 100e18);
        a = bound(a, 0, 1e16);
        b = bound(b, 0, 1e16);
        c = bound(c, 0, 1e16);
        _depositAndWrap(alice, NETUID1, 30 ether);
        _setAlphaPrice(NETUID1, chainPriceE18);
        uint256 total = _setVaultStakes(NETUID1, a, b, c);

        vault.rebalance(NETUID1);

        assertEq(lens.totalStake(TOKEN1), total, "every attempted move cleared the chain floor");
    }

    // Three outcomes: the vault refuses up front only where the rounded-down read proves the amount
    // is under the minimum it can see; a fall-through leaves the verdict to the chain, which refuses
    // only under its far lower move bar; success cleared that bar.
    function testFuzz_Rebalance_ConsolidationMatchesChainFloor(uint256 dust, uint256 chainPriceE18) public {
        dust = bound(dust, 1, 1e16);
        chainPriceE18 = bound(chainPriceE18, 1, 100e18);
        _registerSubnet(99, hotkey4);
        _simulateAlphaDepositHotkey(alice, 99, 10 ether, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);
        uint256 tokenId = vault.currentTokenId(99);
        _setVaultStake(hotkey4, 99, dust);
        _setValidators(99, _hotkeys(hotkey1), _weights(10_000));
        _setAlphaPrice(99, chainPriceE18);
        uint256 trueValue = (dust * chainPriceE18) / 1e18;
        uint256 read = _alphaPriceRead(99);

        (bool ok, bytes memory ret) = address(vault).call(abi.encodeCall(vault.rebalance, (99)));

        if (ok) {
            assertEq(_getVaultStake(hotkey4, 99), 0, "rotated-out stake consolidated");
            assertEq(lens.totalStake(tokenId), dust, "pile conserved onto the current set");
            assertGe(trueValue, CHAIN_MIN_TRANSFER, "the roll landed, so it cleared the chain's move bar");
        } else if (bytes4(ret) == ConsolidationBelowFloor.selector) {
            assertLt((dust * (read + 1e9)) / 1e18, CHAIN_MIN_STAKE, "reject only fires on the provable bound");
        } else {
            assertEq(
                keccak256(ret),
                keccak256(abi.encodeWithSignature("Error(string)", "MockStaking: AmountTooLow")),
                "fall-through surfaces the chain's own refusal"
            );
            assertTrue(
                read == 0 || (dust * (read + 1e9)) / 1e18 >= CHAIN_MIN_STAKE, "fell through only when unprovable"
            );
            assertLt(trueValue, CHAIN_MIN_TRANSFER, "the chain refused because the roll is below its move bar");
        }
    }

    // Delivery over adversarial splits is atomic: whatever the slot distribution and price, unwrap
    // either delivers exactly the pro-rata assets or reverts floor-classed with nothing moved.
    function testFuzz_Unwrap_DeliversExactlyOrRevertsAtomically(
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
        uint256 supply = _depositAndWrap(alice, NETUID1, 30 ether);
        _setAlphaPrice(NETUID1, chainPriceE18);
        uint256 total = _setVaultStakes(NETUID1, a, b, c);
        uint256 shares = (supply * shareBps) / 10_000;
        uint256 expected = (shares * (total + 1)) / (supply + 1e9);

        vm.prank(alice);
        (bool ok, bytes memory ret) =
            address(vault).call(abi.encodeCall(vault.unwrap, (TOKEN1, shares, _toSubstrate(alice))));

        if (ok) {
            assertEq(_userStakeAcrossHotkeys(alice, NETUID1), expected, "delivery is exact");
            assertEq(lens.totalStake(TOKEN1), total - expected, "only the delivered alpha left the vault");
        } else {
            bytes4 selector = bytes4(ret);
            bool chainRefusedTheMove =
                keccak256(ret) == keccak256(abi.encodeWithSignature("Error(string)", "MockStaking: AmountTooLow"));
            assertTrue(
                selector == WithdrawTooSmall.selector || selector == GatherBelowFloor.selector || chainRefusedTheMove,
                "only floor-classed reverts are legitimate"
            );
            assertEq(vault.balanceOf(alice, TOKEN1), supply, "shares intact after rollback");
            assertEq(lens.totalStake(TOKEN1), total, "nothing moved on revert");
        }
    }

    // The gate binds on the floored oracle read even when the chain price sits above it: a deposit
    // at exactly the read's boundary passes both the vault label and the chain's full-precision
    // floor.
    function test_Wrap_AcceptsBoundaryAtQuantizedRead() public {
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, 1.5e9);

        // Boundary at the floored 1e9 read: 2e15 alpha reads exactly 2e6 tao; the chain sees 3e6.
        _simulateAlphaDepositHotkey(alice, 99, 2e15, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), 2e15);
        assertGt(vault.balanceOf(alice, vault.currentTokenId(99)), 0);
    }

    // The richest balance sits inside the oracle's one-quantum band: the label cannot prove a pass, the bound
    // cannot prove a reject, so the roll falls through bare and the chain's full-precision floor
    // accepts it.
    function test_Rebalance_ConsolidatesRichestSlotInsideOracleQuantumBand() public {
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, 1.5e9);
        _simulateAlphaDepositHotkey(alice, 99, 4e15, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);

        // 1.5e15 alpha reads 1.5e6 tao at the floored 1e9 oracle price (sub-floor label) but is a
        // true 2.25e6 at the 1.5e9 chain price: inside the band, above the real floor.
        _setVaultStake(hotkey4, 99, 1.5e15);
        _setValidators(99, _hotkeys(hotkey1), _weights(10_000));

        vault.rebalance(99);

        assertEq(_getVaultStake(hotkey4, 99), 0, "in-band richest slot consolidated by the chain's own check");
        assertEq(_getVaultStake(hotkey1, 99), 1.5e15, "pile landed on the current set");
    }

    // Delivery is exact-or-revert: the gather target's transfer is bare, so a chain rejection
    // bubbles and the whole unwrap rolls back with shares intact.
    function test_RevertWhen_DeliveryTransferFails() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, NETUID1, 40e6, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        // A full drain gathers onto one hotkey then delivers via transferStake; force it to fail.
        MockStaking(STAKING_PRECOMPILE).setTransferStakeReverts(true);

        uint256 sharesBefore = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vm.expectRevert(bytes("MockStaking: transferStake reverted"));
        vault.unwrap(TOKEN1, sharesBefore, _toSubstrate(alice));

        assertEq(vault.balanceOf(alice, TOKEN1), sharesBefore, "shares intact after bubbled failure");
    }

    // Above the floor delivery is exact: what previewUnwrap quotes is exactly what unwrap pays.
    function testFuzz_Unwrap_DeliversExactlyPreview(uint256 priceE18, uint256 deposit) public {
        priceE18 = bound(priceE18, 0.1e18, 100e18);
        uint256 floorAlpha = (2e6 * 1e18) / priceE18 + 1;
        // 4x the floor so every per-validator slot after the weight split clears the floor and any
        // gather starts above it; delivery is then exact. Upper bound stays in u64-ish range.
        deposit = bound(deposit, 4 * floorAlpha, 1e15);

        _setAlphaPrice(NETUID1, priceE18);
        _depositAndWrap(alice, NETUID1, deposit);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 previewAlpha,) = lens.previewUnwrap(TOKEN1, shares);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));

        uint256 received = _userStakeAcrossHotkeys(alice, NETUID1);
        assertEq(received, previewAlpha, "delivery is exact - no shortfall above the floor");
    }

    // Each slot is worth 1.5e6 tao: under the unstake minimum, well over the move one. The vault
    // cannot prove the chain will refuse, so it falls through - and the gather lands.
    function test_Unwrap_GatherWithinOneQuantumOfFloorDelivers() public {
        _setAlphaPrice(NETUID1, 1e9);
        _depositAndWrap(alice, NETUID1, 6e15);
        _setVaultStakes(NETUID1, 1_500_000_000_000_000, 1_500_000_000_000_000, 1_500_000_000_000_000);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 previewAlpha,) = lens.previewUnwrap(TOKEN1, shares);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), previewAlpha, "the gather delivered the full preview");
    }

    function test_RevertWhen_WrapFlushFailsForNonFloorReason() public {
        _registerSubnet(99, hotkey4);
        _simulateAlphaDepositHotkey(alice, 99, 10e6, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setTransferStakeReverts(true);

        vm.prank(alice);
        vm.expectRevert(bytes("MockStaking: transferStake reverted"));
        vault.wrap(99, hotkey4);
    }
}
