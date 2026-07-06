// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IValidatorRegistry } from "src/interfaces/IValidatorRegistry.sol";

contract MockValidatorRegistry is IValidatorRegistry {
    struct Slot {
        bytes32[] hotkeys;
        uint16[] weights;
    }

    mapping(uint256 => Slot) private _slots;

    /// @dev Seeds raw slots without the real registry's validation (e.g. weights that do not
    ///      sum to 10000); tests deploy a fresh vault against this mock when needed.
    function setRaw(uint256 netuid, bytes32[] memory hotkeys, uint16[] memory weights) external {
        Slot storage slot = _slots[netuid];
        slot.hotkeys = hotkeys;
        slot.weights = weights;
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
