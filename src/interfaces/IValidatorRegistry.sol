// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IValidatorRegistry
/// @notice Read interface that AlphaVault consumes to learn which validator hotkeys
///         to stake under, and in what BPS proportions, for a given subnet.
interface IValidatorRegistry {
    /// @notice Returns the per-subnet validator hotkeys and their BPS weights.
    /// @dev    Arrays are equal-length and exactly sized to the attested set; empty when
    ///         the subnet has no attested set. Entries are non-zero, weights sum to 10000,
    ///         and set size is bounded (at most 20) so consumers may iterate freely.
    /// @param  netuid Subnet id.
    function getValidators(uint256 netuid) external view returns (bytes32[] memory hotkeys, uint16[] memory weights);
}
