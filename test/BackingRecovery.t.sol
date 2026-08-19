// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { ValidatorRegistry } from "src/ValidatorRegistry.sol";
import { IValidatorRegistry } from "src/interfaces/IValidatorRegistry.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// @dev Covers getting a position back once the vault has lost sight of its alpha: anyone pointing
///      it at the key that holds it, and the attesters acknowledging a loss nobody can find.
contract BackingRecoveryTest is AlphaVaultTestBase {
    event BackingRecovered(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 found);
    event HotkeySwapFollowed(uint256 indexed tokenId, bytes32 indexed oldHotkey, bytes32 indexed newHotkey);
    event BackingWrittenDown(uint256 indexed tokenId, uint256 nonce, uint256 located);

    bytes32 internal hotkey5 = keccak256("hotkey5");
    bytes32 internal hotkey6 = keccak256("hotkey6");

    // -------------------- Recovery by naming where the alpha went ----------------

    /// @dev Recovery needs nobody's signature. The alpha sits under the vault's own coldkey, so
    ///      recognising the key that holds it can only raise the located total - which is why
    ///      anyone may do it, the moment they find it.
    function test_RecoverStray_ClearsTheShortfallWithoutAQuorum() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);
        assertFalse(vault.isBackingIntact(TOKEN1), "the loss is visible first");

        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingRecovered(TOKEN1, hotkey4, _getVaultStake(hotkey4, NETUID1));
        vm.prank(bob);
        vault.recoverStray(TOKEN1, 0, hotkey4);

        assertTrue(vault.isBackingIntact(TOKEN1), "the found key accounts for the loss");
        assertApproxEqAbs(vault.totalStake(TOKEN1), 30 ether, 0.01 ether, "backing whole after recovery");
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey4, "the slot points at where its alpha is");
    }

    /// @dev A rotation leaves a fresh nonce standing until something settles. It must not double as
    ///      consent for a loss that happens afterwards and lands nowhere the attesters named.
    function test_RotationThenLaterLoss_IsNotExcused() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        // Only now does the backing leave, down a trail the one-hop resolver cannot walk.
        _buildSwapTrail(NETUID1, hotkey1, 2);

        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev Naming a key holding part of the loss explains part of it, which is not an explanation.
    function test_PartiallyNamedLoss_IsNotExcused() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 lost = _getVaultStake(hotkey1, NETUID1);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, lost / 2);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev Settling spends the attestation, so one signature cannot excuse a later, separate loss.
    function test_SettledAttestation_CannotExcuseTheNextLoss() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vault.rebalance(NETUID1);

        _simulateOffVaultSwap(NETUID1, hotkey4, hotkey5);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    function test_RevertWhen_RecoveringOntoAKeyHoldingNothing() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        vm.expectPartialRevert(AlphaVault.NothingStrayUnder.selector);
        vault.recoverStray(TOKEN1, 0, hotkey5);
    }

    function test_RevertWhen_RecoveringOntoAKeyAnotherSlotHolds() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        vm.expectPartialRevert(AlphaVault.HotkeyClaimedTwice.selector);
        vault.recoverStray(TOKEN1, 0, hotkey2);
    }

    /// @dev A slot that is not short has nothing to recover, so pointing it elsewhere would move
    ///      backing between slots rather than find any.
    function test_RevertWhen_RecoveringOntoAHealthySlot() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        vm.expectRevert(AlphaVault.BackingIntact.selector);
        vault.recoverStray(TOKEN1, 1, hotkey4);
    }

    /// @dev The key has to cover what the slot is owed. A partial find leaves the position short,
    ///      and accepting it would report the rest as backing that is not there.
    function test_RevertWhen_TheFoundKeyDoesNotCoverTheSlot() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, owed / 2);

        vm.expectPartialRevert(AlphaVault.NothingStrayUnder.selector);
        vault.recoverStray(TOKEN1, 0, hotkey4);
    }

    // -------------------- Recovery by acknowledging the loss ---------------------

    /// @dev The acknowledgement does not touch the record - it opens the deposit gate, and only
    ///      after a window in which anyone who can still find the alpha may say so. Holders were
    ///      never shut out: the exit works before it, during it and after it.
    function test_WriteDown_ReopensATokenNobodyCanAccountFor() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice));

        uint256 located = vault.totalStake(TOKEN1);
        vm.expectEmit(true, true, true, true, address(vault));
        emit BackingWrittenDown(TOKEN1, 1, located);
        _writeDown(TOKEN1, located);

        assertGt(vault.depositsOpenFrom(TOKEN1), block.timestamp, "deposits wait out the window");
        _simulateAlphaDeposit(bob, NETUID1, 1 ether);
        vm.expectPartialRevert(AlphaVault.DepositsPaused.selector);
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey1);

        vm.warp(vault.depositsOpenFrom(TOKEN1));
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey1);
        assertGt(vault.balanceOf(bob, TOKEN1), 0, "deposits resume once the window is out");
    }

    /// @dev A validator the attesters dropped while the token was frozen still holds its stake.
    ///      The acknowledgement must not lose it, and the ordinary path must still bring it home.
    function test_WriteDown_KeepsADroppedValidatorsStake() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 dropped = _getVaultStake(hotkey3, NETUID1);
        assertGt(dropped, 0, "the dropped validator must hold something to lose");

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, 0);
        _setValidators(NETUID1, _hotkeys(hotkey2, hotkey4), _weights(5000, 5000));

        uint256 located = vault.totalStake(TOKEN1);
        _writeDown(TOKEN1, located);

        assertEq(vault.totalStake(TOKEN1), located, "the dropped validator's stake still counts");
        assertEq(_getVaultStake(hotkey3, NETUID1), dropped, "and is still sitting where it was");
    }

    /// @dev A write-down settles the record, so it owes the record the swaps its own plan
    ///      followed. Dropping them would re-anchor onto the key the alpha departed and strand what
    ///      the signers were shown as surviving.
    function test_WriteDown_KeepsAFollowedSwapInTheRecord() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 moved = _getVaultStake(hotkey1, NETUID1);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, _subnetColdkey(NETUID1), NETUID1, 0);

        uint256 located = vault.totalStake(TOKEN1);
        _writeDown(TOKEN1, located);

        AlphaVault.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].active, hotkey4, "the record kept the key the swap reached");
        assertEq(slots[0].tracked, moved, "and still expects the alpha sitting there");
        assertEq(vault.totalStake(TOKEN1), located, "the write-down discarded no live backing");
    }

    /// @dev The signers say deposits may resume; they do not say the alpha stopped existing. The
    ///      record therefore keeps what each slot is owed, which is what leaves a premature
    ///      acknowledgement recoverable at all.
    function test_WriteDown_KeepsTheRecordStanding() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 owed = _getVaultStake(hotkey1, NETUID1);
        _buildSwapTrail(NETUID1, hotkey1, 2);

        _writeDown(TOKEN1, 0);

        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, owed, "the slot still knows what it is owed");
        assertFalse(vault.isBackingIntact(TOKEN1), "and still reports itself short");
    }

    function test_WriteDown_RefusedWhileTheRecordStillAccountsForThePosition() public {
        _depositAndWrap(alice, NETUID1, 30 ether);

        IValidatorRegistry.BackingWriteDown memory approval = _approval(TOKEN1, 0);
        bytes[] memory sigs = _sign(_writeDownDigest(registry, approval), signerPks);
        vm.expectRevert(AlphaVault.BackingIntact.selector);
        vault.writeDownBacking(approval, sigs);
    }

    /// @dev An approval signed against a shortfall is refused once someone has recovered it, so a
    ///      stale acknowledgement cannot be spent against a token that no longer needs one.
    function test_WriteDown_VoidOnceTheAlphaIsFound() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        IValidatorRegistry.BackingWriteDown memory approval = _approval(TOKEN1, 0);
        bytes[] memory sigs = _sign(_writeDownDigest(registry, approval), signerPks);

        vault.recoverStray(TOKEN1, 0, hotkey4);

        vm.expectRevert(AlphaVault.BackingIntact.selector);
        vault.writeDownBacking(approval, sigs);
    }

    /// @dev And the other direction: an acknowledgement that turns out to be premature is undone by
    ///      anyone who finds the alpha, which also ends the window it started.
    function test_RecoverStray_UndoesAPrematureWriteDown() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);
        uint256 whole = 30 ether;

        _writeDown(TOKEN1, 0);
        assertGt(vault.depositsOpenFrom(TOKEN1), block.timestamp, "the window is running");

        vm.prank(bob);
        vault.recoverStray(TOKEN1, 0, hotkey4);

        assertEq(vault.depositsOpenFrom(TOKEN1), 0, "finding the alpha ends the window");
        assertTrue(vault.isBackingIntact(TOKEN1), "and restores the record");
        assertApproxEqAbs(vault.totalStake(TOKEN1), whole, 0.01 ether, "with the backing whole again");
    }

    function test_WriteDown_RefusedWhenLessSurvivedThanTheSignersExpected() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        uint256 located = vault.totalStake(TOKEN1);

        IValidatorRegistry.BackingWriteDown memory approval = _approval(TOKEN1, located + 1 ether);
        bytes[] memory sigs = _sign(_writeDownDigest(registry, approval), signerPks);
        vm.expectPartialRevert(AlphaVault.BelowApprovedBacking.selector);
        vault.writeDownBacking(approval, sigs);
    }

    function test_WriteDown_CannotBeReplayedAgainstALaterLoss() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        IValidatorRegistry.BackingWriteDown memory approval = _approval(TOKEN1, 0);
        bytes[] memory sigs = _sign(_writeDownDigest(registry, approval), signerPks);
        vault.writeDownBacking(approval, sigs);

        _buildSwapTrail(NETUID1, hotkey2, 2);
        vm.expectRevert(ValidatorRegistry.StaleNonce.selector);
        vault.writeDownBacking(approval, sigs);
    }

    /// @dev And behind that, the registry refuses a nonce it has already seen even when the record
    ///      it names is current.
    function test_WriteDown_RefusesASpentNonce() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        _writeDown(TOKEN1, 0);

        _buildSwapTrail(NETUID1, hotkey2, 2);
        IValidatorRegistry.BackingWriteDown memory replayed = _approval(TOKEN1, 0);
        replayed.nonce = 1;
        bytes[] memory sigs = _sign(_writeDownDigest(registry, replayed), signerPks);
        vm.expectRevert(ValidatorRegistry.StaleNonce.selector);
        vault.writeDownBacking(replayed, sigs);
    }

    // -------------------- Helpers -------------------------------------------------

    /// @dev Moves the clone's backing between hotkeys with no vault call and no lineage, standing
    ///      in for a swap this subnet recorded nothing for.
    function _simulateOffVaultSwap(uint256 netuid, bytes32 fromHotkey, bytes32 toHotkey) internal {
        bytes32 coldkey = _subnetColdkey(netuid);
        uint256 amount = _getStakeForColdkey(fromHotkey, coldkey, netuid);
        MockStaking(STAKING_PRECOMPILE).setStake(fromHotkey, coldkey, netuid, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(toHotkey, coldkey, netuid, amount);
    }

    /// @dev A swap as the chain records it: the stake moves and the lineage points at it.
    function _simulateFollowedSwap(uint256 netuid, bytes32 fromHotkey, bytes32 toHotkey) internal {
        _simulateOffVaultSwap(netuid, fromHotkey, toHotkey);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(fromHotkey, netuid, toHotkey);
    }

    /// @dev Chains `hops` swaps, leaving the backing at the far tip and the vault able to walk
    ///      only the first edge.
    function _buildSwapTrail(uint256 netuid, bytes32 fromHotkey, uint256 hops) internal returns (bytes32 tip) {
        bytes32 previous = fromHotkey;
        for (uint256 i; i < hops; ++i) {
            tip = keccak256(abi.encode("trail-hop", fromHotkey, i));
            MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(previous, netuid, tip);
            previous = tip;
        }
        _simulateOffVaultSwap(netuid, fromHotkey, tip);
    }
}
