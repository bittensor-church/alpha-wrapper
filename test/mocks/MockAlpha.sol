// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Models the Alpha precompile (0x808) getAlphaPrice(uint16). Price is alpha_price * 1e18.
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
}
