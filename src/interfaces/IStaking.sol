// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IStaking
/// @notice Interface for the Bittensor staking precompile on EVM.
/// @dev Precompile lives at 0x0000000000000000000000000000000000000805.
///      Coldkeys are bytes32 (SS58 public keys), NOT H160 addresses.
///      The EVM→Substrate mapping uses Frontier HashedAddressMapping.
interface IStaking {
    function transferStake(
        bytes32 destination_coldkey,
        bytes32 hotkey,
        uint256 origin_netuid,
        uint256 destination_netuid,
        uint256 amount
    ) external payable;

    function moveStake(
        bytes32 origin_hotkey,
        bytes32 destination_hotkey,
        uint256 origin_netuid,
        uint256 destination_netuid,
        uint256 amount
    ) external payable;

    function getStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid) external view returns (uint256);
}

/// @dev Staking precompile address on Bittensor EVM.
address constant STAKING_PRECOMPILE = 0x0000000000000000000000000000000000000805;
