// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVault } from "./AlphaVault.sol";
import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";
import { VaultMath } from "./libraries/VaultMath.sol";
import { VaultReads } from "./libraries/VaultReads.sol";
import {
    NetuidOutOfRange,
    NoSharesOutstanding,
    Parked,
    SharePriceBelowPrecision,
    ShortfallOnFile,
    SubnetDissolved,
    ZeroAddress
} from "./VaultErrors.sol";

/// @dev Quotes share the vault's math, but do not guarantee a call will execute.
///      Use a trusted build; `vault()` alone does not authenticate the lens.
///      Reads during callbacks can observe mid-operation state.
contract AlphaVaultLens {
    AlphaVault public immutable vault;
    IValidatorRegistry public immutable validatorRegistry;

    constructor(AlphaVault _vault) {
        if (address(_vault) == address(0)) revert ZeroAddress();
        vault = _vault;
        validatorRegistry = _vault.validatorRegistry();
    }

    /// @dev Rejects missing backing and a loss on file, as the vault's priced operations do, except
    ///      during/after dissolution when alpha balances are in flux.
    function totalStake(uint256 tokenId) public view returns (uint256) {
        if (_shortSince(tokenId) != 0) revert ShortfallOnFile();
        (VaultReads.Slot[] memory slots, VaultReads.Backing memory backing) = _readBacking(tokenId);
        VaultReads.requireIntact(slots, backing, VaultMath.netuidOf(tokenId));
        return backing.total;
    }

    /// @notice Located alpha, including when a shortfall makes `totalStake` revert.
    function locatedStake(uint256 tokenId) external view returns (uint256) {
        (, VaultReads.Backing memory backing) = _readBacking(tokenId);
        return backing.total;
    }

    /// @notice Recorded active keys, before resolving any new swap.
    function lastSeenHotkeys(uint256 tokenId) external view returns (bytes32[] memory) {
        return VaultReads.activesOf(vault.recordedSlots(tokenId));
    }

    /// @dev Checks backing coverage and the shortfall clock, not hotkey ownership or withdrawal
    ///      eligibility. Dissolving/dissolved positions bypass the coverage check.
    function isBackingIntact(uint256 tokenId) external view returns (bool) {
        if (_shortSince(tokenId) != 0) return false;
        (, VaultReads.Backing memory backing) = _readBacking(tokenId);
        return VaultReads.firstShortOf(backing.short) == type(uint256).max;
    }

    /// @return deadline When `syncBacking` may write the declared shortfall down; zero while the position
    ///         accounts for itself, max uint256 while a shortfall is still undeclared.
    /// @dev Expiry only permits the write-off; only `syncBacking` clears or finalizes a shortfall.
    function frozenUntil(uint256 tokenId) external view returns (uint256 deadline) {
        uint64 shortSince = _shortSince(tokenId);
        if (shortSince != 0) return shortSince + vault.recoveryWindow();
        (, VaultReads.Backing memory backing) = _readBacking(tokenId);
        if (VaultReads.firstShortOf(backing.short) != type(uint256).max) deadline = type(uint256).max;
    }

    /// @notice Whether the position rests on the vault's parking hotkey with deposits and alignment shut.
    function awaitingAttestation(uint256 tokenId) external view returns (bool) {
        return vault.awaitingAttestation(tokenId);
    }

    /// @dev Dissolution converts alpha to TAO; do not treat that drain as missing backing.
    function _readBacking(uint256 tokenId)
        private
        view
        returns (VaultReads.Slot[] memory slots, VaultReads.Backing memory backing)
    {
        address clone = vault.subnetClone(tokenId);
        if (clone == address(0)) return (slots, backing);
        uint16 netuid = VaultMath.netuidOf(tokenId);
        bytes32 coldkey = VaultReads.coldkeyOf(clone);
        if (VaultReads.isIssuedForDissolvedSubnet(tokenId) || VaultReads.isDissolving(netuid)) {
            bytes32[] memory keys = VaultReads.activesOf(vault.recordedSlots(tokenId));
            backing.total = VaultMath.sumBalances(VaultReads.fetchBalances(keys, coldkey, netuid));
            return (slots, backing);
        }
        slots = vault.recordedSlots(tokenId);
        backing = VaultReads.resolveBacking(slots, coldkey, netuid);
    }

    /// @notice Alpha per share, scaled by 1e18, including virtual offsets.
    /// @dev Zero backing quotes zero; positive backing below quote precision reverts.
    ///      `previewUnwrap` can still price a larger burn.
    function sharePrice(uint256 tokenId) external view returns (uint256) {
        _requireCurrentRegistration(tokenId);
        uint256 supply = vault.totalSupply(tokenId);
        if (supply == 0) revert NoSharesOutstanding();
        uint256 stake = totalStake(tokenId);
        // Do not let the virtual asset imply value after a complete write-off.
        if (stake == 0) return 0;
        uint256 price = VaultMath.assetsFor(stake, supply, 1e18);
        if (price == 0) revert SharePriceBelowPrecision();
        return price;
    }

    function previewWrap(uint256 tokenId, uint256 assets) external view returns (uint256) {
        _requireCurrentRegistration(tokenId);
        if (vault.awaitingAttestation(tokenId)) revert Parked();
        return VaultMath.sharesFor(totalStake(tokenId), vault.totalSupply(tokenId), assets);
    }

    /// @notice Nominal alpha RAO for a live exit, or TAO wei for a dissolved exit.
    /// @dev Excludes claimable TAO and does not quote `unwrapForTao`.
    ///      Chain rounding can reduce alpha credit; ownership, transfer and size checks may still reject an exit.
    ///      A zero quote does not authorize a zero payout: the caller must set `minAlphaOut` to zero.
    function previewUnwrap(uint256 tokenId, uint256 shares) external view returns (uint256 alpha, uint256 tao) {
        if (shares == 0) return (0, 0);
        address clone = vault.subnetClone(tokenId);
        if (clone == address(0)) return (0, 0);
        uint256 supply = vault.totalSupply(tokenId);
        if (supply == 0) return (0, 0);

        uint16 netuid = VaultMath.netuidOf(tokenId);
        VaultReads.requireNotHeldByDissolution(tokenId);

        if (VaultReads.isIssuedForDissolvedSubnet(tokenId)) {
            uint256 backing = VaultMath.unreservedTao(clone.balance, vault.taoLiability(tokenId));
            if (backing == 0) revert SubnetDissolved();
            return (0, VaultMath.toNativeQuantum(VaultMath.proRata(backing, shares, supply)));
        }

        VaultReads.resolveValidators(validatorRegistry, netuid);

        return (VaultMath.assetsFor(totalStake(tokenId), supply, shares), 0);
    }

    /// @notice Claimable TAO in EVM wei, including pending accrual, rounded down to whole RAO.
    function claimableTaoOf(address account, uint256 tokenId) external view returns (uint256) {
        return _claimableTaoOf(account, tokenId);
    }

    function batchClaimableTaoOf(address account, uint256[] calldata tokenIds)
        external
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            amounts[i] = _claimableTaoOf(account, tokenIds[i]);
        }
    }

    function _claimableTaoOf(address account, uint256 tokenId) private view returns (uint256) {
        uint256 liability = vault.taoLiability(tokenId);
        (uint256 indexIncrease, uint256 liabilityIncrease) = _previewSyncTao(tokenId, liability);
        uint256 index = vault.cumulativeTaoPerShare(tokenId) + indexIncrease;
        uint256 backing = liability + liabilityIncrease;
        uint256 entitlement = vault.claimableTao(tokenId, account) + _pendingAt(account, tokenId, index);
        return VaultMath.toNativeQuantum(VaultMath.backedEntitlement(entitlement, backing));
    }

    function getCurrentValidators(uint256 netuid) external view returns (bytes32[] memory) {
        if (netuid > type(uint16).max) revert NetuidOutOfRange();
        // forge-lint: disable-next-line(unsafe-typecast)
        (bytes32[] memory hotkeys,,) = VaultReads.resolveValidators(validatorRegistry, uint16(netuid));
        return hotkeys;
    }

    function _shortSince(uint256 tokenId) private view returns (uint64 shortSince) {
        (shortSince,) = vault.recovery(tokenId);
    }

    /// @dev Check the blackout first: a registration block cleared mid-cleanup is not a settled refund.
    function _requireCurrentRegistration(uint256 tokenId) private view {
        VaultReads.requireNotHeldByDissolution(tokenId);
        if (VaultReads.isIssuedForDissolvedSubnet(tokenId)) revert SubnetDissolved();
    }

    function _previewSyncTao(uint256 tokenId, uint256 liability) private view returns (uint256, uint256) {
        address clone = vault.subnetClone(tokenId);
        if (clone == address(0)) return (0, 0);
        uint256 newTao = VaultReads.indexableTao(tokenId, clone.balance, liability);
        if (newTao == 0) return (0, 0);
        return VaultMath.syncAmounts(newTao, vault.totalSupply(tokenId));
    }

    function _pendingAt(address account, uint256 tokenId, uint256 index) private view returns (uint256) {
        return VaultMath.pendingTao(
            VaultMath.earnedAt(vault.balanceOf(account, tokenId), index), vault.taoIndexDebt(tokenId, account)
        );
    }
}
