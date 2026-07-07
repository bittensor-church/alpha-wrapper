// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// @dev The vault gates stake moves against the chain's live min-stake threshold, read from the
///      staking precompile's getStakeOperationThreshold(), and falls back to the owner-set
///      minStakeTaoFloor only when that view is unavailable (older runtimes) or reads zero.
contract StakeFloorPrecompileTest is AlphaVaultTestBase {
    MockStaking private staking;

    function setUp() public override {
        super.setUp();
        staking = MockStaking(STAKING_PRECOMPILE);
    }

    // ── effectiveStakeFloor(): chain value, with owner fallback ─────────────────

    function test_EffectiveStakeFloor_ReadsChainThreshold() public {
        staking.setStakeOperationThreshold(7e6);
        assertEq(vault.effectiveStakeFloor(), 7e6, "reads the chain's live threshold");
    }

    function test_EffectiveStakeFloor_FallsBackWhenViewReverts() public {
        staking.setStakeThresholdReverts(true);
        vault.setMinStakeTaoFloor(9e6);
        assertEq(vault.effectiveStakeFloor(), 9e6, "falls back to the owner floor when the view is unavailable");
    }

    function test_EffectiveStakeFloor_FallsBackWhenViewReadsZero() public {
        staking.setStakeThresholdReadsZero(true);
        vault.setMinStakeTaoFloor(9e6);
        assertEq(vault.effectiveStakeFloor(), 9e6, "a zero chain read is not a floor - fall back");
    }

    // A precompile that answers with an unexpected (non-32-byte) payload must not brick the vault:
    // the length guard skips abi.decode and the owner fallback holds, instead of reverting every op.
    function test_EffectiveStakeFloor_FallsBackWhenViewReturnsMalformedData() public {
        staking.setStakeThresholdReturnsShort(true);
        vault.setMinStakeTaoFloor(9e6);
        assertEq(vault.effectiveStakeFloor(), 9e6, "an undecodable return is not a floor - fall back");
    }

    function testFuzz_EffectiveStakeFloor_ReadsAnyNonZeroChainThreshold(uint256 threshold) public {
        threshold = bound(threshold, 1, 100e6);
        staking.setStakeOperationThreshold(threshold);
        assertEq(vault.effectiveStakeFloor(), threshold);
    }

    // ── the chain threshold, not the owner knob, gates a wrap ───────────────────

    // Chain floor above the owner floor: a deposit worth more than the owner floor but below the
    // chain floor is rejected, proving the pre-check follows the chain and not the stored knob.
    function test_RevertWhen_WrapBelowChainThreshold() public {
        staking.setStakeOperationThreshold(10e6); // chain floor 10e6 tao; owner floor stays 2e6
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, 1e18);

        _simulateAlphaDepositHotkey(alice, 99, 5e6, hotkey4); // 5e6 tao: above owner 2e6, below chain 10e6
        vm.prank(alice);
        vm.expectRevert(AlphaVault.DepositTooSmall.selector);
        vault.wrap(alice, 99, hotkey4);
    }

    // The same position clears once the deposit reaches the chain threshold.
    function test_Wrap_SucceedsAtChainThreshold() public {
        staking.setStakeOperationThreshold(10e6);
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, 1e18);

        _simulateAlphaDepositHotkey(alice, 99, 10e6, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);
        assertGt(vault.balanceOf(alice, vault.currentTokenId(99)), 0, "wrap clears at the chain floor");
    }

    // Older runtime (view reverts): the owner floor is the gate, so it must be kept at or above the
    // chain's real floor. Here the chain would accept the deposit but the vault cannot read that.
    function test_RevertWhen_WrapBelowOwnerFallbackFloor() public {
        staking.setStakeThresholdReverts(true); // view reverts...
        staking.setStakeOperationThreshold(1); //  ...while the chain's real floor is tiny
        vault.setMinStakeTaoFloor(10e6); //         owner holds a conservative 10e6
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, 1e18);

        _simulateAlphaDepositHotkey(alice, 99, 5e6, hotkey4);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.DepositTooSmall.selector);
        vault.wrap(alice, 99, hotkey4);
    }

    // The wrap gate is pure numeric input, so fuzz it: at a 1:1 price the deposit's tao value equals
    // the alpha amount, and the gate must track the (fuzzed) chain threshold - reject below, clear at
    // or above - regardless of the lower owner fallback.
    function testFuzz_Wrap_GatesOnChainThreshold(uint256 threshold, uint256 deposit) public {
        threshold = bound(threshold, MIN_STAKE_FLOOR + 1, 100e6); // above the 2e6 owner fallback
        deposit = bound(deposit, 1, 200e6);
        staking.setStakeOperationThreshold(threshold);
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, 1e18);
        _simulateAlphaDepositHotkey(alice, 99, deposit, hotkey4);

        if (deposit < threshold) {
            vm.prank(alice);
            vm.expectRevert(AlphaVault.DepositTooSmall.selector);
            vault.wrap(alice, 99, hotkey4);
        } else {
            _wrapHotkey(alice, 99, hotkey4);
            assertGt(vault.balanceOf(alice, vault.currentTokenId(99)), 0);
        }
    }
}
