// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IStaking, STAKING_PRECOMPILE } from "../interfaces/IStaking.sol";
import { IValidatorRegistry } from "../interfaces/IValidatorRegistry.sol";
import { IAddressMapping, ADDRESS_MAPPING_PRECOMPILE } from "../interfaces/IAddressMapping.sol";
import { ISubnet, SUBNET_PRECOMPILE } from "../interfaces/ISubnet.sol";
import { VaultMath } from "./VaultMath.sol";
import { NoValidatorFound, SubnetInDissolutionBlackoutPeriod, ValidatorSetMalformed } from "../VaultErrors.sol";

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
        // The registry interface guarantees matching lengths; a registry that breaks it would
        // otherwise surface as a panic deep inside weight alignment, after stake has moved.
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

    /// @dev The whole stake behind a position. The registry read is deliberately unchecked: a
    ///      position whose validator set was withdrawn still holds the alpha its remembered slots
    ///      name, and reporting no backing for it would be wrong. Callers that must instead refuse
    ///      an unconfigured subnet resolve the set themselves and pass it to `unionStake`.
    function backingStake(IValidatorRegistry registry, bytes32[] memory lastSeen, bytes32 coldkey, uint16 netuid)
        internal
        view
        returns (bytes32[] memory hotkeys, uint256[] memory balances, uint256 total)
    {
        (bytes32[] memory current,) = registry.getValidators(netuid);
        return unionStake(lastSeen, current, coldkey, netuid);
    }

    /// @dev Per-hotkey stake across the remembered and current validator sets, with its total. A view
    ///      has no chance to consolidate first, so it must count stake wherever it sits: between a
    ///      registry commit and the next vault call the whole position is on validators the set no
    ///      longer names, and reading only the current set would report no backing at all.
    function unionStake(bytes32[] memory lastSeen, bytes32[] memory current, bytes32 coldkey, uint16 netuid)
        internal
        view
        returns (bytes32[] memory hotkeys, uint256[] memory balances, uint256 total)
    {
        hotkeys = VaultMath.unionSlots(lastSeen, current);
        balances = fetchBalances(hotkeys, coldkey, netuid);
        total = VaultMath.sumBalances(balances);
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

    /// @dev One record per validator the position is spread across. `logical` is the identity the
    ///      registry assigns weight to; `active` is the key actually holding the alpha - they start
    ///      equal and diverge when a hotkey swap moves the stake. `tracked` is the alpha the
    ///      position is expected to account for, re-read from the chain at every settle.
    ///      `shortSince` is when a write first saw the slot fail to account for itself, zero while
    ///      it does; the recovery window runs per slot from here.
    struct Slot {
        bytes32 logical;
        bytes32 active;
        uint256 tracked;
        uint64 shortSince;
    }

    /// @dev One reading of a position: the keys it can see, what it cannot account for, and the
    ///      located total. Carried as a struct because the coverage build compiles at minimum
    ///      optimization, where returning the parts separately runs the stack out.
    struct Plan {
        bytes32[] keys;
        bool[] unaccounted;
        uint256 total;
        uint256 shortIndex;
    }

    /// @dev The chain's share arithmetic credits any position a few RAO short of the amount asked
    ///      for, its own hotkey-swap migration included, so expectations are compared with this
    ///      much give rather than for equality.
    uint256 internal constant TRACKED_SLACK_RAO = 1e3;

    /// @dev How long anyone has to point the vault at missing alpha before the record gives up on
    ///      it. Deposits and quotes wait this out; exits, mailbox reclaims and TAO claims stay open
    ///      throughout, so the wait costs only new money coming in. Each slot's loss runs its own
    ///      window, so a second loss never restarts a clock already running, and nothing that
    ///      merely moves balances between keys can touch a deadline.
    uint256 internal constant RECOVERY_WINDOW = 3 hours;

    /// @dev Reads the position and decides, without writing anything, whether the record still
    ///      accounts for it. `keys` is the union - recorded active keys first, so slot `i` and
    ///      entry `i` line up - with any hotkey swap this pass would follow already applied.
    ///      Shared by the vault's rails and the lens's quotes, so what counts as accounted for is
    ///      decided in a single place.
    function planBacking(Slot[] memory slots, bytes32[] memory currentSet, bytes32 coldkey, uint16 netuid)
        internal
        view
        returns (Plan memory plan)
    {
        plan.keys = VaultMath.unionSlots(activesOf(slots), currentSet);
        uint256[] memory balances = fetchBalances(plan.keys, coldkey, netuid);
        plan.total = VaultMath.sumBalances(balances);
        plan.shortIndex = type(uint256).max;

        uint256 count = slots.length;
        plan.unaccounted = new bool[](count);
        for (uint256 i; i < count;) {
            uint256 tracked = slots[i].tracked;
            if (balances[i] + TRACKED_SLACK_RAO < tracked) {
                (bool accounted, uint256 found) = _accountForSlot(slots, i, netuid, coldkey, plan.keys, count, tracked);
                plan.total += found;
                if (!accounted) {
                    if (plan.shortIndex == type(uint256).max) plan.shortIndex = i;
                    // The settle that follows re-reads every slot from the chain, which would file
                    // this loss as an ordinary balance change. Flagging the slot keeps its
                    // expectation standing until the alpha is found or its window has run.
                    plan.unaccounted[i] = true;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev What became of one slot's missing alpha, decided on what the chain recorded rather
    ///      than on what the position is worth today.
    ///
    ///      One case resolves itself: the recorded key has a successor edge, no other slot leans
    ///      on that successor, and the successor holds what the record expects. That is the
    ///      ordinary validator hotkey swap, and it clears itself.
    ///
    ///      Every other shortfall stands, the chain's own dust sweep included. A missing edge is
    ///      no evidence of one, because the chain drops a key's successor as soon as that key is
    ///      registered again - so an operator who swaps away and re-registers can erase the trail
    ///      behind them. Standing shortfalls clear through someone naming where the alpha went, or
    ///      through the recovery window running out on it.
    ///
    ///      Deliberately no price and no threshold: judging a past event by today's valuation gets
    ///      it wrong in both directions as the market moves.
    function _accountForSlot(
        Slot[] memory slots,
        uint256 index,
        uint16 netuid,
        bytes32 coldkey,
        bytes32[] memory keys,
        uint256 count,
        uint256 tracked
    ) private view returns (bool accounted, uint256 found) {
        bytes32 active = slots[index].active;
        (bool exists, bytes32 next) = IStaking(STAKING_PRECOMPILE).getHotkeySuccessor(active, netuid);
        if (!exists || next == active) return (false, 0);
        // An edge says the alpha moved. Two slots cannot lean on one balance, so a successor
        // another slot already holds or has already claimed this pass reads as unaccounted for.
        if (VaultMath.contains(activesOf(slots), next) || VaultMath.keysHold(keys, 0, count, next)) {
            return (false, 0);
        }
        uint256 stake = IStaking(STAKING_PRECOMPILE).getStake(next, coldkey, netuid);
        if (stake + TRACKED_SLACK_RAO < tracked) return (false, 0);
        // A successor the attesters already name sits in the union and is counted there; claiming
        // it still has to be exclusive, which rewriting the key below records.
        found = VaultMath.keysHold(keys, count, keys.length, next) ? 0 : stake;
        keys[index] = next;
        return (true, found);
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

    /// @dev The first slot the plan cannot account for whose recovery window has not run out - a
    ///      window not yet started cannot have. `type(uint256).max` when none stands. The rails
    ///      that could mint refuse on this, and every quote refuses on the same call, so a quote
    ///      never promises what the call would refuse.
    function firstStandingShortfall(Slot[] memory slots, Plan memory plan) internal view returns (uint256) {
        for (uint256 i; i < plan.unaccounted.length;) {
            if (plan.unaccounted[i]) {
                uint64 shortSince = slots[i].shortSince;
                // forge-lint: disable-next-line(block-timestamp)
                if (shortSince == 0 || block.timestamp < shortSince + RECOVERY_WINDOW) return i;
            }
            unchecked {
                ++i;
            }
        }
        return type(uint256).max;
    }
}
