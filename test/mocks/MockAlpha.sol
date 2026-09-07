// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { MockStaking } from "./MockStaking.sol";

contract MockAlpha {
    uint256 private constant DEFAULT_PRICE_E18 = 1e18;
    uint256 private constant PRICE_QUANTUM_E18 = 1e9;

    mapping(uint16 => uint256) private _chainPriceE18;
    mapping(uint16 => bool) private _isSet;

    /// @dev Use a price below 1e9 to model a zero EVM read with nonzero chain-side value.
    function setAlphaPrice(uint16 netuid, uint256 alphaPriceE18) external {
        require(alphaPriceE18 != 0, "MockAlpha: zero chain price unrepresentable");
        _chainPriceE18[netuid] = alphaPriceE18;
        _isSet[netuid] = true;
    }

    /// @dev Mirror the precompile's truncation to whole RAO before scaling back to 1e18.
    function getAlphaPrice(uint16 netuid) external view returns (uint256) {
        return chainAlphaPrice(netuid) / PRICE_QUANTUM_E18 * PRICE_QUANTUM_E18;
    }

    function chainAlphaPrice(uint16 netuid) public view returns (uint256) {
        return _isSet[netuid] ? _chainPriceE18[netuid] : DEFAULT_PRICE_E18;
    }

    bool public simSwapReverts;
    mapping(uint64 => uint256) private _simQuoteOverride;
    mapping(uint64 => bool) private _simQuoteSet;

    function setSimSwapReverts(bool v) external {
        simSwapReverts = v;
    }

    /// @dev Exact-input overrides model price impact absent from the default linear rate.
    function setSimSwapQuote(uint64 alpha, uint256 taoOut) external {
        _simQuoteOverride[alpha] = taoOut;
        _simQuoteSet[alpha] = true;
    }

    function simSwapAlphaForTao(uint16, uint64 alpha) external view returns (uint256) {
        require(!simSwapReverts, "MockAlpha: simSwap reverted");
        if (_simQuoteSet[alpha]) return _simQuoteOverride[alpha];
        return MockStaking(STAKING_PRECOMPILE).quoteTaoOut(alpha);
    }
}
