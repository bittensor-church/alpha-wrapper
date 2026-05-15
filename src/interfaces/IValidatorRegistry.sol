// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IValidatorRegistry
/// @notice Read interface that AlphaVault consumes to learn which validator hotkeys
///         to stake under, and in what BPS proportions, for a given subnet.
interface IValidatorRegistry {
    /// @notice Returns the per-subnet validator hotkeys and their BPS weights.
    /// @dev    Returned arrays are packed from index 0: populated entries occupy
    ///         indices `0..count-1`, trailing entries are zero. Callers derive count
    ///         as the index of the first zero weight. A subnet is configured iff
    ///         `weights[0] > 0`; weights sum to 10000 across populated entries.
    /// @param  netuid Subnet id.
    function getValidators(uint256 netuid) external view returns (bytes32[3] memory hotkeys, uint16[3] memory weights);
}
