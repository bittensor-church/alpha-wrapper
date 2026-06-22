// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockAlpha {
    uint256 private constant DEFAULT_PRICE_E18 = 1e18;
    mapping(uint16 => uint256) private _alphaPriceE18;
    mapping(uint16 => bool) private _isSet;

    function setAlphaPrice(uint16 netuid, uint256 alphaPriceE18) external {
        _alphaPriceE18[netuid] = alphaPriceE18;
        _isSet[netuid] = true;
    }

    /// @notice EVM oracle read. Returns the price verbatim, so a test sets 0 to model a sub-1e-9
    ///         subnet the oracle cannot represent; an unset subnet reads a nonzero default.
    function getAlphaPrice(uint16 netuid) external view returns (uint256) {
        return _isSet[netuid] ? _alphaPriceE18[netuid] : DEFAULT_PRICE_E18;
    }

    /// @notice Full-precision price the staking mock floors against. Never zero: the chain enforces
    ///         its floor even on subnets whose EVM oracle price rounds to 0.
    function chainAlphaPrice(uint16 netuid) public view returns (uint256) {
        uint256 price = _alphaPriceE18[netuid];
        return price == 0 ? DEFAULT_PRICE_E18 : price;
    }
}
