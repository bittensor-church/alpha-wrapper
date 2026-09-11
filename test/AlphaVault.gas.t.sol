// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { MAX_VALIDATORS } from "src/ValidatorRegistry.sol";

// Mock-based regression measurements, not live-chain gas estimates; use e2e receipts for sizing.

/// forge-config: default.isolate = true
contract AlphaVaultGasTest is AlphaVaultTestBase {
    function test_gas_createMailbox_firstOnSubnet() public {
        vm.prank(alice);
        vault.createMailbox(NETUID1);
        vm.snapshotGasLastCall("AlphaVault", "createMailbox: first on subnet");
    }

    function test_gas_createMailbox_sharedSubnet() public {
        _prepareMailbox(alice, NETUID1);
        vm.prank(bob);
        vault.createMailbox(NETUID1);
        vm.snapshotGasLastCall("AlphaVault", "createMailbox: shared subnet");
    }

    function test_gas_createMailbox_existing() public {
        _prepareMailbox(alice, NETUID1);
        vm.prank(alice);
        vault.createMailbox(NETUID1);
        vm.snapshotGasLastCall("AlphaVault", "createMailbox: existing");
    }

    function test_gas_wrap_firstWrap() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        vm.snapshotGasLastCall("AlphaVault", "wrap: first");
    }

    function test_gas_wrap_subsequentWrap() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        _simulateAlphaDeposit(bob, NETUID1, 5 ether);
        _wrap(bob, NETUID1);
        vm.snapshotGasLastCall("AlphaVault", "wrap: subsequent");
    }

    function test_gas_unwrap_partial() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);
        vm.snapshotGasLastCall("AlphaVault", "unwrap: partial");
    }

    function test_gas_unwrap_full() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        vm.snapshotGasLastCall("AlphaVault", "unwrap: full");
    }

    function test_gas_unwrapForTao_partialTailAboveFloor() public {
        _setRemoveStakeRate(1, 1);
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);
        vm.snapshotGasLastCall("AlphaVault", "unwrapForTao: partial tail above floor");
    }

    function test_gas_unwrapForTao_subFloorTailRefunded() public {
        _setRemoveStakeRate(1, 1);
        _simulateAlphaDeposit(alice, NETUID1, 100 ether);
        _wrap(alice, NETUID1);

        uint256 total = _plantVaultStakes(NETUID1, 60 ether, 0, 40 ether);
        // The 1e6 remainder is a sub-floor partial, refunded as shares.
        uint256 shares = _sharesForExactAssets(TOKEN1, 60 ether + 1e6, total);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);
        vm.snapshotGasLastCall("AlphaVault", "unwrapForTao: sub-floor tail refunded");
    }

    function test_gas_rebalance() public {
        _simulateAlphaDeposit(alice, NETUID1, 100 ether);
        _wrap(alice, NETUID1);

        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(5000, 3000, 2000));

        vault.rebalance(NETUID1);
        vm.snapshotGasLastCall("AlphaVault", "rebalance: after registry weight update");
    }

    function test_gas_previewUnwrap() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        lens.previewUnwrap(TOKEN1, shares / 2);
        vm.snapshotGasLastCall("AlphaVaultLens", "previewUnwrap");
    }

    // Repeating one id measures the loop, not cold reads across independent positions.
    function test_gas_claimableTaoOf() public {
        _seedClaimableTao();

        lens.claimableTaoOf(alice, TOKEN1);
        vm.snapshotGasLastCall("AlphaVaultLens", "claimableTaoOf");
    }

    function test_gas_batchClaimableTaoOf_20RepeatedIds() public {
        _seedClaimableTao();
        uint256[] memory ids = new uint256[](20);
        for (uint256 i = 0; i < ids.length; i++) {
            ids[i] = TOKEN1;
        }

        lens.batchClaimableTaoOf(alice, ids);
        vm.snapshotGasLastCall("AlphaVaultLens", "batchClaimableTaoOf (20 repeated ids)");
    }

    function test_gas_batchClaimableTaoOf_20DistinctPositions() public {
        uint256[] memory ids = new uint256[](20);
        for (uint256 i; i < ids.length; ++i) {
            uint256 netuid = 100 + i;
            _registerSubnet(netuid, hotkey1);
            _depositAndWrap(alice, netuid, 10e9);
            ids[i] = vault.currentTokenId(netuid);
            _donateToClone(vault.subnetClone(ids[i]), 3 ether);
        }

        lens.batchClaimableTaoOf(alice, ids);
        vm.snapshotGasLastCall("AlphaVaultLens", "batchClaimableTaoOf (20 distinct positions)");
    }

    function _seedClaimableTao() private {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        _donateToClone(vault.subnetClone(TOKEN1), 3 ether);
    }

    function test_gas_wrap_firstWrap_64Validators() public {
        _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        vm.snapshotGasLastCall("AlphaVault", "wrap: first (64 validators)");
    }

    function test_gas_wrap_subsequentWrap_64Validators() public {
        _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        _simulateAlphaDeposit(bob, NETUID1, 5 ether);
        _wrap(bob, NETUID1);
        vm.snapshotGasLastCall("AlphaVault", "wrap: subsequent (64 validators)");
    }

    function test_gas_unwrap_partial_64Validators() public {
        _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);
        vm.snapshotGasLastCall("AlphaVault", "unwrap: partial (64 validators)");
    }

    function test_gas_unwrap_full_64Validators() public {
        _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        vm.snapshotGasLastCall("AlphaVault", "unwrap: full (64 validators)");
    }

    function test_gas_unwrapForTao_full_64Validators() public {
        _setRemoveStakeRate(1, 1);
        _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);
        vm.snapshotGasLastCall("AlphaVault", "unwrapForTao: full (64 validators)");
    }

    // A registry rotation must not widen the TAO path, which reads only recorded keys.
    function test_gas_unwrapForTao_fullyRotated_64Validators() public {
        _setRemoveStakeRate(1, 1);
        _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        _setValidators(NETUID1, _hotkeysFrom("rotated", MAX_VALIDATORS), _evenWeights(MAX_VALIDATORS));

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);
        vm.snapshotGasLastCall("AlphaVault", "unwrapForTao: full after a rotation (64 validators)");
    }

    function test_gas_rebalance_fullyRotated_64Validators() public {
        _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        _setValidators(NETUID1, _hotkeysFrom("rotated", MAX_VALIDATORS), _evenWeights(MAX_VALIDATORS));

        vault.rebalance(NETUID1);
        vm.snapshotGasLastCall("AlphaVault", "rebalance: fully rotated (64 validators)");
    }

    function test_gas_syncBacking_64Validators() public {
        _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        _buildSwapTrail(NETUID1, lens.getCurrentValidators(NETUID1)[0], 2);

        vault.syncBacking(TOKEN1);
        vm.snapshotGasLastCall("AlphaVault", "syncBacking: loss on file (64 validators)");
    }

    function test_gas_recoverStray_64Validators() public {
        _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        bytes32 lost = lens.getCurrentValidators(NETUID1)[0];
        bytes32 tip = _buildSwapTrail(NETUID1, lost, 2);
        vault.syncBacking(TOKEN1);

        vault.recoverStray(TOKEN1, tip);
        vm.snapshotGasLastCall("AlphaVault", "recoverStray: collect one source (64 validators)");

        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 10 ether);
        assertEq(_parkedStake(NETUID1), 10 ether);
    }

    function test_gas_recoverStray_merged_64Validators() public {
        bytes32[] memory hotkeys = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _depositAndWrap(alice, NETUID1, 10 ether);
        bytes32 source = keccak256("merged-recovery");
        for (uint256 i; i < hotkeys.length; ++i) {
            _simulateOffVaultSwap(NETUID1, hotkeys[i], source);
        }
        vault.syncBacking(TOKEN1);

        vault.recoverStray(TOKEN1, source);
        vm.snapshotGasLastCall("AlphaVault", "recoverStray: collect merged source (64 validators)");

        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 10 ether);
        assertEq(lens.frozenUntil(TOKEN1), 0);
        assertEq(_getVaultStake(source, NETUID1), 0);
    }

    function test_gas_rebalance_releaseParked_64Validators() public {
        _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        bytes32 tip = _buildSwapTrail(NETUID1, lens.getCurrentValidators(NETUID1)[0], 2);
        vault.syncBacking(TOKEN1);
        vault.recoverStray(TOKEN1, tip);
        vault.syncBacking(TOKEN1);
        _reattestCurrentSet(NETUID1);

        vault.rebalance(NETUID1);
        vm.snapshotGasLastCall("AlphaVault", "rebalance: release parked position (64 validators)");

        assertFalse(lens.awaitingAttestation(TOKEN1));
        assertEq(_parkedStake(NETUID1), 0);
    }

    function test_gas_previewUnwrap_64Validators() public {
        _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        lens.previewUnwrap(TOKEN1, shares / 2);
        vm.snapshotGasLastCall("AlphaVaultLens", "previewUnwrap (64 validators)");
    }
}
