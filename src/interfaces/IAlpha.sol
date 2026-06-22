// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAlpha
/// @notice Interface for the Bittensor alpha precompile on EVM.
interface IAlpha {
    /// @notice Spot alpha price for a subnet in TAO, scaled by 1e18.
    function getAlphaPrice(uint16 netuid) external view returns (uint256);
}

address constant ALPHA_PRECOMPILE = 0x0000000000000000000000000000000000000808;
