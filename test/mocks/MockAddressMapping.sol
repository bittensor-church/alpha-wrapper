// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Uses keccak256 instead of the real blake2b so the derived coldkey matches
///      `MockStaking._senderColdkey`.
contract MockAddressMapping {
    function addressMapping(address evmAddress) external pure returns (bytes32) {
        return keccak256(abi.encodePacked("evm:", evmAddress));
    }
}
