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
}
