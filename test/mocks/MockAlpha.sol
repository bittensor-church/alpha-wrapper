// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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
}
