// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockAlpha
/// @notice Mock of the Bittensor IAlpha precompile (0x808) for testing.
contract MockAlpha {
    // netuid => moving alpha price (RAO per alpha)
    mapping(uint16 => uint256) public movingPrices;
    // netuid => spot alpha price (RAO per alpha)
    mapping(uint16 => uint256) public spotPrices;

    /// @notice Test helper: set the EMA price for a subnet.
    function setMovingAlphaPrice(uint16 netuid, uint256 price) external {
        movingPrices[netuid] = price;
    }

    /// @notice Test helper: set the spot price for a subnet.
    function setAlphaPrice(uint16 netuid, uint256 price) external {
        spotPrices[netuid] = price;
    }

    function getMovingAlphaPrice(uint16 netuid) external view returns (uint256) {
        return movingPrices[netuid];
    }

    function getAlphaPrice(uint16 netuid) external view returns (uint256) {
        return spotPrices[netuid];
    }

    // Stubs for remaining IAlpha functions
    function getTaoInPool(uint16) external pure returns (uint64) {
        return 0;
    }

    function getAlphaInPool(uint16) external pure returns (uint64) {
        return 0;
    }

    function getAlphaOutPool(uint16) external pure returns (uint64) {
        return 0;
    }

    function getAlphaIssuance(uint16) external pure returns (uint64) {
        return 0;
    }

    function getTaoWeight() external pure returns (uint256) {
        return 0;
    }

    function simSwapTaoForAlpha(uint16, uint64) external pure returns (uint256) {
        return 0;
    }

    function simSwapAlphaForTao(uint16, uint64) external pure returns (uint256) {
        return 0;
    }

    function getSubnetMechanism(uint16) external pure returns (uint16) {
        return 1;
    }

    function getRootNetuid() external pure returns (uint16) {
        return 0;
    }

    function getEMAPriceHalvingBlocks(uint16) external pure returns (uint64) {
        return 0;
    }

    function getSubnetVolume(uint16) external pure returns (uint256) {
        return 0;
    }

    function getTaoInEmission(uint16) external pure returns (uint256) {
        return 0;
    }

    function getAlphaInEmission(uint16) external pure returns (uint256) {
        return 0;
    }

    function getAlphaOutEmission(uint16) external pure returns (uint256) {
        return 0;
    }

    function getSumAlphaPrice() external pure returns (uint256) {
        return 0;
    }

    function getCKBurn() external pure returns (uint256) {
        return 0;
    }
}
