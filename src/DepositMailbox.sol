// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { CloneBase } from "./CloneBase.sol";
import { IStaking, STAKING_PRECOMPILE } from "./interfaces/IStaking.sol";
import { VaultReads } from "./libraries/VaultReads.sol";

/// @title DepositMailbox
/// @notice Per-user deposit mailbox. Receives alpha stake, flushes to the subnet clone.
contract DepositMailbox is CloneBase {
    /// @dev Successor edges chain rather than rewrite, so a deposit that slept through several
    ///      swaps sits a few edges away. The walk only reads this mailbox's own balances, so depth
    ///      costs nothing but gas and a decoy trail just ends at zero.
    uint256 private constant MAX_TRAIL_HOPS = 16;

    /// @notice Where this mailbox's deposit aimed at `hotkey` actually sits, following the chain's
    ///         successor trail when hotkey swaps carried it away first.
    /// @dev    A swap moves every coldkey's stake, this mailbox's included, and only the chain
    ///         knows where: the vault's record follows swaps it holds stake through, which says
    ///         nothing about a mailbox waiting on its first flush. Zero `amount` means nothing was
    ///         found along the trail.
    /// @param  hotkey   Hotkey the deposit was aimed at.
    /// @param  netuid   Subnet id.
    /// @return foundKey The key the deposit was found under.
    /// @return amount   Alpha sitting there.
    function resolveDeposit(bytes32 hotkey, uint16 netuid) external view returns (bytes32 foundKey, uint256 amount) {
        bytes32 coldkey = VaultReads.coldkeyOf(address(this));
        bytes32 current = hotkey;
        for (uint256 hops; hops <= MAX_TRAIL_HOPS; ++hops) {
            uint256 balance = IStaking(STAKING_PRECOMPILE).getStake(current, coldkey, netuid);
            if (balance != 0) return (current, balance);
            (bool exists, bytes32 next) = IStaking(STAKING_PRECOMPILE).getHotkeySuccessor(current, netuid);
            if (!exists || next == current) break;
            current = next;
        }
        return (hotkey, 0);
    }
}
