// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { CloneBase } from "./CloneBase.sol";
import { IStaking, STAKING_PRECOMPILE } from "./interfaces/IStaking.sol";
import { VaultReads } from "./libraries/VaultReads.sol";

/// @title DepositMailbox
/// @notice Per-user deposit mailbox. Receives alpha stake, flushes to the subnet clone.
contract DepositMailbox is CloneBase {
    /// @notice Where this mailbox's deposit aimed at `hotkey` actually sits, following the chain's
    ///         successor edge when a hotkey swap carried it away first.
    /// @dev    A swap moves every coldkey's stake, this mailbox's included, and only the chain
    ///         knows where: the vault's record follows swaps it holds stake through, which says
    ///         nothing about a mailbox waiting on its first flush. Zero `amount` means nothing was
    ///         found on either key.
    /// @param  hotkey   Hotkey the deposit was aimed at.
    /// @param  netuid   Subnet id.
    /// @return foundKey The key the deposit was found under.
    /// @return amount   Alpha sitting there.
    function resolveDeposit(bytes32 hotkey, uint16 netuid) external view returns (bytes32 foundKey, uint256 amount) {
        bytes32 coldkey = VaultReads.coldkeyOf(address(this));
        foundKey = hotkey;
        amount = IStaking(STAKING_PRECOMPILE).getStake(hotkey, coldkey, netuid);
        if (amount == 0) {
            (bool exists, bytes32 next) = IStaking(STAKING_PRECOMPILE).getHotkeySuccessor(hotkey, netuid);
            if (exists && next != hotkey) {
                uint256 moved = IStaking(STAKING_PRECOMPILE).getStake(next, coldkey, netuid);
                if (moved != 0) {
                    foundKey = next;
                    amount = moved;
                }
            }
        }
    }
}
