// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IValidatorRegistry } from "src/interfaces/IValidatorRegistry.sol";

contract MockValidatorRegistry is IValidatorRegistry {
    struct Slot {
        bytes32[] hotkeys;
        uint16[] weights;
        uint256 version;
    }

    mapping(uint256 => Slot) private _slots;

    /// @dev Seeds corrupt slots (e.g. zero hotkey + non-zero weight, or mismatched lengths) that the
    ///      real registry would reject; tests deploy a fresh vault against this mock when needed.
    ///      Each write bumps the version, mirroring the real registry's per-commit nonce.
    function setRaw(uint256 netuid, bytes32[] memory hotkeys, uint16[] memory weights) external {
        Slot storage s = _slots[netuid];
        s.hotkeys = hotkeys;
        s.weights = weights;
        unchecked {
            ++s.version;
        }
    }

    /// @dev Re-commits the same membership under a fresh version, so tests can exercise the
    ///      version-changed path without an actual rotation.
    function bumpVersion(uint256 netuid) external {
        unchecked {
            ++_slots[netuid].version;
        }
    }

    function getValidators(uint256 netuid)
        external
        view
        override
        returns (bytes32[] memory hotkeys, uint16[] memory weights, uint256 version)
    {
        Slot storage s = _slots[netuid];
        return (s.hotkeys, s.weights, s.version);
    }
}
