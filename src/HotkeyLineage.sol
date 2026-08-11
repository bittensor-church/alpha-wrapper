// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IStaking } from "./interfaces/IStaking.sol";

/// @title HotkeyLineage
/// @notice Stateless helpers for tracing a hotkey through chain-side swaps: a bounded successor walk
///         that follows the vault's parked stake, plus two evidence rungs used to corroborate a swap.
library HotkeyLineage {
    /// @notice Walk successors up to `bound` hops, returning the first that holds the vault's stake.
    /// @dev The stake can be parked mid-chain (a rename that leaves stake put), so the tip is not the
    ///      only candidate; every hop is checked against the vault's coldkey.
    function walk(IStaking staking, bytes32 hotkey, uint16 netuid, bytes32 vaultColdkey, uint256 tracked, uint8 bound)
        internal
        view
        returns (bool healed, bytes32 newHotkey)
    {
        bytes32 h = hotkey;
        for (uint8 i; i < bound; ++i) {
            (bool exists, bytes32 next) = staking.getHotkeySuccessor(h, netuid);
            if (!exists || next == h) break;
            if (staking.getStake(next, vaultColdkey, netuid) >= tracked) return (true, next);
            h = next;
        }
        return (false, bytes32(0));
    }

    /// @notice True when `a` and `b` share a lineage root.
    /// @dev Absent root folds to self on both sides, matching how the chain reports a key that has
    ///      no recorded root.
    function sameRoot(IStaking staking, bytes32 a, bytes32 b, uint16 netuid) internal view returns (bool) {
        return _rootOrSelf(staking, a, netuid) == _rootOrSelf(staking, b, netuid);
    }

    /// @notice True when `candidate` is corroborated as a swap of `from`: either a direct successor
    ///         edge or a shared lineage root on the evidence subnet.
    function successorLeadsTo(IStaking staking, bytes32 from, bytes32 candidate, uint16 evidenceNetuid)
        internal
        view
        returns (bool)
    {
        (bool exists, bytes32 next) = staking.getHotkeySuccessor(from, evidenceNetuid);
        if (exists && next == candidate) return true;
        return sameRoot(staking, from, candidate, evidenceNetuid);
    }

    function _rootOrSelf(IStaking staking, bytes32 key, uint16 netuid) private view returns (bytes32) {
        (bool exists, bytes32 root) = staking.getHotkeyRoot(key, netuid);
        return exists ? root : key;
    }
}
