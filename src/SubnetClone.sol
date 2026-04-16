// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { CloneBase } from "./CloneBase.sol";
import { IStaking, STAKING_PRECOMPILE } from "./interfaces/IStaking.sol";

/// @title SubnetClone
/// @notice Per-subnet clone that holds alpha under an isolated coldkey.
contract SubnetClone is CloneBase {
    /// @notice Move alpha held by this clone between two hotkeys on the same subnet.
    /// @dev    No-op when `amount == 0`. Callable only by the wrapper (AlphaVault).
    /// @param  fromHotkey Hotkey the stake currently sits under.
    /// @param  toHotkey   Hotkey the stake should be moved to.
    /// @param  netuid     Subnet id (used as both origin and destination netuid).
    /// @param  amount     Alpha amount to move.
    function moveStake(bytes32 fromHotkey, bytes32 toHotkey, uint256 netuid, uint256 amount) external onlyWrapper {
        if (amount > 0) {
            IStaking(STAKING_PRECOMPILE).moveStake(fromHotkey, toHotkey, netuid, netuid, amount);
        }
    }
}
