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

    /// @dev One record per validator the position is spread across. `logical` is the attested
    ///      identity the registry assigns weight to; `active` is the key expected to be holding
    ///      that identity's alpha. They start equal and diverge only when a hotkey swap moves the
    ///      stake before the attesters catch up. `tracked` is the exact balance the last settle
    ///      read at `active`, and `shortSince` is when a call first found that balance missing -
    ///      zero while the slot accounts for itself.
    struct Slot {
        bytes32 logical;
        bytes32 active;
        uint256 tracked;
        uint64 shortSince;
    }

    /// @dev One reading of a record against the chain: the physical key each slot resolves to, what
    ///      sits there, which slots cannot account for themselves, the located total, and the first
    ///      slot whose loss still holds the position shut. Carried as a struct because the coverage
    ///      build compiles at minimum optimization, where returning the parts separately runs the
    ///      stack out.
    struct Backing {
        bytes32[] keys;
        uint256[] balances;
        bool[] short;
        uint256 total;
        uint256 standing;
    }

    /// @dev The chain credits its own transfers, moves and swap migrations a few RAO short of the
    ///      amount asked for, so expectations are compared with this much give rather than for
    ///      equality. It is an accepted ceiling on accounting dust the vault will never chase, not
    ///      a claim that the chain preserves exact equality.
    uint256 internal constant TRACKED_SLACK_RAO = 1e3;

    /// @dev How long a watcher has to point the vault at missing alpha before the record gives up
    ///      on it and the remainder is written off across everyone still holding shares. Each
    ///      slot's loss runs its own window from the call that first recorded it.
    uint256 internal constant RECOVERY_WINDOW = 3 hours;

    /// @dev Reads the record against the chain without writing anything, resolving at most one
    ///      hotkey swap per slot. Shared by the vault's rails and the lens's quotes, so a quote and
    ///      the call it quotes can never disagree about what the position holds.
    function resolveBacking(Slot[] memory slots, bytes32 coldkey, uint16 netuid)
        internal
        view
        returns (Backing memory backing)
    {
        uint256 count = slots.length;
        backing.keys = activesOf(slots);
        backing.balances = new uint256[](count);
        backing.short = new bool[](count);
        backing.standing = type(uint256).max;
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
                    if (backing.standing == type(uint256).max && isWindowStanding(slots[i].shortSince)) {
                        backing.standing = i;
                    }
                }
            }
            backing.balances[i] = balance;
            backing.total += balance;
            unchecked {
                ++i;
            }
        }
    }

    /// @dev The one shortfall that resolves itself: an ordinary validator hotkey swap, read off the
    ///      chain's own successor edge and accepted only when it explains the whole slot.
    ///
    ///      A residual left on the old key is refused rather than followed, because a slot spread
    ///      across two physical keys is more than the record can carry; a watcher consolidates it
    ///      with `recoverStray` instead. A successor another slot already answers for is refused
    ///      too - one balance may never back two expectations. Exactly one edge is read and the
    ///      successor's own successor never is: a deeper trail, an erased edge, an ambiguous or a
    ///      partial case is a shortfall for the watcher to resolve.
    ///
    ///      Deliberately no price and no threshold: judging a past event by today's valuation gets
    ///      it wrong in both directions as the market moves.
    function _followSwap(
        bytes32[] memory keys,
        uint256 index,
        uint256 balance,
        uint256 tracked,
        bytes32 coldkey,
        uint16 netuid
    ) private view returns (bool, bytes32, uint256) {
        if (balance != 0) return (false, bytes32(0), 0);
        bytes32 active = keys[index];
        (bool exists, bytes32 successor) = IStaking(STAKING_PRECOMPILE).getHotkeySuccessor(active, netuid);
        if (!exists || successor == active) return (false, bytes32(0), 0);
        if (VaultMath.contains(keys, successor)) return (false, bytes32(0), 0);
        uint256 successorBalance = IStaking(STAKING_PRECOMPILE).getStake(successor, coldkey, netuid);
        if (!coversTracked(successorBalance, tracked)) return (false, bytes32(0), 0);
        return (true, successor, successorBalance);
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

    /// @dev Whether `stake` accounts for a slot owed `tracked`, with the give the chain's own
    ///      crediting requires.
    function coversTracked(uint256 stake, uint256 tracked) internal pure returns (bool) {
        return stake + TRACKED_SLACK_RAO >= tracked;
    }

    /// @dev Whether a loss recorded at `shortSince` still holds the position shut. A loss nobody
    ///      has recorded yet counts: a deadline cannot pass before it exists, so an unrecorded loss
    ///      blocks until someone calls `syncBacking` to start its clock.
    function isWindowStanding(uint64 shortSince) internal view returns (bool) {
        // forge-lint: disable-next-line(block-timestamp)
        return shortSince == 0 || block.timestamp < shortSince + RECOVERY_WINDOW;
    }

    /// @dev Whether any slot in this reading fails to account for itself, whatever its clock says.
    function isShort(Backing memory backing) internal pure returns (bool) {
        for (uint256 i; i < backing.short.length;) {
            if (backing.short[i]) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }
}
