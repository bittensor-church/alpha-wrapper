// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Alpha precompile address on Bittensor EVM.
address constant IALPHA_ADDRESS = 0x0000000000000000000000000000000000000808;

interface IAlpha {
    function getAlphaPrice(uint16 netuid) external view returns (uint256);
    function getMovingAlphaPrice(uint16 netuid) external view returns (uint256);
    function getTaoInPool(uint16 netuid) external view returns (uint64);
    function getAlphaInPool(uint16 netuid) external view returns (uint64);
    function getAlphaOutPool(uint16 netuid) external view returns (uint64);
    function getAlphaIssuance(uint16 netuid) external view returns (uint64);
    function getTaoWeight() external view returns (uint256);
    function simSwapTaoForAlpha(uint16 netuid, uint64 tao) external view returns (uint256);
    function simSwapAlphaForTao(uint16 netuid, uint64 alpha) external view returns (uint256);
    function getSubnetMechanism(uint16 netuid) external view returns (uint16);
    function getRootNetuid() external view returns (uint16);
    function getEMAPriceHalvingBlocks(uint16 netuid) external view returns (uint64);
    function getSubnetVolume(uint16 netuid) external view returns (uint256);
    function getTaoInEmission(uint16 netuid) external view returns (uint256);
    function getAlphaInEmission(uint16 netuid) external view returns (uint256);
    function getAlphaOutEmission(uint16 netuid) external view returns (uint256);
    function getSumAlphaPrice() external view returns (uint256);
    function getCKBurn() external view returns (uint256);
}
