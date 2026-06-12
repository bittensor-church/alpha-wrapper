// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { MockStaking } from "./MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// @dev Models the Alpha precompile (0x808): getAlphaPrice(uint16) and simSwapAlphaForTao(uint16,uint64).
contract MockAlpha {
    mapping(uint16 => uint256) private price;

    function setAlphaPrice(uint16 netuid, uint256 priceE18) external {
        price[netuid] = priceE18;
    }

    function getAlphaPrice(uint16 netuid) external view returns (uint256) {
        uint256 p = price[netuid];
        // Unset defaults to 1.0 so price-agnostic tests see alpha == tao.
        return p == 0 ? 1e18 : p;
    }

    /// @dev Returns the same TAO output MockStaking.removeStake pays, so the swap simulation and its
    ///      execution agree by construction. Tests open the spot-vs-output gap that exercises the
    ///      removeStake floor classifier by setting getAlphaPrice independently of the swap rate.
    function simSwapAlphaForTao(uint16, uint64 alpha) external view returns (uint256) {
        uint256 num = MockStaking(STAKING_PRECOMPILE).taoPerAlpha();
        uint256 denom = MockStaking(STAKING_PRECOMPILE).taoPerAlphaDenom();
        // Unset rate defaults to 1:1, matching MockStaking.removeStake.
        if (denom == 0) return alpha;
        return (uint256(alpha) * num) / denom;
    }
}
