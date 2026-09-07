// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Uses keccak256, not Frontier's blake2b; must match the staking mock and test helpers.
contract MockAddressMapping {
    function addressMapping(address evmAddress) external pure returns (bytes32) {
        return keccak256(abi.encodePacked("evm:", evmAddress));
    }
}
