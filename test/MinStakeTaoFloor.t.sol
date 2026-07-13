// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Exercises the TAO-denominated min-stake floor: the wrap/withdraw labels, the best-effort
///      rebalance skip, exact-or-revert delivery, and the owner knob.
contract MinStakeTaoFloorTest is AlphaVaultTestBase {
    event MinStakeTaoFloorUpdated(uint256 oldValue, uint256 newValue);

    uint256 private constant PRICE_HALF = 0.5e18;

    function test_RevertWhen_WrapDepositBelowTaoFloor() public {
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, PRICE_HALF);

        // 3e6 alpha = 1.5e6 tao, below the 2e6 floor.
        _simulateAlphaDepositHotkey(alice, 99, 3e6, hotkey4);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.DepositTooSmall.selector);
        vault.wrap(alice, 99, hotkey4);
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

    // The real precompile consumes all forwarded gas when it rejects a call, so a doomed rebalance
    // move must be skipped without ever being attempted; the whole wrap fits a fixed budget only then.
    function test_Wrap_SkipsSubFloorRebalanceWithinGasBudget() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        MockStaking(STAKING_PRECOMPILE).setConsumeAllGasOnFailure(true);
        _setAlphaPrice(NETUID1, PRICE_HALF);

        // 6e6 alpha = 3e6 tao clears the deposit floor; the 3e6-alpha split move is 1.5e6 tao and does not.
        _simulateAlphaDepositHotkey(alice, NETUID1, 6e6, hotkey1);
        vm.recordLogs();
        vm.prank(alice);
        vault.wrap{ gas: 1_500_000 }(alice, NETUID1, hotkey1);

        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0, "doomed move never attempted");
        assertGt(vault.balanceOf(alice, TOKEN1), 0, "wrap completed within the fixed gas budget");
    }

    // Every slot is individually below the floor while the request clears it: the gather's first
    // hop could never clear the chain's floor, so the redemption is rejected up front.
    function test_RevertWhen_UnwrapWithAllSlotsSubFloor() public {
        _depositAndWrap(alice, NETUID1, 4_500_000);
        _setVaultStakes(NETUID1, 1_500_000, 1_500_000, 1_500_000);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.GatherBelowFloor.selector);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));
    }

    function test_RevertWhen_UnwrapRequestBelowFloor() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, NETUID1, 40e6, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        _setAlphaPrice(NETUID1, PRICE_HALF);
        uint256 burnShares = vault.balanceOf(alice, TOKEN1) * 5 / 100;

        vm.prank(alice);
        vm.expectRevert(AlphaVault.WithdrawTooSmall.selector);
        vault.unwrap(TOKEN1, burnShares, _toSubstrate(alice));
    }

    function test_Unwrap_DeliversExactlyAtFloorValue() public {
        _depositAndWrap(alice, NETUID1, 40e6);
        uint256 shares = _sharesForExactAssets(TOKEN1, MIN_STAKE_FLOOR, 40e6);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), MIN_STAKE_FLOOR, "a request worth exactly the floor delivers");
    }

    // The knob's purpose: a raised floor binds the deposit gate at the new value, not the chain's.
    function test_RevertWhen_DepositBelowRaisedFloor() public {
        vault.setMinStakeTaoFloor(5e6);
        _registerSubnet(99, hotkey4);

        // 3e6 tao clears the chain's 2e6 floor but not the raised vault floor.
        _simulateAlphaDepositHotkey(alice, 99, 3e6, hotkey4);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.DepositTooSmall.selector);
        vault.wrap(alice, 99, hotkey4);
    }

    function test_RevertWhen_UnwrapBelowRaisedFloor() public {
        _depositAndWrap(alice, NETUID1, 40e6);
        vault.setMinStakeTaoFloor(5e6);

        // A 3e6-value request cleared the deploy-time floor; the raised floor now refuses it.
        uint256 shares = _sharesForExactAssets(TOKEN1, 3e6, 40e6);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.WithdrawTooSmall.selector);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));
    }

    // The alpha rail quotes dust it will not deliver: previewUnwrap prices the shares while unwrap
    // of the same shares reverts, pointing the holder at unwrapForTao.
    function test_PreviewUnwrap_QuotesWhatDustUnwrapRefuses() public {
        _depositAndWrap(alice, NETUID1, 40e6);
        _setAlphaPrice(NETUID1, PRICE_HALF);

        // 3e6 alpha = 1.5e6 tao: above zero, below the floor.
        uint256 shares = _sharesForExactAssets(TOKEN1, 3e6, 40e6);
        (uint256 previewAlpha,) = vault.previewUnwrap(TOKEN1, shares);
        assertEq(previewAlpha, 3e6, "preview quotes the pro-rata alpha");

        vm.prank(alice);
        vm.expectRevert(AlphaVault.WithdrawTooSmall.selector);
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

        assertEq(vault.totalStake(TOKEN1), total, "every attempted move cleared the chain floor");
    }

    // Consolidation is a trichotomy and each arm must match the chain's own verdict: an up-front
    // ConsolidationBelowFloor may fire only when the true price makes the roll chain-certain to
    // fail; a bare fall-through may be chain-rejected only when the read could not prove the
    // failure; success requires the true value to clear the floor.
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
            assertEq(_getVaultStake(hotkey4, 99), 0, "orphan consolidated");
            assertEq(vault.totalStake(tokenId), dust, "pile conserved onto the current set");
            assertGe(trueValue, MIN_STAKE_FLOOR, "chain accepted because truly at or above the floor");
        } else if (bytes4(ret) == AlphaVault.ConsolidationBelowFloor.selector) {
            assertLt((dust * (read + 1e9)) / 1e18, MIN_STAKE_FLOOR, "reject only fires on the provable bound");
            assertLt(trueValue, MIN_STAKE_FLOOR, "and the reject is chain-certain");
        } else {
            assertEq(bytes4(ret), bytes4(0x08c379a0), "fall-through surfaces the chain's own error");
            assertTrue(
                read == 0 || (dust * (read + 1e9)) / 1e18 >= MIN_STAKE_FLOOR, "fell through only when unprovable"
            );
            assertLt(trueValue, MIN_STAKE_FLOOR, "chain rejected because truly below the floor");
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
            assertEq(vault.totalStake(TOKEN1), total - expected, "only the delivered alpha left the vault");
        } else {
            bytes4 selector = bytes4(ret);
            assertTrue(
                selector == AlphaVault.WithdrawTooSmall.selector || selector == AlphaVault.GatherBelowFloor.selector
                    || selector == bytes4(0x08c379a0),
                "only floor-classed reverts are legitimate"
            );
            assertEq(vault.balanceOf(alice, TOKEN1), supply, "shares intact after rollback");
            assertEq(vault.totalStake(TOKEN1), total, "nothing moved on revert");
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

    // The seed sits inside the oracle's one-quantum band: the label cannot prove a pass, the bound
    // cannot prove a reject, so the roll falls through bare and the chain's full-precision floor
    // accepts it.
    function test_Rebalance_ConsolidatesSeedInsideOracleQuantumBand() public {
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, 1.5e9);
        _simulateAlphaDepositHotkey(alice, 99, 4e15, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);

        // 1.5e15 alpha reads 1.5e6 tao at the floored 1e9 oracle price (sub-floor label) but is a
        // true 2.25e6 at the 1.5e9 chain price: inside the band, above the real floor.
        _setVaultStake(hotkey4, 99, 1.5e15);
        _setValidators(99, _hotkeys(hotkey1), _weights(10_000));

        vault.rebalance(99);

        assertEq(_getVaultStake(hotkey4, 99), 0, "band seed consolidated by the chain's own check");
        assertEq(_getVaultStake(hotkey1, 99), 1.5e15, "pile landed on the current set");
    }

    // Delivery is exact-or-revert: the gather target's transfer is bare, so a chain rejection
    // bubbles and the whole redemption rolls back with shares intact.
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
        // 4x the floor so every per-validator slot after the weight split clears the floor and seeds
        // an above-floor gather; delivery is then exact. Upper bound stays in u64-ish range.
        deposit = bound(deposit, 4 * floorAlpha, 1e15);

        _setAlphaPrice(NETUID1, priceE18);
        _depositAndWrap(alice, NETUID1, deposit);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 previewAlpha,) = vault.previewUnwrap(TOKEN1, shares);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));

        uint256 received = _userStakeAcrossHotkeys(alice, NETUID1);
        assertEq(received, previewAlpha, "delivery is exact - no shortfall above the floor");
    }

    function test_SetMinStakeTaoFloor_UpdatesValueAndEmits() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit MinStakeTaoFloorUpdated(2e6, 5e6);
        vault.setMinStakeTaoFloor(5e6);
        assertEq(vault.minStakeTaoFloor(), 5e6);
    }

    function test_RevertWhen_MinStakeTaoFloorAboveCap() public {
        vm.expectRevert(AlphaVault.MinStakeTaoFloorTooHigh.selector);
        vault.setMinStakeTaoFloor(100e6 + 1);
    }

    function test_SetMinStakeTaoFloor_AcceptsCapBoundary() public {
        vault.setMinStakeTaoFloor(100e6);
        assertEq(vault.minStakeTaoFloor(), 100e6);
    }

    function test_Constructor_DefaultsFloorToChainMinimum() public view {
        assertEq(vault.minStakeTaoFloor(), MIN_STAKE_FLOOR, "deploy default tracks the chain floor");
    }

    // No lower clamp: the owner follows the chain floor in either direction, anywhere under the
    // cap. Keeping the value at or above the chain's live floor is an operational responsibility,
    // not an on-chain invariant.
    function test_SetMinStakeTaoFloor_TracksChainFloorInBothDirections() public {
        vault.setMinStakeTaoFloor(5e5);
        assertEq(vault.minStakeTaoFloor(), 5e5, "follows a chain-floor decrease below the deploy value");

        vault.setMinStakeTaoFloor(20e6);
        assertEq(vault.minStakeTaoFloor(), 20e6, "follows a chain-floor increase toward the cap");
    }

    // Within one price quantum of the floor the label cannot prove the chain will reject, so the
    // gather falls through bare and the chain's full-precision floor decides.
    function test_RevertWhen_GatherSeedWithinOneQuantumOfFloor() public {
        _setAlphaPrice(NETUID1, 1e9);
        _depositAndWrap(alice, NETUID1, 6e15);
        _setVaultStakes(NETUID1, 1_500_000_000_000_000, 1_500_000_000_000_000, 1_500_000_000_000_000);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vm.expectRevert(bytes("MockStaking: AmountTooLow"));
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));
    }

    function test_RevertWhen_NonOwnerSetsMinStakeTaoFloor() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setMinStakeTaoFloor(3e6);
    }

    function test_RevertWhen_WrapFlushFailsForNonFloorReason() public {
        _registerSubnet(99, hotkey4);
        _simulateAlphaDepositHotkey(alice, 99, 10e6, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setTransferStakeReverts(true);

        vm.prank(alice);
        vm.expectRevert(bytes("MockStaking: transferStake reverted"));
        vault.wrap(alice, 99, hotkey4);
    }
}
