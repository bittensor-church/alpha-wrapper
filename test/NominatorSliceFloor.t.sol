// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { PositionTooSmall } from "src/VaultErrors.sol";
import { CHAIN_MIN_STAKE, MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract NominatorSliceFloorTest is AlphaVaultTestBase {
    uint256 private constant UNIT_PRICE = 1e18;

    function _assertSweepSafe(bytes32[] memory hotkeys, uint256 netuid) private view returns (uint256 nonZero) {
        uint256 priceE18 = _alphaPriceRead(netuid);
        for (uint256 i; i < hotkeys.length;) {
            uint256 balance = _getVaultStake(hotkeys[i], netuid);
            if (balance != 0) {
                ++nonZero;
                assertGe((balance * priceE18) / 1e18, DUST_THRESHOLD, "non-zero slice is sweepable");
            }
            unchecked {
                ++i;
            }
        }
    }

    function test_Wrap_ThreeValidatorSmallPositionConcentratesOnHighestWeight() public {
        bytes32[] memory hotkeys = _setValidatorCount(NETUID1, 3);
        uint256 deposit = DUST_THRESHOLD + 1;
        _simulateAlphaDepositHotkey(alice, NETUID1, deposit, hotkeys[0]);

        vm.expectCall(STAKING_PRECOMPILE, abi.encodeCall(MockStaking.getNominatorMinRequiredStake, ()), uint64(1));
        _wrapHotkey(alice, NETUID1, hotkeys[0]);

        assertEq(_assertSweepSafe(hotkeys, NETUID1), 1, "small position should use one safe slice");
        assertEq(_getVaultStake(hotkeys[2], NETUID1), deposit, "highest-weight validator receives the position");
    }

    function test_RevertWhen_WrapWouldCreateSweepableWholePosition() public {
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, UNIT_PRICE);
        _simulateAlphaDepositHotkey(alice, 99, DUST_THRESHOLD - 1, hotkey4);

        vm.prank(alice);
        vm.expectRevert(PositionTooSmall.selector);
        vault.wrap(99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), 0, "failed wrap rolls the flush back");
        assertEq(vault.balanceOf(alice, vault.currentTokenId(99)), 0, "failed wrap mints no shares");
    }

    function test_Wrap_SubThresholdTopUpIntoSafePositionSucceeds() public {
        _setAlphaPrice(NETUID1, UNIT_PRICE);
        _depositAndWrap(alice, NETUID1, 90e6);

        _simulateAlphaDepositHotkey(alice, NETUID1, CHAIN_MIN_STAKE, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        assertEq(lens.totalStake(TOKEN1), 92e6, "top-up joins the existing safe position");
        assertEq(_assertSweepSafe(_hotkeys(hotkey1, hotkey2, hotkey3), NETUID1), 3);
    }

    function test_Wrap_TargetExactlyAtThresholdIsKept() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _setAlphaPrice(NETUID1, UNIT_PRICE);
        _simulateAlphaDepositHotkey(alice, NETUID1, 2 * DUST_THRESHOLD, hotkey1);

        _wrapHotkey(alice, NETUID1, hotkey1);

        assertEq(_getVaultStake(hotkey1, NETUID1), DUST_THRESHOLD);
        assertEq(_getVaultStake(hotkey2, NETUID1), DUST_THRESHOLD);
    }

    function test_Wrap_TargetOneRaoBelowThresholdIsFolded() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _setAlphaPrice(NETUID1, UNIT_PRICE);
        uint256 deposit = 2 * DUST_THRESHOLD - 1;
        _simulateAlphaDepositHotkey(alice, NETUID1, deposit, hotkey1);

        _wrapHotkey(alice, NETUID1, hotkey1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "sub-threshold target is removed");
        assertEq(_getVaultStake(hotkey2, NETUID1), deposit, "folded amount is conserved exactly");
    }

    function test_Rebalance_DrainsUnsafeSourceTailInsteadOfLeavingIt() public {
        bytes32[] memory hotkeys = _hotkeysFrom("source-tail", 4);
        uint16[] memory weights = new uint16[](4);
        weights[0] = 1250;
        weights[1] = 3250;
        weights[2] = 3000;
        weights[3] = 2500;
        _setValidators(NETUID1, hotkeys, weights);
        _setAlphaPrice(NETUID1, UNIT_PRICE);
        _simulateAlphaDepositHotkey(alice, NETUID1, 100e6, hotkeys[0]);
        _wrapHotkey(alice, NETUID1, hotkeys[0]);

        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking staking = MockStaking(STAKING_PRECOMPILE);
        staking.setStake(hotkeys[0], coldkey, NETUID1, 25e6);
        staking.setStake(hotkeys[1], coldkey, NETUID1, 35e6);
        staking.setStake(hotkeys[2], coldkey, NETUID1, 0);
        staking.setStake(hotkeys[3], coldkey, NETUID1, 20e6);

        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkeys[0], NETUID1), 0, "zero-target source is drained fully");
        assertEq(_assertSweepSafe(hotkeys, NETUID1), 3);
        assertEq(_vaultStakeAcross(hotkeys, NETUID1), 80e6, "full-source move conserves backing");
    }

    function test_Rebalance_SkipsMoveThatWouldCreateUnsafeDestination() public {
        _setAlphaPrice(NETUID1, UNIT_PRICE);
        _depositAndWrap(alice, NETUID1, 90e6);
        _setVaultStakes(NETUID1, 20_500_000, 39_510_000, 0);

        vm.recordLogs();
        vault.rebalance(NETUID1);

        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0, "unsafe partial destination is not created");
        assertEq(_getVaultStake(hotkey1, NETUID1), 20_500_000);
        assertEq(_getVaultStake(hotkey2, NETUID1), 39_510_000);
        assertEq(_getVaultStake(hotkey3, NETUID1), 0);
    }

    function test_Unwrap_GathersBeforeCreatingUnsafeDeliveryTail() public {
        _setAlphaPrice(NETUID1, UNIT_PRICE);
        _depositAndWrap(alice, NETUID1, 90e6);
        uint256 shares = _sharesForExactAssets(TOKEN1, 15e6, 90e6);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 15e6, "delivery remains exact");
        assertEq(_assertSweepSafe(_hotkeys(hotkey1, hotkey2, hotkey3), NETUID1), 3);
    }

    function test_RevertWhen_PartialUnwrapWouldLeaveSweepablePosition() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _setAlphaPrice(NETUID1, UNIT_PRICE);
        _depositAndWrap(alice, NETUID1, 40e6);
        uint256 shares = _sharesForExactAssets(TOKEN1, 25e6, 40e6);

        vm.prank(alice);
        vm.expectRevert(PositionTooSmall.selector);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));

        assertEq(lens.totalStake(TOKEN1), 40e6, "failed partial exit leaves backing untouched");
    }

    function test_Unwrap_FullBurnAfterEmissionsDrainsExactBacking() public {
        _setAlphaPrice(NETUID1, UNIT_PRICE);
        _depositAndWrap(alice, NETUID1, 90e6);
        _simulateEmissions(NETUID1, 30e6);
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 previewed,) = lens.previewUnwrap(TOKEN1, shares);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));

        assertEq(previewed, 120e6, "full-burn preview quotes exact backing");
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 120e6, "last holder receives all backing");
        assertEq(lens.totalStake(TOKEN1), 0, "full burn leaves no sweepable orphan");
        assertEq(vault.totalSupply(TOKEN1), 0);
    }

    function test_Rebalance_PriceCrashConcentratesInsteadOfFragmenting() public {
        _setAlphaPrice(NETUID1, UNIT_PRICE);
        _depositAndWrap(alice, NETUID1, 100e6);

        _setAlphaPrice(NETUID1, 0.5e18);
        vault.rebalance(NETUID1);

        assertEq(_assertSweepSafe(_hotkeys(hotkey1, hotkey2, hotkey3), NETUID1), 1);
        assertEq(lens.totalStake(TOKEN1), 100e6);
    }

    function test_Wrap_QuantizedPriceReadConcentratesConservatively() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        // The EVM reads 1e9 while the chain sees 1.5e9. Using the read plus its quantum would
        // spread this position; using the rounded-down read keeps the split safe at either price.
        _setAlphaPrice(NETUID1, 1.5e9);
        uint256 deposit = 30e15;
        _simulateAlphaDepositHotkey(alice, NETUID1, deposit, hotkey1);

        _wrapHotkey(alice, NETUID1, hotkey1);

        assertEq(_getVaultStake(hotkey1, NETUID1), deposit);
        assertEq(_getVaultStake(hotkey2, NETUID1), 0);
    }

    function test_Wrap_ZeroPriceReadLeavesPositionConcentrated() public {
        _setAlphaPriceReadsZero(NETUID1);
        uint256 deposit = 50e15;
        _simulateAlphaDepositHotkey(alice, NETUID1, deposit, hotkey1);

        _wrapHotkey(alice, NETUID1, hotkey1);

        assertEq(_getVaultStake(hotkey1, NETUID1), deposit);
        assertEq(_getVaultStake(hotkey2, NETUID1), 0);
        assertEq(_getVaultStake(hotkey3, NETUID1), 0);
    }

    function test_Wrap_LargePositionKeepsExactWeightSplit() public {
        _setAlphaPrice(NETUID1, UNIT_PRICE);
        _depositAndWrap(alice, NETUID1, 90e6);

        uint256 first = _weighted(90e6, NETUID1_BPS_HK1);
        uint256 second = _weighted(90e6, NETUID1_BPS_HK2);
        assertEq(_getVaultStake(hotkey1, NETUID1), first);
        assertEq(_getVaultStake(hotkey2, NETUID1), second);
        assertEq(_getVaultStake(hotkey3, NETUID1), 90e6 - first - second, "last slot absorbs the remainder");
    }

    function testFuzz_Wrap_ThreeValidatorsNeverCreatesSweepableSlice(uint256 total, uint256 priceE18) public {
        priceE18 = bound(priceE18, 0.1e18, 100e18);
        priceE18 -= priceE18 % 1e9;
        uint256 minSliceAlpha = (DUST_THRESHOLD * 1e18 + priceE18 - 1) / priceE18;
        total = bound(total, minSliceAlpha, minSliceAlpha * 6);

        bytes32[] memory hotkeys = _setValidatorCount(NETUID1, 3);
        _setAlphaPrice(NETUID1, priceE18);
        _simulateAlphaDepositHotkey(alice, NETUID1, total, hotkeys[0]);

        _wrapHotkey(alice, NETUID1, hotkeys[0]);

        uint256 nonZero = _assertSweepSafe(hotkeys, NETUID1);
        assertLe(nonZero, total / minSliceAlpha, "position uses no more safe slices than it can fund");
        assertEq(_vaultStakeAcross(hotkeys, NETUID1), total);
    }

    function testFuzz_Rebalance_PreservesSafeOrZeroSlices(uint256 a, uint256 b, uint256 c) public {
        _setAlphaPrice(NETUID1, UNIT_PRICE);
        _depositAndWrap(alice, NETUID1, 90e6);
        a = a % 100e6;
        b = b % 100e6;
        c = c % 100e6;
        a = a == 0 ? 0 : DUST_THRESHOLD + a;
        b = b == 0 ? 0 : DUST_THRESHOLD + b;
        c = c == 0 ? 0 : DUST_THRESHOLD + c;
        _setVaultStakes(NETUID1, a, b, c);

        vault.rebalance(NETUID1);

        _assertSweepSafe(_hotkeys(hotkey1, hotkey2, hotkey3), NETUID1);
        assertEq(lens.totalStake(TOKEN1), a + b + c);
    }

    function testFuzz_PartialUnwrap_NeverCreatesSweepableSlice(uint256 total, uint256 burnBps) public {
        total = bound(total, 100e6, 1e9);
        burnBps = bound(burnBps, 2500, 5000);
        _setAlphaPrice(NETUID1, UNIT_PRICE);
        _depositAndWrap(alice, NETUID1, total);
        uint256 shares = (vault.balanceOf(alice, TOKEN1) * burnBps) / BPS_BASE;
        (uint256 previewed,) = lens.previewUnwrap(TOKEN1, shares);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));

        _assertSweepSafe(_hotkeys(hotkey1, hotkey2, hotkey3), NETUID1);
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), previewed);
        assertEq(lens.totalStake(TOKEN1), total - previewed);
    }
}
