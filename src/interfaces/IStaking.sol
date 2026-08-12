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

    /// @notice One hotkey's alpha stake under a coldkey, as returned by the batched read.
    struct StakeInfo {
        bytes32 hotkey;
        uint256 stake;
    }

    /// @notice Alpha stake for many hotkeys under one coldkey on one subnet, in a single call.
    /// @dev    Accepts at most `MAX_STAKE_INFO_HOTKEYS` hotkeys and reverts on a duplicate. Hotkeys
    ///         holding no stake are omitted, so the result is a subset of `hotkeys` in the same
    ///         order and callers must match entries by hotkey rather than by position.
    function getStakeInfoForColdkeyAndNetuid(bytes32 coldkey, uint256 netuid, bytes32[] calldata hotkeys)
        external
        view
        returns (StakeInfo[] memory);

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

/// @dev Most hotkeys `getStakeInfoForColdkeyAndNetuid` accepts in one call. A chain constant: the
///      input is bounded, so a longer list fails to decode rather than returning a partial answer.
uint256 constant MAX_STAKE_INFO_HOTKEYS = 64;
