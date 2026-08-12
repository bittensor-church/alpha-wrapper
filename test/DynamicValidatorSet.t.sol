// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { CHAIN_MIN_STAKE } from "./mocks/MockStaking.sol";

/// @dev A subnet's validator set is any size from 1 to 64 and changes size between calls. Three is
///      the expected size; these tests hold the two ends and the transitions between them, where the
///      set outgrows a single batched balance read and where a dropped validator's balance is too
///      large to strand yet too small to spread.
contract DynamicValidatorSetTest is AlphaVaultTestBase {
    /// @dev Deposit sized so that after one of 64 validators is dropped, its balance clears the
    ///      chain's floor many times over while each remaining slot's share of it falls well under
    ///      the floor. Spreading the drop is impossible; moving it whole is the only way out.
    uint256 private constant UNSPREADABLE_DEPOSIT = 1e9;

    function test_Wrap_SpreadsAcrossFullValidatorCap() public {
        bytes32[] memory hks = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _depositAndWrap(alice, NETUID1, 10 ether);

        uint16[] memory wts = _evenWeights(MAX_VALIDATORS);
        for (uint256 i; i < MAX_VALIDATORS; ++i) {
            assertEq(_getVaultStake(hks[i], NETUID1), _weighted(10 ether, wts[i]), "slot off its weight");
        }
        assertEq(vault.totalStake(TOKEN1), 10 ether);
    }

    function test_Wrap_StakesWholePositionOnSingleValidator() public {
        bytes32[] memory hks = _setValidatorCount(NETUID1, 1);
        _depositAndWrap(alice, NETUID1, 10 ether);

        assertEq(_getVaultStake(hks[0], NETUID1), 10 ether);
        assertEq(vault.totalStake(TOKEN1), 10 ether);
    }

    function test_Rebalance_ShrinkFromCapLeavesNoStaleTail() public {
        bytes32[] memory wide = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _depositAndWrap(alice, NETUID1, 10 ether);

        bytes32[] memory narrow = _setValidatorCount(NETUID1, 3);
        vault.rebalance(NETUID1);

        for (uint256 i = 3; i < MAX_VALIDATORS; ++i) {
            assertEq(_getVaultStake(wide[i], NETUID1), 0, "dropped validator still funded");
        }
        assertEq(vault.totalStake(TOKEN1), 10 ether, "total conserved across the shrink");
        assertEq(vault.lastSeenHotkeys(TOKEN1).length, 3, "remembered set carries no stale tail");

        uint16[] memory wts = _evenWeights(3);
        for (uint256 i; i < 3; ++i) {
            assertEq(_getVaultStake(narrow[i], NETUID1), _weighted(10 ether, wts[i]));
        }
    }

    function test_Rebalance_GrowToCapSpreadsAcrossFullSet() public {
        _setValidatorCount(NETUID1, 3);
        _depositAndWrap(alice, NETUID1, 10 ether);

        bytes32[] memory wide = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        vault.rebalance(NETUID1);

        uint16[] memory wts = _evenWeights(MAX_VALIDATORS);
        for (uint256 i; i < MAX_VALIDATORS; ++i) {
            assertEq(_getVaultStake(wide[i], NETUID1), _weighted(10 ether, wts[i]), "slot off its weight");
        }
        assertEq(vault.totalStake(TOKEN1), 10 ether);
        assertEq(vault.lastSeenHotkeys(TOKEN1).length, MAX_VALIDATORS);
    }

    /// @dev The case weight alignment cannot serve: alignment moves only the smaller of a surplus and
    ///      a deficit, and here every deficit is below the floor, so it would skip every move and
    ///      leave a balance many times the floor sitting on a validator the set no longer names.
    function test_Rebalance_DrainsDroppedBalanceTooSmallToSpread() public {
        bytes32[] memory wide = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _depositAndWrap(alice, NETUID1, UNSPREADABLE_DEPOSIT);

        uint256 dropped = _getVaultStake(wide[MAX_VALIDATORS - 1], NETUID1);
        assertGt(dropped, CHAIN_MIN_STAKE, "the dropped balance must be worth moving");
        assertLt(dropped / (MAX_VALIDATORS - 1), CHAIN_MIN_STAKE, "and impossible to spread");

        _setValidatorCount(NETUID1, MAX_VALIDATORS - 1);
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(wide[MAX_VALIDATORS - 1], NETUID1), 0, "dropped validator drained");
        assertEq(vault.totalStake(TOKEN1), UNSPREADABLE_DEPOSIT, "total conserved");
        assertEq(vault.lastSeenHotkeys(TOKEN1).length, MAX_VALIDATORS - 1, "nothing left to remember");
    }

    /// @dev A full-set rotation puts 128 slots in play, past the 64 the chain reads in one call, so
    ///      the balances arrive over two batched reads and every one must land on its own slot.
    function test_Rebalance_ReadsUnionWiderThanOneBatch() public {
        bytes32[] memory first = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _depositAndWrap(alice, NETUID1, 10 ether);

        bytes32[] memory second = _hotkeysFrom("second-wave", MAX_VALIDATORS);
        _setValidators(NETUID1, second, _evenWeights(MAX_VALIDATORS));

        // The union is 128 slots before a single balance has been read.
        assertEq(vault.totalStake(TOKEN1), 10 ether, "union read prices the whole position");

        vault.rebalance(NETUID1);

        for (uint256 i; i < MAX_VALIDATORS; ++i) {
            assertEq(_getVaultStake(first[i], NETUID1), 0, "old set fully drained");
        }
        assertEq(_vaultStakeAcross(second, NETUID1), 10 ether, "whole position landed on the new set");
        assertEq(vault.lastSeenHotkeys(TOKEN1).length, MAX_VALIDATORS);
    }

    /// @dev A weights-only re-attestation moves the version without moving membership, which is the
    ///      commonest commit of all. It must settle on the new weights and count the set once.
    function test_Rebalance_SettlesWeightsOnlyReattestation() public {
        bytes32[] memory hks = _setValidatorCount(NETUID1, 3);
        _depositAndWrap(alice, NETUID1, 10 ether);

        uint16[] memory skewed = _weights(8000, 1000, 1000);
        _setValidators(NETUID1, hks, skewed);
        vault.rebalance(NETUID1);

        for (uint256 i; i < 3; ++i) {
            assertEq(_getVaultStake(hks[i], NETUID1), _weighted(10 ether, skewed[i]), "slot off its new weight");
        }
        assertEq(vault.totalStake(TOKEN1), 10 ether, "the set must be counted once, not twice");
        assertEq(vault.lastSeenHotkeys(TOKEN1).length, 3);
    }

    /// @dev A swap that leaves the set the same size must not read as an unchanged set: the fast
    ///      path keys on the registry's version, and the length alone cannot tell the two apart.
    function test_Rebalance_DrainsSameSizeMembershipSwap() public {
        bytes32[] memory original = _setValidatorCount(NETUID1, 3);
        _depositAndWrap(alice, NETUID1, 10 ether);

        bytes32[] memory swapped = _hotkeys(original[0], original[1], hotkey4);
        _setValidators(NETUID1, swapped, _evenWeights(3));
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(original[2], NETUID1), 0, "the swapped-out validator must be drained");
        assertEq(_vaultStakeAcross(swapped, NETUID1), 10 ether, "whole position on the new set");
        assertEq(vault.lastSeenHotkeys(TOKEN1).length, 3, "and nothing left to remember");
    }

    /// @dev Between a registry commit and the next vault call the whole position sits on validators
    ///      the set no longer names. The TAO rail must price and sell it from there.
    function test_UnwrapForTao_ExitsFullyRotatedPosition() public {
        _setValidatorCount(NETUID1, 3);
        _depositAndWrap(alice, NETUID1, 10 ether);

        // Disjoint from the validator fixtures, so nothing the position holds is still attested.
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 10 ether, "rotated-out position sold in full");
        assertEq(vault.totalStake(TOKEN1), 0);
    }

    /// @dev A price the EVM reads as zero carries no bound, so the drain must attempt the move and
    ///      let the chain's own full-precision floor decide - refusing on a zero read would freeze
    ///      every rotation on a sub-quantum subnet.
    function test_Rebalance_DrainsRotationAtUnreadablePrice() public {
        bytes32[] memory wide = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _depositAndWrap(alice, NETUID1, 10 ether);
        _setAlphaPriceReadsZero(NETUID1);
        assertEq(_alphaPriceRead(NETUID1), 0, "the read must be unusable for this to mean anything");

        _setValidatorCount(NETUID1, MAX_VALIDATORS - 1);
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(wide[MAX_VALIDATORS - 1], NETUID1), 0, "dropped validator drained");
        assertEq(vault.totalStake(TOKEN1), 10 ether);
    }

    /// @dev At 64 validators an even split of a small position puts every target under the chain's
    ///      floor, so no move is legal. The position must stay whole and fully priced rather than
    ///      the call failing - the spread is best-effort, the accounting is not.
    function test_Wrap_KeepsSmallPositionWholeWhenTargetsFallBelowFloor() public {
        bytes32[] memory hks = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        uint256 deposit = 4 * CHAIN_MIN_STAKE;
        assertLt(deposit / MAX_VALIDATORS, CHAIN_MIN_STAKE, "no per-slot target may be movable");

        _depositAndWrap(alice, NETUID1, deposit);

        assertEq(_getVaultStake(hks[0], NETUID1), deposit, "position stays where it landed");
        assertEq(vault.totalStake(TOKEN1), deposit, "and is fully priced");
    }

    // Every slot's target clears the chain's floor at the widest set, so the spread is always legal
    // and these can assert on placement rather than only on conservation; MinStakeFloor covers the
    // sub-floor edge.
    uint256 private constant MIN_SPREADABLE = 1 ether;
    uint256 private constant MAX_DEPOSIT = 1_000 ether;

    function testFuzz_Wrap_SpreadsAcrossAnyValidatorCount(uint256 count, uint256 amount) public {
        count = bound(count, 1, MAX_VALIDATORS);
        amount = bound(amount, MIN_SPREADABLE, MAX_DEPOSIT);

        bytes32[] memory hks = _setValidatorCount(NETUID1, count);
        _depositAndWrap(alice, NETUID1, amount);

        uint16[] memory wts = _evenWeights(count);
        uint256 assigned;
        for (uint256 i; i < count - 1; ++i) {
            assertEq(_getVaultStake(hks[i], NETUID1), _weighted(amount, wts[i]), "slot off its weight");
            assigned += _weighted(amount, wts[i]);
        }
        assertEq(_getVaultStake(hks[count - 1], NETUID1), amount - assigned, "last slot absorbs the remainder");
        assertEq(vault.totalStake(TOKEN1), amount);
    }

    function testFuzz_Rebalance_RotationPreservesTotal(uint256 fromCount, uint256 toCount, uint256 amount) public {
        fromCount = bound(fromCount, 1, MAX_VALIDATORS);
        toCount = bound(toCount, 1, MAX_VALIDATORS);
        amount = bound(amount, MIN_SPREADABLE, MAX_DEPOSIT);

        _setValidatorCount(NETUID1, fromCount);
        _depositAndWrap(alice, NETUID1, amount);

        // A disjoint set of the requested size, so every old validator is dropped at once.
        bytes32[] memory rotated = _hotkeysFrom("rotated", toCount);
        _setValidators(NETUID1, rotated, _evenWeights(toCount));

        vault.rebalance(NETUID1);

        assertEq(_vaultStakeAcross(rotated, NETUID1), amount, "whole position moved to the new set");
        assertEq(vault.totalStake(TOKEN1), amount);
        assertEq(vault.lastSeenHotkeys(TOKEN1).length, toCount, "no drained slot stays remembered");
    }

    function testFuzz_WrapUnwrapRoundTrip(uint256 count, uint256 amount, uint256 burnBps) public {
        count = bound(count, 1, MAX_VALIDATORS);
        amount = bound(amount, MIN_SPREADABLE, MAX_DEPOSIT);
        burnBps = bound(burnBps, 1, BPS_BASE);

        bytes32[] memory hks = _setValidatorCount(NETUID1, count);
        _depositAndWrap(alice, NETUID1, amount);

        uint256 shares = vault.balanceOf(alice, TOKEN1) * burnBps / BPS_BASE;
        (uint256 previewAlpha,) = vault.previewUnwrap(TOKEN1, shares);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice));

        assertEq(_stakeAcross(hks, _toSubstrate(alice), NETUID1), previewAlpha, "delivery matches the quote");
        assertEq(vault.totalStake(TOKEN1), amount - previewAlpha, "only the delivered alpha left the vault");
    }
}
