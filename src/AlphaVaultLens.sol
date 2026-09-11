// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVault } from "./AlphaVault.sol";
import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";
import { VaultMath } from "./libraries/VaultMath.sol";
import { VaultReads } from "./libraries/VaultReads.sol";
import {
    NetuidOutOfRange,
    LockedBacking,
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
    /// @dev Every vault and precompile value a backing reading needs, fetched once per external call.
    ///      An absent clone leaves `slots` and `backing` empty.
    struct BackingRead {
        address clone;
        uint16 netuid;
        bytes32 coldkey;
        bool alphaInFlux;
        VaultReads.Slot[] slots;
        VaultReads.Backing backing;
    }

    AlphaVault public immutable vault;
    IValidatorRegistry public immutable validatorRegistry;

    constructor(AlphaVault _vault) {
        if (address(_vault) == address(0)) revert ZeroAddress();
        vault = _vault;
        validatorRegistry = _vault.validatorRegistry();
    }

    /// @dev Rejects missing backing and a loss on file, as the vault's priced operations do, except
    ///      during/after dissolution when alpha balances are in flux. Refuses unexpected conviction locks.
    function totalStake(uint256 tokenId) public view returns (uint256) {
        if (_shortSince(tokenId) != 0) revert ShortfallOnFile();
        return _intactStakeOf(_readBacking(tokenId));
    }

    /// @notice Located alpha, including when a shortfall makes `totalStake` revert.
    function locatedStake(uint256 tokenId) external view returns (uint256) {
        return _readBacking(tokenId).backing.total;
    }

    /// @notice Unlocated alpha relative to the recorded obligation.
    /// @dev Dust at recorded keys reduces this amount, even if it cannot be parked and is later written off.
    function missingStake(uint256 tokenId) external view returns (uint256) {
        BackingRead memory read = _readBacking(tokenId);
        uint256 expected;
        for (uint256 i; i < read.slots.length; ++i) {
            expected += read.slots[i].tracked;
        }
        return expected > read.backing.total ? expected - read.backing.total : 0;
    }

    /// @notice The recorded keys resolved one successor hop each, as a TAO exit reads them before selling.
    /// @dev A slot marked short makes that exit revert; `keys[i]` is the key slot `i` sells from.
    function resolvedBacking(uint256 tokenId) external view returns (VaultReads.Backing memory backing) {
        address clone = vault.subnetClone(tokenId);
        if (clone == address(0)) return backing;
        return VaultReads.resolveBacking(
            vault.recordedSlots(tokenId), VaultReads.coldkeyOf(clone), VaultMath.netuidOf(tokenId)
        );
    }

    /// @notice Recorded active keys, before resolving any new swap.
    function lastSeenHotkeys(uint256 tokenId) external view returns (bytes32[] memory) {
        return VaultReads.activesOf(vault.recordedSlots(tokenId));
    }

    /// @dev Checks backing coverage and the shortfall clock, not hotkey ownership or withdrawal
    ///      eligibility. Dissolving/dissolved positions bypass the coverage check.
    function isBackingIntact(uint256 tokenId) external view returns (bool) {
        if (_shortSince(tokenId) != 0) return false;
        return VaultReads.firstShortOf(_readBacking(tokenId).backing.short) == VaultReads.NO_SHORT_SLOT;
    }

    /// @return deadline Write-off time, zero if intact, or VaultReads.UNDECLARED_SHORTFALL.
    /// @dev Collection starts a fixed window; below-floor piles may stay behind.
    ///      Expiry permits a write-off by syncBacking; it does not finalize recovery.
    function frozenUntil(uint256 tokenId) external view returns (uint256 deadline) {
        uint64 shortSince = _shortSince(tokenId);
        if (shortSince != 0) return shortSince + vault.recoveryWindow();
        if (VaultReads.firstShortOf(_readBacking(tokenId).backing.short) != VaultReads.NO_SHORT_SLOT) {
            deadline = VaultReads.UNDECLARED_SHORTFALL;
        }
    }

    /// @notice Whether deposits and weight alignment await an attestation newer than the parking one.
    /// @dev Alpha can rest on the parking hotkey after this turns false, until the next wrap, rebalance or alpha
    ///      exit moves it.
    function awaitingAttestation(uint256 tokenId) external view returns (bool) {
        return vault.awaitingAttestation(tokenId);
    }

    function _readBacking(uint256 tokenId) private view returns (BackingRead memory read) {
        read.netuid = VaultMath.netuidOf(tokenId);
        read.clone = vault.subnetClone(tokenId);
        if (read.clone == address(0)) return read;
        _locateBacking(read, tokenId, VaultReads.isDissolvingOrDissolved(tokenId));
    }

    /// @dev Dissolution converts alpha to TAO; do not treat that drain as missing backing.
    function _locateBacking(BackingRead memory read, uint256 tokenId, bool alphaInFlux) private view {
        read.coldkey = VaultReads.coldkeyOf(read.clone);
        read.alphaInFlux = alphaInFlux;
        if (alphaInFlux) {
            bytes32[] memory keys = VaultReads.activesOf(vault.recordedSlots(tokenId));
            read.backing.total = VaultMath.sumBalances(VaultReads.fetchBalances(keys, read.coldkey, read.netuid));
            return;
        }
        read.slots = vault.recordedSlots(tokenId);
        read.backing = VaultReads.resolveBacking(read.slots, read.coldkey, read.netuid);
    }

    /// @dev Alpha in flux during dissolution carries no lock to check.
    function _intactStakeOf(BackingRead memory read) private view returns (uint256) {
        VaultReads.requireIntact(read.slots, read.backing, read.netuid);
        if (read.clone != address(0) && !read.alphaInFlux && VaultReads.lockedAlphaOf(read.coldkey, read.netuid) != 0) {
            revert LockedBacking();
        }
        return read.backing.total;
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
        uint256 price = VaultMath.assetsFor(stake, supply, VaultMath.SHARE_PRICE_SCALE);
        if (price == 0) revert SharePriceBelowPrecision();
        return price;
    }

    function previewWrap(uint256 tokenId, uint256 assets) external view returns (uint256) {
        _requireCurrentRegistration(tokenId);
        VaultReads.requireTransfersEnabled(VaultMath.netuidOf(tokenId));
        if (vault.awaitingAttestation(tokenId)) revert Parked();
        return VaultMath.sharesFor(totalStake(tokenId), vault.totalSupply(tokenId), assets);
    }

    /// @notice Nominal alpha RAO for a live exit, or TAO wei for a dissolved exit.
    /// @dev Excludes claimable TAO, does not quote `unwrapForTao`, and does not consult the registry.
    ///      Chain rounding can reduce alpha credit; ownership, transfer, size and registry checks may
    ///      still reject an exit.
    ///      A zero quote does not authorize a zero payout: the caller must set `minAlphaOut` to zero.
    function previewUnwrap(uint256 tokenId, uint256 shares) external view returns (uint256 alpha, uint256 tao) {
        if (shares == 0) return (0, 0);
        BackingRead memory read;
        read.netuid = VaultMath.netuidOf(tokenId);
        read.clone = vault.subnetClone(tokenId);
        if (read.clone == address(0)) return (0, 0);
        uint256 supply = vault.totalSupply(tokenId);
        if (supply == 0) return (0, 0);

        if (VaultReads.isDissolved(tokenId)) {
            uint256 backing = VaultMath.unreservedTao(read.clone.balance, vault.taoLiability(tokenId));
            if (backing == 0) revert SubnetDissolved();
            return (0, VaultMath.toNativeQuantum(VaultMath.proRata(backing, shares, supply)));
        }

        VaultReads.requireTransfersEnabled(read.netuid);
        if (_shortSince(tokenId) != 0) revert ShortfallOnFile();
        // Passing the dissolution check means this generation is live and its alpha is not in flux.
        _locateBacking(read, tokenId, false);

        return (VaultMath.assetsFor(_intactStakeOf(read), supply, shares), 0);
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

    function _requireCurrentRegistration(uint256 tokenId) private view {
        if (VaultReads.isDissolved(tokenId)) revert SubnetDissolved();
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
