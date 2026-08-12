// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";

/// forge-config: default.isolate = true
contract AlphaVaultGasTest is AlphaVaultTestBase {
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
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice));
        vm.snapshotGasLastCall("AlphaVault", "unwrap: partial");
    }

    function test_gas_unwrap_full() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));
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

        uint256 total = _setVaultStakes(NETUID1, 60 ether, 0, 40 ether);
        // The 1e6 remainder on hotkey3 is a sub-floor partial; it is skipped and refunded as shares.
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

        vault.previewUnwrap(TOKEN1, shares / 2);
        vm.snapshotGasLastCall("AlphaVault", "previewUnwrap");
    }

    // --------- widest supported set ------------------------------------------
    // Three validators is the expected size; the entries below price the 64-validator ceiling so a
    // change that only shows up at full width cannot land unnoticed.

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
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice));
        vm.snapshotGasLastCall("AlphaVault", "unwrap: partial (64 validators)");
    }

    function test_gas_unwrap_full_64Validators() public {
        _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));
        vm.snapshotGasLastCall("AlphaVault", "unwrap: full (64 validators)");
    }

    function test_gas_previewUnwrap_64Validators() public {
        _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vault.previewUnwrap(TOKEN1, shares / 2);
        vm.snapshotGasLastCall("AlphaVault", "previewUnwrap (64 validators)");
    }
}
