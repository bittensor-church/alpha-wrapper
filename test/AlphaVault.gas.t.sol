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

    function test_gas_unwrapForTao_subFloorFinalSliceSkipped() public {
        _setRemoveStakeRate(1, 1);
        _simulateAlphaDeposit(alice, NETUID1, 100 ether);
        _wrap(alice, NETUID1);

        uint256 total = _setVaultStakes(NETUID1, 60 ether, 0, 40 ether);
        // The 1e6 remainder on hotkey3 is a sub-floor partial; it is skipped, under-delivering dust.
        uint256 shares = _sharesForExactAssets(TOKEN1, 60 ether + 1e6, total);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);
        vm.snapshotGasLastCall("AlphaVault", "unwrapForTao: sub-floor final slice skipped");
    }

    function test_gas_rebalance() public {
        _simulateAlphaDeposit(alice, NETUID1, 100 ether);
        _wrap(alice, NETUID1);

        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(5000, 3000, 2000));

        vault.rebalance(NETUID1);
        vm.snapshotGasLastCall("AlphaVault", "rebalance: after registry weight update");
    }

    function test_gas_wrap_tenValidators() public {
        _attestAndWrap(alice, NETUID1, _generatedHotkeys(10), _splitWeights(10), 100 ether);
        vm.snapshotGasLastCall("AlphaVault", "wrap: ten validators");
    }

    function test_gas_unwrap_fullTenValidators() public {
        _attestAndWrap(alice, NETUID1, _generatedHotkeys(10), _splitWeights(10), 100 ether);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));
        vm.snapshotGasLastCall("AlphaVault", "unwrap: full ten validators");
    }

    function test_gas_wrap_maxValidators() public {
        uint256 maxValidators = registry.MAX_VALIDATORS();
        _attestAndWrap(alice, NETUID1, _generatedHotkeys(maxValidators), _splitWeights(maxValidators), 100 ether);
        vm.snapshotGasLastCall("AlphaVault", "wrap: max validators");
    }

    /// @dev The costliest wrap shape: the whole max-size set is rotated out, so the call rolls
    ///      every old slot onto the new set before splitting across it.
    function test_gas_wrap_maxValidatorRotation() public {
        uint256 maxValidators = registry.MAX_VALIDATORS();
        _attestAndWrap(alice, NETUID1, _generatedHotkeys(maxValidators), _splitWeights(maxValidators), 100 ether);

        _attestAndWrap(bob, NETUID1, _generatedHotkeys(maxValidators, 1), _splitWeights(maxValidators), 100 ether);
        vm.snapshotGasLastCall("AlphaVault", "wrap: max-validator rotation");
    }

    /// @dev The costliest unwrap shape: consolidation first rolls the whole rotated-out max-size
    ///      set onto the new one, then the gathered backing is delivered.
    function test_gas_unwrap_maxValidatorRotation() public {
        uint256 maxValidators = registry.MAX_VALIDATORS();
        _attestAndWrap(alice, NETUID1, _generatedHotkeys(maxValidators), _splitWeights(maxValidators), 100 ether);

        _setValidators(NETUID1, _generatedHotkeys(maxValidators, 1), _splitWeights(maxValidators));

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));
        vm.snapshotGasLastCall("AlphaVault", "unwrap: full after max-validator rotation");
    }
}
