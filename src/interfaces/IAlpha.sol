// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAlpha
/// @notice Interface for the Bittensor alpha precompile on EVM.
/// @dev Precompile lives at 0x0000000000000000000000000000000000000808.
interface IAlpha {
    /// @return alpha_price scaled by 1e18 (TAO-RAO per alpha-RAO).
    function getAlphaPrice(uint16 netuid) external view returns (uint256);

    /// @notice Simulate unstaking `alpha` rao on `netuid`.
    /// @return tao_out TAO-RAO the swap would pay out, net of fee and slippage — the value
    ///         subtensor floor-checks when validating a `removeStake`.
    function simSwapAlphaForTao(uint16 netuid, uint64 alpha) external view returns (uint256);
}

/// @dev Alpha precompile address on Bittensor EVM.
address constant ALPHA_PRECOMPILE = 0x0000000000000000000000000000000000000808;
