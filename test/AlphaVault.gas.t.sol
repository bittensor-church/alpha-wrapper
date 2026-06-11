// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";

/// forge-config: default.isolate = true
contract AlphaVaultGasTest is AlphaVaultTestBase {
    function test_gas_processDeposit_firstDeposit() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        vm.snapshotGasLastCall("AlphaVault", "processDeposit: first");
    }

    function test_gas_processDeposit_subsequentDeposit() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);

        _simulateAlphaDeposit(bob, NETUID1, 5 ether);
        _processDeposit(bob, NETUID1);
        vm.snapshotGasLastCall("AlphaVault", "processDeposit: subsequent");
    }

    function test_gas_withdraw_partial() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.prank(alice);
        vault.withdraw(TOKEN1, shares / 2, _toSubstrate(alice), 0);
        vm.snapshotGasLastCall("AlphaVault", "withdraw: partial");
    }

    function test_gas_withdraw_full() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.prank(alice);
        vault.withdraw(TOKEN1, shares, _toSubstrate(alice), 0);
        vm.snapshotGasLastCall("AlphaVault", "withdraw: full");
    }

    function test_gas_withdrawForTao_partialTailAboveFloor() public {
        _setRemoveStakeRate(1, 1);
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, shares / 2, 0);
        vm.snapshotGasLastCall("AlphaVault", "withdrawForTao: partial tail above floor");
    }

    function test_gas_withdrawForTao_subFloorTailShave() public {
        _setRemoveStakeRate(1, 1);
        _simulateAlphaDeposit(alice, NETUID1, 100 ether);
        _processDeposit(alice, NETUID1);

        uint256 total = _setVaultStakes(NETUID1, 60 ether, 0, 40 ether);
        // The 1e6 tail on hotkey3 is sub-floor and forces the grow-and-shave branch.
        uint256 shares = _sharesForExactAssets(TOKEN1, 60 ether + 1e6, total);

        vm.prank(alice);
        vault.withdrawForTao(TOKEN1, shares, 0);
        vm.snapshotGasLastCall("AlphaVault", "withdrawForTao: sub-floor tail shave");
    }

    function test_gas_rebalance() public {
        _simulateAlphaDeposit(alice, NETUID1, 100 ether);
        _processDeposit(alice, NETUID1);

        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(5000, 3000, 2000));

        vault.rebalance(NETUID1);
        vm.snapshotGasLastCall("AlphaVault", "rebalance: after registry weight update");
    }
}
