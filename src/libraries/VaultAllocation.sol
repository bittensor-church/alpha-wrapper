// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IValidatorRegistry } from "../interfaces/IValidatorRegistry.sol";
import { VaultMath } from "./VaultMath.sol";
import { VaultReads } from "./VaultReads.sol";
import { IStaking, STAKING_PRECOMPILE } from "../interfaces/IStaking.sol";
import { SwappedHotkeyStillAttested } from "../VaultErrors.sol";

/// @dev Deployed once and linked into the vault, which keeps these rules out of its own bytecode.
library VaultAllocation {
    /// @dev Keep funded slots on resolved keys; empty slots need a usable receiving key. A key is usable
    ///      only under the coldkey that owned the attested name, so a vacated name claimed by anyone
    ///      else reports as retired. Keys remain exclusive even for empty slots.
    function assignActives(
        IValidatorRegistry registry,
        bytes32[] memory logicals,
        bytes32[] memory keys,
        uint256[] memory balances,
        bytes32[] memory currentSet,
        uint16 netuid
    ) external view returns (bytes32[] memory actives, bytes32 retired) {
        actives = new bytes32[](currentSet.length);
        for (uint256 i; i < currentSet.length;) {
            bytes32 name = currentSet[i];
            bytes32 owner = registry.attestedOwner(name);
            uint256 at = VaultMath.indexOf(logicals, name);
            bytes32 key;
            bool live;
            if (at != type(uint256).max && balances[at] != 0) {
                key = keys[at];
                live = VaultReads.ownedBy(key, owner);
            } else if (_keyHeldElsewhere(keys, logicals, currentSet, name, at)) {
                if (at == type(uint256).max) revert SwappedHotkeyStillAttested();
                key = keys[at];
                live = VaultReads.ownedBy(key, owner);
            } else {
                (key, live) = _receivingKey(keys, logicals, currentSet, name, owner, at, netuid);
                if (key != name && VaultMath.contains(actives, key)) revert SwappedHotkeyStillAttested();
            }
            actives[i] = key;
            if (!live && retired == bytes32(0)) retired = name;
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Start at the richest source or destination, letting a fresh deposit carry rotated-out dust.
    function chooseRichestSlot(bytes32[] memory sourceKeys, bytes32[] memory currentSet, bytes32 coldkey, uint16 netuid)
        external
        view
        returns (
            bytes32 richestHotkey,
            uint256 richestBalance,
            uint256[] memory sourceBalances,
            bool hasRotatedOutBalance
        )
    {
        sourceBalances = new uint256[](sourceKeys.length);
        bytes32 richestRotatedOut;
        uint256 richestRotatedOutBalance;
        for (uint256 i; i < sourceBalances.length;) {
            bytes32 candidate = sourceKeys[i];
            if (!VaultMath.contains(currentSet, candidate)) {
                uint256 balance = IStaking(STAKING_PRECOMPILE).getStake(candidate, coldkey, netuid);
                sourceBalances[i] = balance;
                if (balance > richestRotatedOutBalance) {
                    richestRotatedOut = candidate;
                    richestRotatedOutBalance = balance;
                }
            }
            unchecked {
                ++i;
            }
        }
        if (richestRotatedOutBalance == 0) return (currentSet[0], 0, sourceBalances, false);

        hasRotatedOutBalance = true;
        richestHotkey = currentSet[0];
        for (uint256 i; i < currentSet.length;) {
            uint256 balance = IStaking(STAKING_PRECOMPILE).getStake(currentSet[i], coldkey, netuid);
            if (balance > richestBalance) {
                richestHotkey = currentSet[i];
                richestBalance = balance;
            }
            unchecked {
                ++i;
            }
        }
        if (richestRotatedOutBalance > richestBalance) {
            richestHotkey = richestRotatedOut;
            richestBalance = richestRotatedOutBalance;
        }
    }

    /// @dev A still-attested slot reserves its resolved key even while empty.
    function _keyHeldElsewhere(
        bytes32[] memory keys,
        bytes32[] memory logicals,
        bytes32[] memory currentSet,
        bytes32 key,
        uint256 ownSlot
    ) private pure returns (bool) {
        uint256 holder = VaultMath.indexOf(keys, key);
        if (holder == type(uint256).max || holder == ownSlot) return false;
        return VaultMath.contains(currentSet, logicals[holder]);
    }

    /// @dev Prefer the attested name, then the recorded active key, then its one-hop successor, each
    ///      only under the attested owner. Resume from the record: the name's edge may predate swaps
    ///      already followed.
    function _receivingKey(
        bytes32[] memory keys,
        bytes32[] memory logicals,
        bytes32[] memory currentSet,
        bytes32 name,
        bytes32 owner,
        uint256 ownSlot,
        uint16 netuid
    ) private view returns (bytes32 key, bool live) {
        if (VaultReads.ownedBy(name, owner)) return (name, true);

        key = ownSlot == type(uint256).max ? name : keys[ownSlot];
        live = key != name && VaultReads.ownedBy(key, owner);
        if (!live) {
            bytes32 successor = VaultReads.hotkeySuccessor(key, netuid);
            if (successor != bytes32(0) && VaultReads.ownedBy(successor, owner)) {
                key = successor;
                live = true;
            }
        }
        if (
            key != name
                && (VaultMath.contains(currentSet, key) || _keyHeldElsewhere(keys, logicals, currentSet, key, ownSlot))
        ) {
            revert SwappedHotkeyStillAttested();
        }
    }
}
