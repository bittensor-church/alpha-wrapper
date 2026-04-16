// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

address constant ADDRESS_MAPPING_PRECOMPILE = 0x000000000000000000000000000000000000080C;

interface IAddressMapping {
    function addressMapping(address evmAddress) external view returns (bytes32);
}
