// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

interface IAlpha {
    /// @notice Spot TAO per alpha, scaled by 1e18.
    function getAlphaPrice(uint16 netuid) external view returns (uint256);

    /// @notice Post-fee, post-slippage TAO output in RAO for `alpha` RAO; used by partial-unstake validation.
    /// @dev A rejected simulation consumes all forwarded gas. Avoid inputs the pool cannot price.
    function simSwapAlphaForTao(uint16 netuid, uint64 alpha) external view returns (uint256);
}

address constant ALPHA_PRECOMPILE = 0x0000000000000000000000000000000000000808;
