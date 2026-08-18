// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IValidatorRegistry } from "src/interfaces/IValidatorRegistry.sol";

contract MockValidatorRegistry is IValidatorRegistry {
    struct Slot {
        bytes32[] hotkeys;
        uint16[] weights;
    }

    mapping(uint256 => Slot) private _slots;

    /// @dev Seeds corrupt slots (e.g. zero hotkey + non-zero weight, or mismatched lengths) that the
    ///      real registry would reject; tests deploy a fresh vault against this mock when needed.
    mapping(uint256 => uint256) public nonces;

    function setRaw(uint256 netuid, bytes32[] memory hotkeys, uint16[] memory weights) external {
        Slot storage slot = _slots[netuid];
        slot.hotkeys = hotkeys;
        slot.weights = weights;
        // The real registry bumps its counter on every accepted update, and the vault reads that
        // counter to tell a set it has already settled against from one it has not.
        ++nonces[netuid];
    }

    function getValidators(uint256 netuid)
        external
        view
        override
        returns (bytes32[] memory hotkeys, uint16[] memory weights)
    {
        Slot storage slot = _slots[netuid];
        return (slot.hotkeys, slot.weights);
    }
}
