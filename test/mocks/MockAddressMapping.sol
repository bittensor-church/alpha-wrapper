// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Mock of the address mapping precompile (0x080C) for testing.
///         Uses keccak256 instead of blake2b to match MockStaking._senderColdkey().
contract MockAddressMapping {
    function addressMapping(address evmAddress) external pure returns (bytes32) {
        return keccak256(abi.encodePacked("evm:", evmAddress));
    }
}
