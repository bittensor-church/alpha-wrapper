// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";

/// @title FixedValidator
/// @notice The vault's validator source, pinned at deployment: every subnet stakes under one
///         immutable hotkey at full weight. Swapping the validator means deploying a fresh
///         FixedValidator and a fresh vault against it - there is no admin surface here.
contract FixedValidator is IValidatorRegistry {
    bytes32 public immutable hotkey;

    error ZeroHotkey();

    constructor(bytes32 _hotkey) {
        if (_hotkey == bytes32(0)) revert ZeroHotkey();
        hotkey = _hotkey;
    }

    /// @inheritdoc IValidatorRegistry
    function getValidators(uint256) external view returns (bytes32[] memory hotkeys, uint16[] memory weights) {
        hotkeys = new bytes32[](1);
        hotkeys[0] = hotkey;
        weights = new uint16[](1);
        weights[0] = 10_000;
    }
}
