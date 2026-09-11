// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Coldkeys are Substrate public keys, not H160 addresses. Stake amounts and TAO thresholds use RAO.
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

    /// @dev An all-subnet swap removes the old key's owner record, not the key identifier.
    ///      Stake operations require this record; association can restore it.
    function getHotkeyOwner(bytes32 hotkey) external view returns (bool exists, bytes32 owner);

    /// @dev Subnet re-registration can erase this edge; no edge does not prove there was no swap.
    function getHotkeySuccessor(bytes32 hotkey, uint16 netuid) external view returns (bool exists, bytes32 successor);

    function removeStake(bytes32 hotkey, uint256 amount, uint256 netuid) external payable;

    /// @notice TAO spot-value threshold in RAO below which a partial unstake force-sells the remainder.
    function getNominatorMinRequiredStake() external view returns (uint256);

    /// @notice Partial-unstake minimum in TAO RAO.
    /// @dev Transfers/moves have a lower minimum, absent from this interface; this is a conservative bound.
    function getDefaultMinStake() external view returns (uint256);
}

address constant STAKING_PRECOMPILE = 0x0000000000000000000000000000000000000805;
