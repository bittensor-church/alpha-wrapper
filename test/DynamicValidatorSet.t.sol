// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";

/// @dev Tests vault flows against validator sets of many sizes: a deposit spreads across ten
///      weighted validators, an unwrap pays the full backing back out of the split, and an
///      existing position follows the attested set cleanly when it grows or shrinks.
contract DynamicValidatorSetTest is AlphaVaultTestBase {
    function _tenWeights() private pure returns (uint16[] memory weights) {
        weights = new uint16[](10);
        weights[0] = 1900;
        weights[1] = 1700;
        weights[2] = 1500;
        weights[3] = 1300;
        weights[4] = 1100;
        weights[5] = 900;
        weights[6] = 700;
        weights[7] = 400;
        weights[8] = 300;
        weights[9] = 200;
    }

    function test_Wrap_SpreadsDepositAcrossTenWeightedValidators() public {
        bytes32[] memory validators = _generatedHotkeys(10);
        uint16[] memory weights = _tenWeights();

        vm.recordLogs();
        _attestAndWrap(alice, NETUID1, validators, weights, 100 ether);

        assertLe(_countRebalancedLogs(vm.getRecordedLogs()), 9, "alignment needs at most count-1 moves");
        assertEq(vault.totalStake(TOKEN1), 100 ether);
        for (uint256 i = 0; i < 10; i++) {
            assertEq(_getVaultStake(validators[i], NETUID1), _weighted(100 ether, weights[i]));
        }
    }

    function test_Unwrap_PaysFullBackingFromTenValidators() public {
        bytes32[] memory validators = _generatedHotkeys(10);
        _attestAndWrap(alice, NETUID1, validators, _tenWeights(), 100 ether);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        bytes32 aliceColdkey = _toSubstrate(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceColdkey);

        uint256 received;
        for (uint256 i = 0; i < 10; i++) {
            received += _getStakeForColdkey(validators[i], aliceColdkey, NETUID1);
        }
        assertEq(received, 100 ether, "full backing delivered");
        assertEq(vault.totalStake(TOKEN1), 0);
        assertEq(vault.balanceOf(alice, TOKEN1), 0);
    }

    function test_Rebalance_ConsolidatesWhenTenValidatorSetShrinksToTwo() public {
        bytes32[] memory validators = _generatedHotkeys(10);
        _attestAndWrap(alice, NETUID1, validators, _splitWeights(10), 100 ether);

        _setValidators(NETUID1, _hotkeys(validators[0], validators[1]), _weights(6000, 4000));
        vault.rebalance(NETUID1);

        for (uint256 i = 2; i < 10; i++) {
            assertEq(_getVaultStake(validators[i], NETUID1), 0, "rotated-out slot drained");
        }
        assertEq(vault.totalStake(TOKEN1), 100 ether, "total conserved across the roll");
        assertEq(_getVaultStake(validators[0], NETUID1), 60 ether);
        assertEq(_getVaultStake(validators[1], NETUID1), 40 ether);

        bytes32[] memory seen = vault.lastSeenHotkeys(TOKEN1);
        assertEq(seen.length, 2, "remembered set shrunk with the attested set");
        assertEq(seen[0], validators[0]);
        assertEq(seen[1], validators[1]);
    }

    function test_Rebalance_SpreadsPositionWhenSetGrowsToTen() public {
        bytes32[] memory validators = _generatedHotkeys(10);
        _attestAndWrap(alice, NETUID1, _hotkeys(validators[0], validators[1]), _weights(6000, 4000), 100 ether);

        uint16[] memory weights = _tenWeights();
        _setValidators(NETUID1, validators, weights);
        vault.rebalance(NETUID1);

        for (uint256 i = 0; i < 10; i++) {
            assertEq(_getVaultStake(validators[i], NETUID1), _weighted(100 ether, weights[i]));
        }
        assertEq(vault.lastSeenHotkeys(TOKEN1).length, 10, "remembered set grew with the attested set");
    }

    function testFuzz_WrapUnwrapRoundTripAcrossSetSizes(uint8 rawCount, uint256 amount) public {
        uint256 count = bound(rawCount, 1, registry.MAX_VALIDATORS());
        amount = bound(amount, MIN_STAKE_FLOOR, 1e24);

        bytes32[] memory validators = _generatedHotkeys(count);
        _attestAndWrap(alice, NETUID1, validators, _splitWeights(count), amount);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        assertGt(shares, 0);
        assertEq(vault.totalStake(TOKEN1), amount, "wrap conserves the deposit across the set");

        bytes32 aliceColdkey = _toSubstrate(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceColdkey);

        uint256 received;
        for (uint256 i = 0; i < count; i++) {
            received += _getStakeForColdkey(validators[i], aliceColdkey, NETUID1);
        }
        assertEq(received, amount, "full round trip returns the deposit");
        assertEq(vault.totalStake(TOKEN1), 0);
    }
}
