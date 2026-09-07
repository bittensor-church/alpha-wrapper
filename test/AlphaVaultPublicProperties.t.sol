// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { BackingShortfall } from "src/VaultErrors.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract AlphaVaultPublicPropertiesTest is AlphaVaultTestBase {
    function testFuzz_ClaimPaysTheSoleHoldersGiftWithinOneNativeQuantum(uint256 gift) public {
        gift = bound(gift, 2e9, 1e24);
        _depositAndWrap(alice, NETUID1, 30e9);
        _donateToClone(vault.subnetClone(TOKEN1), gift);

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.claimTao(TOKEN1, payable(alice));
        uint256 paid = alice.balance - before;

        assertEq(paid % 1e9, 0, "native delivery is in whole RAO");
        assertLe(paid, gift, "the gift bounds the payout");
        assertLe(gift - paid, 1e9, "only index and native rounding can remain");
        assertEq(vault.subnetClone(TOKEN1).balance, gift - paid);
    }

    function testFuzz_BackingAcceptsAtMostOneThousandRaoOfMissingStake(uint256 missing) public {
        missing = bound(missing, 0, 2_000);
        _depositAndWrap(alice, NETUID1, 30e9);
        uint256 held = _getVaultStake(hotkey1, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, held - missing);

        assertEq(lens.isBackingIntact(TOKEN1), missing <= 1_000);
        if (missing > 1_000) vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    function testFuzz_DepositAndFullExitLoseOnlyTheConfiguredTransferRounding(uint256 deposit, uint256 loss) public {
        deposit = bound(deposit, 1e9, type(uint64).max);
        loss = bound(loss, 0, 2);
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(10_000));
        MockStaking(STAKING_PRECOMPILE).setTransferStakeRoundingLoss(loss);
        uint256 shares = _depositAndWrap(alice, NETUID1, deposit);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), deposit - 2 * loss, "one loss at each transfer");
        assertEq(vault.totalSupply(TOKEN1), 0);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
    }
}
