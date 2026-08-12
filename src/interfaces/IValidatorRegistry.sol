// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IValidatorRegistry
/// @notice Read interface that AlphaVault consumes to learn which validator hotkeys
///         to stake under, and in what BPS proportions, for a given subnet.
interface IValidatorRegistry {
    /// @notice Returns the per-subnet validator hotkeys, their BPS weights, and the set's version.
    /// @dev    `hotkeys` and `weights` are equal length, hold 1..64 entries, carry no zero hotkey
    ///         or zero weight, and their weights sum to 10000. A subnet is configured iff the
    ///         returned length is non-zero.
    /// @param  netuid Subnet id.
    /// @return hotkeys Validators to stake this subnet's alpha under.
    /// @return weights Each validator's share of the stake, in basis points.
    /// @return version Increments on every committed set; equal versions mean an unchanged set, so
    ///         callers can skip work that only a membership change could require.
    function getValidators(uint256 netuid)
        external
        view
        returns (bytes32[] memory hotkeys, uint16[] memory weights, uint256 version);
}
