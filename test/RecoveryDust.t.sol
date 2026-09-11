// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { BackingUnchanged, NothingToRecover } from "src/VaultErrors.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { MockStaking, CHAIN_MIN_STAKE } from "./mocks/MockStaking.sol";

contract RecoveryDustTest is AlphaVaultTestBase {
    uint256 private constant EXPECTED = 30e6;
    uint256 private constant DUST = CHAIN_MIN_STAKE / 2;

    function _missingPosition() private returns (bytes32[] memory tips) {
        _depositAndWrap(alice, NETUID1, EXPECTED);
        bytes32[] memory keys = _hotkeys(hotkey1, hotkey2, hotkey3);
        tips = new bytes32[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            tips[i] = _buildSwapTrail(NETUID1, keys[i], 2);
        }
    }

    function _plant(bytes32 key, uint256 amount) private {
        MockStaking(STAKING_PRECOMPILE).setStake(key, _subnetColdkey(NETUID1), NETUID1, amount);
        _simulateHotkeyOwnerPresent(key);
    }

    function _emptyRecovery() private returns (bytes32[] memory tips, uint256 deadline) {
        tips = _missingPosition();
        vault.syncBacking(TOKEN1);
        deadline = lens.frozenUntil(TOKEN1);
        assertEq(_parkedStake(NETUID1), 0);
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, EXPECTED);
    }

    function test_SubFloorStray_CannotChangeTheDeclaredObligation() public {
        _missingPosition();
        _plant(hotkey4, DUST);
        vault.syncBacking(TOKEN1);
        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, hotkey4);
        assertEq(lens.frozenUntil(TOKEN1), block.timestamp + vault.recoveryWindow());
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, EXPECTED);
        assertEq(_parkedStake(NETUID1), 0);
        assertEq(_getVaultStake(hotkey4, NETUID1), DUST);
    }

    function test_DustDuringEmptyRecovery_DoesNotBlockExpiryOrBurningWorthlessShares() public {
        (, uint256 deadline) = _emptyRecovery();
        _plant(hotkey1, DUST);
        vm.warp(deadline - 1);
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
        assertEq(lens.frozenUntil(TOKEN1), deadline);
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, EXPECTED);

        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, EXPECTED, 0);
        vault.syncBacking(TOKEN1);
        assertEq(_getVaultStake(hotkey1, NETUID1), DUST);
        assertEq(lens.totalStake(TOKEN1), 0);
        assertEq(lens.frozenUntil(TOKEN1), 0);
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        assertEq(vault.totalSupply(TOKEN1), 0);
    }

    function test_ParkedPile_CollectsDustWithoutExtendingTheWindow() public {
        (bytes32[] memory tips, uint256 deadline) = _emptyRecovery();
        uint256 recovered = _getVaultStake(tips[2], NETUID1);
        vault.recoverStray(TOKEN1, tips[2]);
        _plant(hotkey1, DUST);
        vault.syncBacking(TOKEN1);
        assertEq(_parkedStake(NETUID1), recovered + DUST);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(lens.missingStake(TOKEN1), EXPECTED - recovered - DUST);
        assertEq(lens.frozenUntil(TOKEN1), deadline);
    }

    function test_AboveFloorReturnAtExpiry_CollectsPreviouslySkippedDust() public {
        (bytes32[] memory tips, uint256 deadline) = _emptyRecovery();
        _plant(hotkey1, DUST);
        uint256 recovered = _getVaultStake(tips[2], NETUID1);
        _simulateOffVaultSwap(NETUID1, tips[2], hotkey3);
        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, EXPECTED, recovered + DUST);
        vault.syncBacking(TOKEN1);
        assertEq(_parkedStake(NETUID1), recovered + DUST);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(_getVaultStake(hotkey3, NETUID1), 0);
    }

    function test_PriceRiseAtExpiry_CollectsDustThatNowClearsTheFloor() public {
        _missingPosition();
        _plant(hotkey1, DUST);
        vault.syncBacking(TOKEN1);
        assertEq(_parkedStake(NETUID1), 0);
        uint256 deadline = lens.frozenUntil(TOKEN1);
        _setAlphaPrice(NETUID1, 3e18);
        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, EXPECTED, DUST);
        vault.syncBacking(TOKEN1);
        assertEq(_parkedStake(NETUID1), DUST, "newly movable backing must not be written off");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
    }

    function test_PriceFallDuringRecovery_DoesNotLetDustBlockTheParkedBalance() public {
        (bytes32[] memory tips, uint256 deadline) = _emptyRecovery();
        uint256 recovered = _getVaultStake(tips[2], NETUID1);
        vault.recoverStray(TOKEN1, tips[2]);
        _plant(hotkey1, DUST);
        _setAlphaPrice(NETUID1, 0.1e18);
        assertLt(recovered / 10, CHAIN_MIN_STAKE);
        vm.warp(deadline);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), recovered, "the entire parked balance remains backing");
        assertEq(_getVaultStake(hotkey1, NETUID1), DUST);
        // A subsequent price recovery permits the holder's normal full alpha exit.
        _setAlphaPrice(NETUID1, 1e18);
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), recovered);
        assertEq(_getStake(vault.parkingHotkey(), alice, NETUID1), recovered);
    }

    function test_UnknownRoundedPrice_DoesNotAuthorizeADustWriteOff() public {
        (, uint256 deadline) = _emptyRecovery();
        _plant(hotkey1, DUST);
        _setAlphaPriceReadsZero(NETUID1);
        vm.warp(deadline);
        vm.expectRevert(bytes("MockStaking: AmountTooLow"));
        vault.syncBacking(TOKEN1);
        assertEq(lens.frozenUntil(TOKEN1), deadline);
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, EXPECTED);
        assertEq(_getVaultStake(hotkey1, NETUID1), DUST);
    }

    function test_FailedAboveFloorCollection_DoesNotUseTheDustException() public {
        (, uint256 deadline) = _emptyRecovery();
        _plant(hotkey1, CHAIN_MIN_STAKE);
        _plant(hotkey2, DUST);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeReverts(true);
        vm.warp(deadline);
        vm.expectRevert(bytes("MockStaking: moveStake reverted"));
        vault.syncBacking(TOKEN1);
        assertEq(lens.frozenUntil(TOKEN1), deadline);
        assertEq(_parkedStake(NETUID1), 0);
        assertEq(_getVaultStake(hotkey1, NETUID1), CHAIN_MIN_STAKE);
        assertEq(_getVaultStake(hotkey2, NETUID1), DUST);
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, EXPECTED);
    }

    function _smallSet(uint256 count, uint256 dust, bool movable) private returns (uint256 located) {
        uint16 netuid = 9;
        _setRegBlock(netuid, 400);
        bytes32[] memory keys = _setValidatorCount(netuid, count);
        _simulateAlphaDepositHotkey(alice, netuid, 100e6, keys[0]);
        _wrapHotkey(alice, netuid, keys[0]);
        uint256 tokenId = vault.currentTokenId(netuid);
        bytes32 coldkey = _subnetColdkey(netuid);
        for (uint256 i; i < count; ++i) {
            uint256 balance = movable && i == count - 1 ? CHAIN_MIN_STAKE : dust;
            MockStaking(STAKING_PRECOMPILE).setStake(keys[i], coldkey, netuid, balance);
            located += balance;
        }
        vault.syncBacking(tokenId);
        assertEq(vault.recordedSlots(tokenId)[0].tracked, 100e6);
        assertEq(_parkedStake(netuid), movable ? located : 0);
        uint256 deadline = lens.frozenUntil(tokenId);
        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(tokenId, 100e6, movable ? located : 0);
        vault.syncBacking(tokenId);
        assertEq(lens.totalStake(tokenId), movable ? located : 0);
        for (uint256 i; i < count; ++i) {
            assertEq(_getVaultStake(keys[i], netuid), movable ? 0 : dust);
        }
    }

    function test_TenDustBalances_DoNotBlockWriteOffEvenWhenTheirSumExceedsTheFloor() public {
        uint256 located = _smallSet(10, CHAIN_MIN_STAKE - 1, false);
        assertGt(located, CHAIN_MIN_STAKE, "the combined dust exceeds the floor even though each balance does not");
    }

    function test_OneBalanceAtTheFloor_CollectsAllNineDustBalances() public {
        _smallSet(10, CHAIN_MIN_STAKE - 1, true);
    }

    function testFuzz_SmallSets_OnlySkipIndividuallySubFloorBalances(uint256 rawCount, uint256 rawDust, bool movable)
        public
    {
        _smallSet(
            bound(rawCount, 2, 10), bound(rawDust, VaultReads.TRACKED_SLACK_RAO + 1, CHAIN_MIN_STAKE - 1), movable
        );
    }
}
