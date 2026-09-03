// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev The widest validator set any implementation may return; AlphaVault sizes its
///      per-hotkey loops and gas expectations against this bound.
uint256 constant MAX_VALIDATORS = 64;

/// @title IValidatorRegistry
/// @notice Read interface that AlphaVault consumes to learn which validator hotkeys
///         to stake under, and in what BPS proportions, for a given subnet.
interface IValidatorRegistry {
    /// @notice Returns the per-subnet validator hotkeys and their BPS weights.
    /// @dev    `hotkeys` and `weights` are equal length and hold 1..64 entries, with no zero hotkey
    ///         and no zero weight; the weights sum to 10000. A subnet is configured iff the returned
    ///         length is non-zero.
    /// @param  netuid Subnet id.
    function getValidators(uint256 netuid) external view returns (bytes32[] memory hotkeys, uint16[] memory weights);
}
