// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IStaking, STAKING_PRECOMPILE } from "./interfaces/IStaking.sol";

/// @title DepositForwarderLogic
/// @notice Stateless implementation contract for EIP-1167 Minimal Proxy "Mailbox" clones.
///         Each clone is a deterministic deposit address for a specific user.
///         The clone receives Alpha Stake, then flushes it to the parent AlphaVault
///         via transferStake on the staking precompile.
///
/// @dev This contract is deployed ONCE. Clones delegate-call into it.
///      Storage layout (in the clone's context):
///        slot 0: address wrapper   (set during initialize)
///        slot 1: bool   initialized
///
///      The wrapper calls `flush()` which transfers alpha stake from
///      the clone to the vault's coldkey via the staking precompile.
contract DepositForwarderLogic {
    // ──────────────────── Storage (written in clone context) ────────────────────
    address public wrapper;
    bool public initialized;

    // ──────────────────── Errors ────────────────────────────────────────────────
    error AlreadyInitialized();
    error NotWrapper();
    error ZeroAddress();

    // ──────────────────── Modifiers ─────────────────────────────────────────────
    modifier onlyWrapper() {
        if (msg.sender != wrapper) revert NotWrapper();
        _;
    }

    /// @notice Initialize the clone with the parent wrapper address.
    /// @dev Called once immediately after clone deployment via CREATE2.
    /// @param _wrapper Address of the AlphaWrapper that owns this clone.
    function initialize(address _wrapper) external {
        if (initialized) revert AlreadyInitialized();
        if (_wrapper == address(0)) revert ZeroAddress();
        wrapper = _wrapper;
        initialized = true;
    }

    /// @notice Transfer alpha stake held by this clone to the vault via transferStake.
    /// @param destinationColdkey The vault's coldkey as bytes32.
    /// @param hotkey The validator hotkey.
    /// @param netuid The subnet ID (used as both origin and destination).
    /// @param amount The amount of alpha stake to transfer.
    function flush(bytes32 destinationColdkey, bytes32 hotkey, uint256 netuid, uint256 amount) external onlyWrapper {
        if (amount > 0) {
            IStaking(STAKING_PRECOMPILE).transferStake(destinationColdkey, hotkey, netuid, netuid, amount);
        }
    }
}
