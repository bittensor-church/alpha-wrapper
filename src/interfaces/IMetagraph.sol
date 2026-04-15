// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IMetagraph
/// @notice Interface for the Bittensor metagraph precompile on EVM.
/// @dev Precompile lives at 0x0000000000000000000000000000000000000802.
interface IMetagraph {
    function getUidCount(uint16 netuid) external view returns (uint16);
    function getStake(uint16 netuid, uint16 uid) external view returns (uint64);
    function getHotkey(uint16 netuid, uint16 uid) external view returns (bytes32);
    function getValidatorStatus(uint16 netuid, uint16 uid) external view returns (bool);
}

/// @dev Metagraph precompile address on Bittensor EVM.
address constant METAGRAPH_PRECOMPILE = 0x0000000000000000000000000000000000000802;
