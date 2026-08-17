// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IStaking
/// @notice Interface for the Bittensor staking precompile on EVM.
/// @dev Precompile lives at 0x0000000000000000000000000000000000000805.
///      Coldkeys are bytes32 (SS58 public keys), NOT H160 addresses.
///      The EVM-to-Substrate mapping uses Frontier HashedAddressMapping.
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

    /// @notice The hotkey `hotkey` on `netuid` was renamed to, if any. The chain keys this getter
    ///         with a narrower netuid type than the rest of the interface.
    function getHotkeySuccessor(bytes32 hotkey, uint16 netuid) external view returns (bool exists, bytes32 successor);

    /// @notice The coldkey owning `hotkey`. Absent once a full rename has deleted the hotkey's
    ///         account, even while delegated stake still sits under it.
    function getHotkeyOwner(bytes32 hotkey) external view returns (bool exists, bytes32 owner);

    function removeStake(bytes32 hotkey, uint256 amount, uint256 netuid) external payable;

    /// @notice Tao-denominated dust threshold: after a partial unstake, the chain force-clears any
    ///         nominator stake entry left below this spot value.
    function getNominatorMinRequiredStake() external view returns (uint256);

    /// @notice Tao-denominated minimum the chain applies to a partial unstake; a runtime constant,
    ///         so it moves only on a chain upgrade. The chain floors transfers and same-subnet moves
    ///         lower and exposes no getter for that one, so this is a safe upper bound for them too.
    function getDefaultMinStake() external view returns (uint256);
}

/// @dev Staking precompile address on Bittensor EVM.
address constant STAKING_PRECOMPILE = 0x0000000000000000000000000000000000000805;
