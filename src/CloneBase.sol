// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IStaking, STAKING_PRECOMPILE } from "./interfaces/IStaking.sol";

/// @title CloneBase
/// @notice Shared logic for EIP-1167 minimal proxy clones managed by AlphaVault.
abstract contract CloneBase {
    address public wrapper;
    bool public initialized;

    error AlreadyInitialized();
    error NotWrapper();
    error ZeroAddress();
    error UnauthorizedInitializer();

    /// @dev Lock the implementation contract itself so only fresh-storage clones can `initialize`.
    constructor() {
        initialized = true;
    }

    modifier onlyWrapper() {
        if (msg.sender != wrapper) revert NotWrapper();
        _;
    }

    /// @notice One-shot initializer called by the wrapper right after cloning.
    /// @dev    Only the wrapper itself can initialize: enforced by `msg.sender == _wrapper`.
    ///         Reverts with `AlreadyInitialized` if called twice, `ZeroAddress` on zero input,
    ///         and `UnauthorizedInitializer` if the caller is not the passed wrapper.
    /// @param  _wrapper AlphaVault instance authorized to drive this clone.
    function initialize(address _wrapper) external {
        if (initialized) revert AlreadyInitialized();
        if (_wrapper == address(0)) revert ZeroAddress();
        if (msg.sender != _wrapper) revert UnauthorizedInitializer();
        wrapper = _wrapper;
        initialized = true;
    }

    /// @notice Transfer alpha stake held by this clone to another coldkey on the same subnet.
    /// @dev    No-op when `amount == 0`. Callable only by the wrapper.
    /// @param  destinationColdkey Substrate coldkey receiving the stake.
    /// @param  hotkey             Hotkey the stake sits under.
    /// @param  netuid             Subnet id (used as both origin and destination netuid).
    /// @param  amount             Alpha amount to transfer.
    function flush(bytes32 destinationColdkey, bytes32 hotkey, uint256 netuid, uint256 amount) external onlyWrapper {
        if (amount > 0) {
            IStaking(STAKING_PRECOMPILE).transferStake(destinationColdkey, hotkey, netuid, netuid, amount);
        }
    }

    /// @notice Forward native TAO held by this clone to `to`.
    /// @dev    No-op when `amount == 0`. Callable only by the wrapper.
    /// @param  to     Recipient of the native TAO.
    /// @param  amount TAO (in wei) to send.
    function withdrawTao(address payable to, uint256 amount) external onlyWrapper {
        if (amount > 0) Address.sendValue(to, amount);
    }

    receive() external payable { }
}
