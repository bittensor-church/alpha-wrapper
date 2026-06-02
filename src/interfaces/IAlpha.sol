// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAlpha
/// @notice Interface for the Bittensor alpha precompile on EVM.
/// @dev Precompile lives at 0x0000000000000000000000000000000000000808.
interface IAlpha {
    /// @return alpha_price scaled by 1e18 (TAO-RAO per alpha-RAO).
    function getAlphaPrice(uint16 netuid) external view returns (uint256);
}

/// @dev Alpha precompile address on Bittensor EVM.
address constant ALPHA_PRECOMPILE = 0x0000000000000000000000000000000000000808;
