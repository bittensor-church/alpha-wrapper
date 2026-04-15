// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockStaking
/// @notice Mock of the Bittensor staking precompile (0x805) for testing.
///         Matches the real IStaking interface: coldkeys are bytes32 (substrate account IDs).
///
///         On the real chain, an EVM address (H160) maps to a substrate account via
///         blake2b("evm:" + h160). In this mock, we simulate the same with
///         keccak256("evm:", h160) for simplicity (the test helpers use the same hash).
contract MockStaking {
    // hotkey => coldkey(bytes32) => netuid => stake
    mapping(bytes32 => mapping(bytes32 => mapping(uint256 => uint256))) public stakes;

    /// @notice Test helper: directly set stake for a coldkey.
    function setStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid, uint256 amount) external {
        stakes[hotkey][coldkey][netuid] = amount;
    }

    /// @dev Convert msg.sender H160 to substrate-like account ID.
    ///      Uses keccak256("evm:", addr) to match the test helper _toSubstrate().
    function _senderColdkey() internal view returns (bytes32) {
        return keccak256(abi.encodePacked("evm:", msg.sender));
    }

    function addStake(bytes32 hotkey, uint256 amount, uint256 netuid) external payable {
        stakes[hotkey][_senderColdkey()][netuid] += amount;
    }

    function removeStake(bytes32 hotkey, uint256 amount, uint256 netuid) external payable {
        stakes[hotkey][_senderColdkey()][netuid] -= amount;
    }

    function transferStake(
        bytes32 destination_coldkey,
        bytes32 hotkey,
        uint256 origin_netuid,
        uint256 destination_netuid,
        uint256 amount
    ) external payable {
        stakes[hotkey][_senderColdkey()][origin_netuid] -= amount;
        stakes[hotkey][destination_coldkey][destination_netuid] += amount;
    }

    function moveStake(
        bytes32 origin_hotkey,
        bytes32 destination_hotkey,
        uint256 origin_netuid,
        uint256 destination_netuid,
        uint256 amount
    ) external payable {
        stakes[origin_hotkey][_senderColdkey()][origin_netuid] -= amount;
        stakes[destination_hotkey][_senderColdkey()][destination_netuid] += amount;
    }

    function getStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid) external view returns (uint256) {
        return stakes[hotkey][coldkey][netuid];
    }

    function getTotalColdkeyStake(bytes32) external pure returns (uint256) {
        return 0;
    }

    function getTotalHotkeyStake(bytes32) external pure returns (uint256) {
        return 0;
    }
}
