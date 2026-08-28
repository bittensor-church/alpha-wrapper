// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IStaking, STAKING_PRECOMPILE } from "../interfaces/IStaking.sol";
import { IValidatorRegistry } from "../interfaces/IValidatorRegistry.sol";
import { IAddressMapping, ADDRESS_MAPPING_PRECOMPILE } from "../interfaces/IAddressMapping.sol";
import { ISubnet, SUBNET_PRECOMPILE } from "../interfaces/ISubnet.sol";
import { VaultMath } from "./VaultMath.sol";
import {
    BackingShortfall,
    NoValidatorFound,
    SubnetInDissolutionBlackoutPeriod,
    ValidatorSetMalformed
} from "../VaultErrors.sol";

/// @title VaultReads
/// @notice The chain reads behind a vault position - validator set, per-hotkey stake, subnet
///         registration state and unclaimed clone TAO - shared by `AlphaVault` and the read-only
///         `AlphaVaultLens`, so a quote and the call it quotes read the same way.
/// @dev    Vault storage is never reached from here; every caller passes in what it read from its
///         own side, whether that is a storage slot or a getter call.
library VaultReads {
    function coldkeyOf(address evmAddress) internal view returns (bytes32) {
        return IAddressMapping(ADDRESS_MAPPING_PRECOMPILE).addressMapping(evmAddress);
    }

    /// @dev Reverts `NoValidatorFound` if the registry has no configured set for `netuid`.
    function resolveValidators(IValidatorRegistry registry, uint16 netuid)
        internal
        view
        returns (bytes32[] memory hotkeys, uint16[] memory weights)
    {
        (hotkeys, weights) = registry.getValidators(netuid);
        if (hotkeys.length == 0) revert NoValidatorFound();
        // The registry interface guarantees matching lengths; a broken registry fails fast here.
        if (hotkeys.length != weights.length) revert ValidatorSetMalformed();
    }

    function fetchBalances(bytes32[] memory hotkeys, bytes32 coldkey, uint16 netuid)
        internal
        view
        returns (uint256[] memory balances)
    {
        balances = new uint256[](hotkeys.length);
        IStaking staking = IStaking(STAKING_PRECOMPILE);
        for (uint256 i; i < hotkeys.length;) {
            balances[i] = staking.getStake(hotkeys[i], coldkey, netuid);
            unchecked {
                ++i;
            }
        }
    }

    function isIssuedForDissolvedSubnet(uint256 tokenId) internal view returns (bool) {
        uint64 currentRegistrationBlock =
            ISubnet(SUBNET_PRECOMPILE).getNetworkRegistrationBlock(VaultMath.netuidOf(tokenId));
        return currentRegistrationBlock == 0 || currentRegistrationBlock != VaultMath.registrationBlockOf(tokenId);
    }

    /// @dev Subtensor dissolves a subnet asynchronously over many blocks, and alpha balances and
    ///      TAO refunds are in flux for the whole window.
    function isDissolving(uint16 netuid) internal view returns (bool) {
        return ISubnet(SUBNET_PRECOMPILE).isSubnetDissolving(netuid);
    }

    /// @dev Every share-priced path is frozen until dissolution completes. The check is per netuid,
    ///      so an already-dissolved position is also frozen while a newer subnet on the same netuid
    ///      dissolves.
    function requireNotDissolving(uint16 netuid) internal view {
        if (isDissolving(netuid)) revert SubnetInDissolutionBlackoutPeriod();
    }

    /// @dev The part of a clone's `balance` a synchronization may fold into the claim index right
    ///      now, given the liability already `reserved` against it. Zero while the subnet is
    ///      dissolving or dissolved: from then on new clone balance is the dissolution refund,
    ///      which the dissolved unwrap path distributes pro rata instead.
    function indexableTao(uint256 tokenId, uint256 balance, uint256 reserved) internal view returns (uint256) {
        uint256 newTao = VaultMath.unreservedTao(balance, reserved);
        if (newTao == 0) return 0;
        if (isDissolving(VaultMath.netuidOf(tokenId))) return 0;
        if (isIssuedForDissolvedSubnet(tokenId)) return 0;
        return newTao;
    }

    // -------------------- Backing record ----------------------------------------

    /// @dev One record per validator the position is spread across. `logical` and `active` differ
    ///      only while a hotkey swap has moved the stake and the attesters have not caught up.
    struct Slot {
        bytes32 logical;
        bytes32 active;
        uint256 tracked;
        uint64 shortSince;
    }

    /// @dev One reading of a record against the chain. A struct because the coverage build
    ///      compiles at minimum optimization, where returning the parts separately runs the stack
    ///      out.
    /// @param keys     The key each slot resolves to.
    /// @param balances What sits under each of them.
    /// @param short    Which slots cannot account for themselves.
    /// @param total    What the reading located in all.
    struct Backing {
        bytes32[] keys;
        uint256[] balances;
        bool[] short;
        uint256 total;
    }

    /// @dev Expectations are compared with this much give, never for equality. An accepted ceiling
    ///      on accounting dust the vault will not chase.
    uint256 internal constant TRACKED_SLACK_RAO = 1e3;

    /// @dev Reads the record against the chain, writing nothing and resolving at most one hotkey
    ///      swap per slot. The vault's rails and the lens's quotes share it, so they cannot
    ///      disagree about what the position holds.
    function resolveBacking(Slot[] memory slots, bytes32 coldkey, uint16 netuid)
        internal
        view
        returns (Backing memory backing)
    {
        uint256 count = slots.length;
        backing.keys = activesOf(slots);
        backing.balances = new uint256[](count);
        backing.short = new bool[](count);
        for (uint256 i; i < count;) {
            uint256 tracked = slots[i].tracked;
            uint256 balance = IStaking(STAKING_PRECOMPILE).getStake(backing.keys[i], coldkey, netuid);
            if (!coversTracked(balance, tracked)) {
                (bool followed, bytes32 successor, uint256 successorBalance) =
                    _followSwap(backing.keys, i, balance, tracked, coldkey, netuid);
                if (followed) {
                    backing.keys[i] = successor;
                    balance = successorBalance;
                } else {
                    backing.short[i] = true;
                }
            }
            backing.balances[i] = balance;
            backing.total += balance;
            unchecked {
                ++i;
            }
        }
    }

    /// @dev The one shortfall that resolves itself: a validator hotkey swap, accepted only when the
    ///      successor explains the whole slot. A residual left behind is refused because a slot
    ///      spread across two keys is more than the record can carry, and a successor another slot
    ///      answers for is refused because one balance may never back two expectations. Exactly one
    ///      edge is read, and no price: judging a past event by today's valuation gets it wrong in
    ///      both directions.
    function _followSwap(
        bytes32[] memory keys,
        uint256 index,
        uint256 balance,
        uint256 tracked,
        bytes32 coldkey,
        uint16 netuid
    ) private view returns (bool, bytes32, uint256) {
        if (balance != 0) return (false, bytes32(0), 0);
        bytes32 successor = hotkeySuccessor(keys[index], netuid);
        if (successor == bytes32(0)) return (false, bytes32(0), 0);
        if (VaultMath.contains(keys, successor)) return (false, bytes32(0), 0);
        uint256 successorBalance = IStaking(STAKING_PRECOMPILE).getStake(successor, coldkey, netuid);
        if (!coversTracked(successorBalance, tracked)) return (false, bytes32(0), 0);
        return (true, successor, successorBalance);
    }

    /// @dev The hotkey's one-hop successor, or zero when the chain records none.
    function hotkeySuccessor(bytes32 hotkey, uint16 netuid) internal view returns (bytes32) {
        (bool exists, bytes32 successor) = IStaking(STAKING_PRECOMPILE).getHotkeySuccessor(hotkey, netuid);
        if (!exists || successor == hotkey) return bytes32(0);
        return successor;
    }

    function activesOf(Slot[] memory slots) internal pure returns (bytes32[] memory keys) {
        keys = new bytes32[](slots.length);
        for (uint256 i; i < keys.length;) {
            keys[i] = slots[i].active;
            unchecked {
                ++i;
            }
        }
    }

    /// @dev First short slot of a reading; max when none are.
    function firstShortOf(bool[] memory short) internal pure returns (uint256) {
        for (uint256 i; i < short.length;) {
            if (short[i]) return i;
            unchecked {
                ++i;
            }
        }
        return type(uint256).max;
    }

    /// @dev The one refusal for unaccounted backing, shared so the vault's rails and the lens's
    ///      quotes cannot disagree about it.
    function requireIntact(Slot[] memory slots, Backing memory backing, uint16 netuid) internal pure {
        uint256 shortIndex = firstShortOf(backing.short);
        if (shortIndex != type(uint256).max) {
            revert BackingShortfall(netuid, slots[shortIndex].active, slots[shortIndex].tracked);
        }
    }

    /// @dev Whether `stake` accounts for a slot owed `tracked`.
    function coversTracked(uint256 stake, uint256 tracked) internal pure returns (bool) {
        return stake + TRACKED_SLACK_RAO >= tracked;
    }

    /// @dev When the loss recorded at `shortSince` becomes writable off, given the vault's
    ///      recovery window.
    function recoveryDeadline(uint64 shortSince, uint256 window) internal pure returns (uint256) {
        return shortSince + window;
    }

    /// @dev Whether a loss recorded at `shortSince` still holds the position shut. An unrecorded
    ///      loss counts: a deadline cannot pass before it exists.
    function isWindowStanding(uint64 shortSince, uint256 window) internal view returns (bool) {
        // forge-lint: disable-next-line(block-timestamp)
        return shortSince == 0 || block.timestamp < recoveryDeadline(shortSince, window);
    }
}
