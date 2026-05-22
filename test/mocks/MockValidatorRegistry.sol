// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IValidatorRegistry } from "src/interfaces/IValidatorRegistry.sol";

contract MockValidatorRegistry is IValidatorRegistry {
    struct Slot {
        bytes32[3] hotkeys;
        uint16[3] weights;
    }

    mapping(uint256 => Slot) private _slots;

    /// @dev Seeds corrupt slots (e.g. zero hotkey + non-zero weight) that the real
    ///      registry would reject; tests point AlphaVault at a fresh mock when needed.
    function setRaw(uint256 netuid, bytes32[3] memory hotkeys, uint16[3] memory weights) external {
        _slots[netuid] = Slot(hotkeys, weights);
    }

    function getValidators(uint256 netuid)
        external
        view
        override
        returns (bytes32[3] memory hotkeys, uint16[3] memory weights)
    {
        Slot storage s = _slots[netuid];
        return (s.hotkeys, s.weights);
    }
}
