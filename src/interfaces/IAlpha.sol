// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAlpha
/// @notice Interface for the Bittensor alpha precompile on EVM.
interface IAlpha {
    /// @notice Spot alpha price for a subnet in TAO, scaled by 1e18.
    function getAlphaPrice(uint16 netuid) external view returns (uint256);

    /// @notice Simulated post-fee, post-slippage TAO output (RAO) of selling `alpha` RAO - the
    ///         number the chain itself validates partial unstakes against.
    /// @dev    Rejected simulations surface as EVM errors that consume all forwarded gas, so
    ///         callers must keep this off inputs the pool cannot price.
    function simSwapAlphaForTao(uint16 netuid, uint64 alpha) external view returns (uint256);
}

address constant ALPHA_PRECOMPILE = 0x0000000000000000000000000000000000000808;
