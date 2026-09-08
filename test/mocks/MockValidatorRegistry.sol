// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IValidatorRegistry } from "src/interfaces/IValidatorRegistry.sol";

contract MockValidatorRegistry is IValidatorRegistry {
    struct Slot {
        bytes32[] hotkeys;
        uint16[] weights;
    }

    mapping(uint256 => Slot) private _slots;
    mapping(uint256 => uint256) public override nonces;
    mapping(bytes32 => bytes32) public override attestedOwner;

    /// @dev Allows malformed sets that the real registry rejects.
    function setRaw(uint256 netuid, bytes32[] memory hotkeys, uint16[] memory weights) external {
        Slot storage slot = _slots[netuid];
        slot.hotkeys = hotkeys;
        slot.weights = weights;
        nonces[netuid] += 1;
    }

    function setAttestedOwner(bytes32 hotkey, bytes32 coldkey) external {
        attestedOwner[hotkey] = coldkey;
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
