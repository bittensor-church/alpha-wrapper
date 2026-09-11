// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IStaking, STAKING_PRECOMPILE } from "../interfaces/IStaking.sol";
import { IValidatorRegistry } from "../interfaces/IValidatorRegistry.sol";
import { IAddressMapping, ADDRESS_MAPPING_PRECOMPILE } from "../interfaces/IAddressMapping.sol";
import { ISubnet, SUBNET_PRECOMPILE } from "../interfaces/ISubnet.sol";
import { VaultMath } from "./VaultMath.sol";
import {
    BackingShortfall,
    NoValidatorFound,
    AlphaTransfersDisabled,
    SubnetInDissolutionBlackoutPeriod,
    ValidatorSetMalformed
} from "../VaultErrors.sol";

library VaultReads {
    uint256 internal constant NO_SHORT_SLOT = type(uint256).max;
    /// @dev Frozen with no deadline until recovery is declared.
    uint256 internal constant UNDECLARED_SHORTFALL = type(uint256).max;

    function coldkeyOf(address evmAddress) internal view returns (bytes32) {
        return IAddressMapping(ADDRESS_MAPPING_PRECOMPILE).addressMapping(evmAddress);
    }

    function ownedBy(bytes32 hotkey, bytes32 coldkey) internal view returns (bool) {
        (bool exists, bytes32 owner) = IStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkey);
        return exists && owner == coldkey;
    }

    function lockedAlphaOf(bytes32 coldkey, uint16 netuid) internal view returns (uint256 lockedAlpha) {
        (,, lockedAlpha,,) = IStaking(STAKING_PRECOMPILE).getColdkeyLock(coldkey, netuid);
    }

    /// @dev One attestation: the target hotkeys, their basis-point weights and the coldkey that owned
    ///      each name when it was attested.
    struct ValidatorSet {
        bytes32[] hotkeys;
        uint16[] weights;
        bytes32[] owners;
    }

    function resolveValidators(IValidatorRegistry registry, uint16 netuid)
        internal
        view
        returns (ValidatorSet memory set)
    {
        (bytes32[] memory hotkeys, uint16[] memory weights, bytes32[] memory owners) = registry.getValidators(netuid);
        if (hotkeys.length == 0) revert NoValidatorFound();
        if (hotkeys.length != weights.length || hotkeys.length != owners.length) revert ValidatorSetMalformed();
        set = ValidatorSet({ hotkeys: hotkeys, weights: weights, owners: owners });
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

    /// @dev The counter identifies generations; migrations may rewrite the registration block.
    function _subnetState(uint256 tokenId) private view returns (bool ownGeneration, bool registered, bool dissolving) {
        uint16 netuid = VaultMath.netuidOf(tokenId);
        ISubnet subnet = ISubnet(SUBNET_PRECOMPILE);
        ownGeneration = subnet.getRegisteredSubnetCounter(netuid) == VaultMath.generationOf(tokenId);
        registered = subnet.getNetworkRegistrationBlock(netuid) != 0;
        dissolving = subnet.isSubnetDissolving(netuid);
    }

    /// @dev Whether the token's generation is gone; reverts while it is still being cleaned up.
    function isDissolved(uint256 tokenId) internal view returns (bool) {
        (bool ownGeneration, bool registered, bool dissolving) = _subnetState(tokenId);
        if (ownGeneration && dissolving) revert SubnetInDissolutionBlackoutPeriod();
        return !ownGeneration || !registered;
    }

    /// @dev Alpha balances are in flux from the start of dissolution on.
    function isDissolvingOrDissolved(uint256 tokenId) internal view returns (bool) {
        (bool ownGeneration, bool registered, bool dissolving) = _subnetState(tokenId);
        return dissolving || !ownGeneration || !registered;
    }

    function isDissolving(uint16 netuid) internal view returns (bool) {
        return ISubnet(SUBNET_PRECOMPILE).isSubnetDissolving(netuid);
    }

    function requireNotDissolving(uint16 netuid) internal view {
        if (isDissolving(netuid)) revert SubnetInDissolutionBlackoutPeriod();
    }

    /// @dev A transfer the chain will refuse burns every unit of gas forwarded to it; refuse it here.
    function requireTransfersEnabled(uint16 netuid) internal view {
        (,,,,,,,,, bool transfersEnabled,,) = ISubnet(SUBNET_PRECOMPILE).getSubnetCapacityConfig(netuid);
        if (!transfersEnabled) revert AlphaTransfersDisabled(netuid);
    }

    /// @dev TAO arriving during/after dissolution backs redemptions, not the claim index.
    function indexableTao(uint256 tokenId, uint256 balance, uint256 reserved) internal view returns (uint256) {
        uint256 newTao = VaultMath.unreservedTao(balance, reserved);
        if (newTao == 0) return 0;
        if (isDissolvingOrDissolved(tokenId)) return 0;
        return newTao;
    }

    /// @dev `logical` is the attested name; `active` is the recorded stake location, possibly a successor.
    ///      During recovery, only the parking slot carries the pooled tracked obligation.
    struct Slot {
        bytes32 logical;
        bytes32 active;
        uint256 tracked;
    }

    struct Backing {
        bytes32[] keys;
        uint256[] balances;
        bool[] short;
        uint256 total;
    }

    function logicalsOf(Slot[] memory slots) internal pure returns (bytes32[] memory logicals) {
        logicals = new bytes32[](slots.length);
        for (uint256 i; i < slots.length;) {
            logicals[i] = slots[i].logical;
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Accepted accounting dust; smaller discrepancies do not start recovery.
    uint256 internal constant TRACKED_SLACK_RAO = 1e3;

    /// @dev Resolves at most one successor hop from each recorded active key, without writing it back.
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
                    _followSwap(backing.keys, i, tracked, coldkey, netuid);
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

    /// @dev Follow only a successor covering the whole slot. Ignore old-key residue and reject
    ///      shared successors so one balance never backs two slots. Use alpha, not today's TAO price.
    function _followSwap(bytes32[] memory keys, uint256 index, uint256 tracked, bytes32 coldkey, uint16 netuid)
        private
        view
        returns (bool, bytes32, uint256)
    {
        bytes32 successor = hotkeySuccessor(keys[index], netuid);
        if (successor == bytes32(0)) return (false, bytes32(0), 0);
        if (VaultMath.contains(keys, successor)) return (false, bytes32(0), 0);
        uint256 successorBalance = IStaking(STAKING_PRECOMPILE).getStake(successor, coldkey, netuid);
        if (!coversTracked(successorBalance, tracked)) return (false, bytes32(0), 0);
        return (true, successor, successorBalance);
    }

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

    function firstShortOf(bool[] memory short) internal pure returns (uint256) {
        for (uint256 i; i < short.length;) {
            if (short[i]) return i;
            unchecked {
                ++i;
            }
        }
        return NO_SHORT_SLOT;
    }

    function requireIntact(Slot[] memory slots, Backing memory backing, uint16 netuid) internal pure {
        uint256 shortIndex = firstShortOf(backing.short);
        if (shortIndex != NO_SHORT_SLOT) {
            revert BackingShortfall(netuid, slots[shortIndex].active, slots[shortIndex].tracked);
        }
    }

    function coversTracked(uint256 stake, uint256 tracked) internal pure returns (bool) {
        return stake + TRACKED_SLACK_RAO >= tracked;
    }
}
