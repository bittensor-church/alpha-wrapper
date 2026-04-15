// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IValidatorRegistry
/// @notice Interface for the validator registry that stores preferred validators per subnet
///         with target allocation weights. Off-chain bot selects validators (e.g. by APY)
///         and pushes hotkeys + weights here. AlphaVault reads this to decide stake distribution.
interface IValidatorRegistry {
    /// @notice Returns the preferred validator hotkeys and their target weights for a subnet.
    /// @param netuid The subnet ID.
    /// @return hotkeys Array of validator hotkeys (up to 3).
    /// @return weights Target allocation in BPS (basis points, sum = 10000).
    /// @return count Number of valid entries.
    function getValidators(uint256 netuid)
        external
        view
        returns (bytes32[3] memory hotkeys, uint16[3] memory weights, uint8 count);

    /// @notice Whether the registry has validators set for a subnet.
    function hasValidators(uint256 netuid) external view returns (bool);
}
