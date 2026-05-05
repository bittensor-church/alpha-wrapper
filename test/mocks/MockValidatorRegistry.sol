// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IValidatorRegistry } from "src/interfaces/IValidatorRegistry.sol";

contract MockValidatorRegistry is IValidatorRegistry {
    struct Slot {
        bytes32[3] hotkeys;
        uint16[3] weights;
    }

    mapping(uint256 => Slot) internal _slots;

    error LengthMismatch();

    function set(uint256 netuid, bytes32[] memory hotkeys, uint16[] memory weights) external {
        if (hotkeys.length != weights.length) revert LengthMismatch();
        Slot storage s = _slots[netuid];
        for (uint256 i = 0; i < 3; i++) {
            if (i < hotkeys.length) {
                s.hotkeys[i] = hotkeys[i];
                s.weights[i] = weights[i];
            } else {
                s.hotkeys[i] = bytes32(0);
                s.weights[i] = 0;
            }
        }
    }

    /// @dev Bypasses `set`'s length check to seed corrupt slots (e.g. zero hotkey + non-zero weight).
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
