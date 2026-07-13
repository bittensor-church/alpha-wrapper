// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { MockStaking } from "./MockStaking.sol";

contract MockAlpha {
    uint256 private constant DEFAULT_PRICE_E18 = 1e18;
    uint256 private constant PRICE_QUANTUM_E18 = 1e9;

    mapping(uint16 => uint256) private _chainPriceE18;
    mapping(uint16 => bool) private _isSet;

    /// @notice Set the subnet's full-precision chain price. Zero is unrepresentable on-chain (an
    ///         empty pool rejects staking ops long before pricing); model a sub-quantum subnet
    ///         with a value below 1e9 instead - its EVM read then rounds to 0.
    function setAlphaPrice(uint16 netuid, uint256 alphaPriceE18) external {
        require(alphaPriceE18 != 0, "MockAlpha: zero chain price unrepresentable");
        _chainPriceE18[netuid] = alphaPriceE18;
        _isSet[netuid] = true;
    }

    /// @notice EVM oracle read: the chain price floored to a 1e9 multiple, mirroring the
    ///         precompile's u64 truncation before its 1e9 upscale.
    function getAlphaPrice(uint16 netuid) external view returns (uint256) {
        return chainAlphaPrice(netuid) / PRICE_QUANTUM_E18 * PRICE_QUANTUM_E18;
    }

    /// @notice Full-precision price the staking mock floors against, as the chain does.
    function chainAlphaPrice(uint16 netuid) public view returns (uint256) {
        return _isSet[netuid] ? _chainPriceE18[netuid] : DEFAULT_PRICE_E18;
    }

    bool public simSwapReverts;
    mapping(uint64 => uint256) private _simQuoteOverride;
    mapping(uint64 => bool) private _simQuoteSet;

    /// @notice The real precompile fails as an all-gas EVM error on swaps the pool cannot price.
    function setSimSwapReverts(bool v) external {
        simSwapReverts = v;
    }

    /// @notice Pin the quote for one exact input, modeling price impact the linear rate cannot.
    function setSimSwapQuote(uint64 alpha, uint256 taoOut) external {
        _simQuoteOverride[alpha] = taoOut;
        _simQuoteSet[alpha] = true;
    }

    /// @notice Simulated sell output at the staking mock's payout rate, so the simulation and the
    ///         execution cannot drift; per-amount overrides model price impact.
    function simSwapAlphaForTao(uint16, uint64 alpha) external view returns (uint256) {
        require(!simSwapReverts, "MockAlpha: simSwap reverted");
        if (_simQuoteSet[alpha]) return _simQuoteOverride[alpha];
        return MockStaking(STAKING_PRECOMPILE).quoteTaoOut(alpha);
    }
}
