// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ISubnet
/// @notice Interface for the Bittensor subnet precompile on EVM.
/// @dev Precompile lives at 0x0000000000000000000000000000000000000803.
///      `getNetworkRegistrationBlock` returns 0 when no subnet is registered at the netuid.
///      `isSubnetDissolving` is true from the dissolve extrinsic until subtensor's
///      asynchronous cleanup of the netuid completes; the netuid cannot be re-registered
///      while it is true.
interface ISubnet {
    function getNetworkRegistrationBlock(uint16 netuid) external view returns (uint64);

    function isSubnetDissolving(uint16 netuid) external view returns (bool);
}

/// @dev Subnet precompile address on Bittensor EVM.
address constant SUBNET_PRECOMPILE = 0x0000000000000000000000000000000000000803;
