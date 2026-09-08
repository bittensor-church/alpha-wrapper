// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IValidatorRegistry } from "src/interfaces/IValidatorRegistry.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { MockStaking } from "./MockStaking.sol";

contract MockValidatorRegistry is IValidatorRegistry {
    struct Slot {
        bytes32[] hotkeys;
        uint16[] weights;
        bytes32[] owners;
    }

    mapping(uint256 => Slot) private _slots;
    mapping(uint256 => uint256) public override nonces;

    /// @dev Allows malformed sets that the real registry rejects; owners are whoever holds the names now.
    function setRaw(uint256 netuid, bytes32[] memory hotkeys, uint16[] memory weights) external {
        Slot storage slot = _slots[netuid];
        slot.hotkeys = hotkeys;
        slot.weights = weights;
        delete slot.owners;
        for (uint256 i; i < hotkeys.length; ++i) {
            slot.owners.push(MockStaking(STAKING_PRECOMPILE).ownerOf(hotkeys[i]));
        }
        nonces[netuid] += 1;
    }

    function getValidators(uint256 netuid)
        external
        view
        override
        returns (bytes32[] memory hotkeys, uint16[] memory weights, bytes32[] memory owners)
    {
        Slot storage slot = _slots[netuid];
        return (slot.hotkeys, slot.weights, slot.owners);
    }
}
