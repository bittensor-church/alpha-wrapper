// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Registration block is zero when unregistered, including late dissolution cleanup.
///      A dissolving netuid cannot be re-registered until asynchronous cleanup completes.
interface ISubnet {
    function getNetworkRegistrationBlock(uint16 netuid) external view returns (uint64);

    function isSubnetDissolving(uint16 netuid) external view returns (bool);
}

address constant SUBNET_PRECOMPILE = 0x0000000000000000000000000000000000000803;
