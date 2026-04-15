// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockMetagraph
/// @notice Mock of the Bittensor metagraph precompile (0x802) for testing.
contract MockMetagraph {
    struct ValidatorInfo {
        bytes32 hotkey;
        uint64 stake;
        bool isValidator;
    }

    // netuid => uid => ValidatorInfo
    mapping(uint16 => mapping(uint16 => ValidatorInfo)) public validators;
    // netuid => uid count
    mapping(uint16 => uint16) public uidCounts;

    /// @notice Test helper: register a validator for a subnet.
    function setValidator(uint16 netuid, uint16 uid, bytes32 hotkey, uint64 stake, bool isValidator) external {
        validators[netuid][uid] = ValidatorInfo(hotkey, stake, isValidator);
        if (uid >= uidCounts[netuid]) {
            uidCounts[netuid] = uid + 1;
        }
    }

    function getUidCount(uint16 netuid) external view returns (uint16) {
        return uidCounts[netuid];
    }

    function getStake(uint16 netuid, uint16 uid) external view returns (uint64) {
        return validators[netuid][uid].stake;
    }

    function getHotkey(uint16 netuid, uint16 uid) external view returns (bytes32) {
        return validators[netuid][uid].hotkey;
    }

    function getValidatorStatus(uint16 netuid, uint16 uid) external view returns (bool) {
        return validators[netuid][uid].isValidator;
    }
}
