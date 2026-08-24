// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVault } from "./AlphaVault.sol";
import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";
import { VaultMath } from "./libraries/VaultMath.sol";
import { VaultReads } from "./libraries/VaultReads.sol";
import { NetuidOutOfRange, NoSharesOutstanding, SubnetDissolved, ZeroAddress } from "./VaultErrors.sol";

/// @title AlphaVaultLens
/// @notice Every quote an `AlphaVault` integrator needs: backing, share price, deposit and exit
///         previews, claimable TAO and the configured validator set.
/// @dev    Holds no state and has no privileges: it reads the vault's public getters and the same
///         chain state the vault reads, through the same libraries, so a lens and a vault built
///         from one source agree by construction. That agreement belongs to the build rather than
///         to the pairing: a lens compiled from changed library source still answers for the same
///         vault while computing differently, and any contract at all can return the right address
///         from `vault()`. The address to read quotes from is therefore one to take from a trusted
///         source and pin, and its runtime code is worth comparing against a reviewed build.
///         Being separate is what keeps the quotes changeable: the vault is immutable and has no
///         admin, so anything living inside it is frozen for good, while a lens can be redeployed
///         against the same vault whenever a quote needs to improve.
contract AlphaVaultLens {
    AlphaVault public immutable vault;
    /// @notice The registry the vault takes its validator sets from, resolved once at construction
    ///         because the vault holds it immutably.
    IValidatorRegistry public immutable validatorRegistry;

    constructor(AlphaVault _vault) {
        if (address(_vault) == address(0)) revert ZeroAddress();
        vault = _vault;
        validatorRegistry = _vault.validatorRegistry();
    }

    /// @notice Total alpha backing this token's shares. Returns 0 before the clone exists.
    /// @dev    While subtensor dissolution cleanup runs for the netuid the backing alpha is in
    ///         flux; treat the value as unstable whenever `isSubnetDissolving(netuid)` is true.
    /// @param  tokenId ERC1155 tokenId identifying the (netuid, registrationBlock) position.
    /// @return Alpha staked under the clone for this token.
    function totalStake(uint256 tokenId) public view returns (uint256) {
        address clone = vault.subnetClone(tokenId);
        if (clone == address(0)) return 0;
        uint16 netuid = VaultMath.netuidOf(tokenId);
        (,, uint256 total) = VaultReads.backingStake(
            validatorRegistry, vault.lastSeenHotkeys(tokenId), VaultReads.coldkeyOf(clone), netuid
        );
        return total;
    }

    /// @notice Price of one share in 1e18 precision, expressed in alpha.
    /// @dev    Reverts `SubnetInDissolutionBlackoutPeriod` while the subnet is being dissolved,
    ///         `SubnetDissolved` once dissolution has completed or
    ///         the tokenId does not correspond to the currently-registered subnet, and
    ///         `NoSharesOutstanding` when no shares have been minted against this tokenId
    ///         (a share price with zero supply has no meaningful value).
    /// @param  tokenId ERC1155 tokenId identifying the (netuid, registrationBlock) position.
    /// @return Price of one share scaled by 1e18.
    function sharePrice(uint256 tokenId) external view returns (uint256) {
        _requireCurrentRegistration(tokenId);
        uint256 supply = vault.totalSupply(tokenId);
        if (supply == 0) revert NoSharesOutstanding();
        return (totalStake(tokenId) * 1e18) / supply;
    }

    /// @notice Preview how many shares would be minted for a deposit of `assets` alpha.
    /// @dev    Reverts `SubnetInDissolutionBlackoutPeriod` during the blackout and
    ///         `SubnetDissolved` for a tokenId whose subnet has been dissolved - deposits
    ///         route through `currentTokenId(netuid)` and cannot land on a stale tokenId.
    /// @param  tokenId ERC1155 tokenId identifying the (netuid, registrationBlock) position.
    /// @param  assets  Amount of alpha being deposited.
    /// @return Number of shares that would be minted.
    function previewWrap(uint256 tokenId, uint256 assets) external view returns (uint256) {
        _requireCurrentRegistration(tokenId);
        return VaultMath.sharesFor(totalStake(tokenId), vault.totalSupply(tokenId), assets);
    }

    /// @notice Preview the unwrap of `shares` for a position.
    /// @dev    Reverts `SubnetInDissolutionBlackoutPeriod` while the subnet is being dissolved
    ///         and `SubnetDissolved` for a dissolved position whose clone holds no TAO refund.
    ///         Live-path delivery is exact to within a few RAO of chain-side share rounding: unwrap
    ///         delivers this amount or reverts, so a sub-floor total is not deliverable here and
    ///         must be exited via unwrapForTao. That voluntary alpha-for-TAO sell is a market order
    ///         with no preview of its own: its payout is bounded by the caller's minTaoOut, not
    ///         quoted here. `tao` is non-zero only for the dissolved-subnet payout. The caller's
    ///         claimable-TAO entitlement is never part of this quote: it survives unwrapping and
    ///         is quoted by `claimableTaoOf`.
    /// @param  tokenId ERC1155 tokenId identifying the (netuid, registrationBlock) position.
    /// @param  shares  Shares being previewed.
    /// @return alpha   Alpha delivered on the live path.
    /// @return tao     Native TAO paid on the dissolved path.
    function previewUnwrap(uint256 tokenId, uint256 shares) external view returns (uint256 alpha, uint256 tao) {
        if (shares == 0) return (0, 0);
        address clone = vault.subnetClone(tokenId);
        if (clone == address(0)) return (0, 0);
        uint256 supply = vault.totalSupply(tokenId);
        if (supply == 0) return (0, 0);

        uint16 netuid = VaultMath.netuidOf(tokenId);
        VaultReads.requireNotDissolving(netuid);

        if (VaultReads.isIssuedForDissolvedSubnet(tokenId)) {
            uint256 backing = VaultMath.unreservedTao(clone.balance, vault.taoLiability(tokenId));
            if (backing == 0) revert SubnetDissolved();
            return (0, VaultMath.proRata(backing, shares, supply));
        }

        // Reverts NoValidatorFound when the registry has no set for this subnet.
        (bytes32[] memory current,) = VaultReads.resolveValidators(validatorRegistry, netuid);

        (,, uint256 totalAlpha) =
            VaultReads.unionStake(vault.lastSeenHotkeys(tokenId), current, VaultReads.coldkeyOf(clone), netuid);
        return (VaultMath.assetsFor(totalAlpha, supply, shares), 0);
    }

    /// @notice TAO withdrawable by `account` for `tokenId` right now: exactly what `claimTao`
    ///         would pay, including entitlement the storage has not settled yet, quoted at the
    ///         granularity a native transfer can deliver.
    function claimableTaoOf(address account, uint256 tokenId) external view returns (uint256) {
        uint256 liability = vault.taoLiability(tokenId);
        (uint256 indexIncrease, uint256 liabilityIncrease) = _previewSyncTao(tokenId, liability);
        uint256 index = vault.cumulativeTaoPerShare(tokenId) + indexIncrease;
        uint256 backing = liability + liabilityIncrease;
        uint256 entitlement = vault.claimableTao(tokenId, account) + _pendingAt(account, tokenId, index);
        return VaultMath.toNativeQuantum(entitlement > backing ? backing : entitlement);
    }

    /// @notice Exactly the subnet's configured validators; reverts when none are configured.
    function getCurrentValidators(uint256 netuid) external view returns (bytes32[] memory) {
        if (netuid > type(uint16).max) revert NetuidOutOfRange();
        // forge-lint: disable-next-line(unsafe-typecast)
        (bytes32[] memory hotkeys,) = VaultReads.resolveValidators(validatorRegistry, uint16(netuid));
        return hotkeys;
    }

    /// @dev Guard for quotes that describe only the currently-registered subnet: the blackout check
    ///      must precede the registration-block comparison so an in-flux registration is never
    ///      classified as dissolved.
    function _requireCurrentRegistration(uint256 tokenId) private view {
        VaultReads.requireNotDissolving(VaultMath.netuidOf(tokenId));
        if (VaultReads.isIssuedForDissolvedSubnet(tokenId)) revert SubnetDissolved();
    }

    /// @dev The increases the vault's next synchronization would record.
    function _previewSyncTao(uint256 tokenId, uint256 liability) private view returns (uint256, uint256) {
        address clone = vault.subnetClone(tokenId);
        if (clone == address(0)) return (0, 0);
        uint256 newTao = VaultReads.indexableTao(tokenId, clone.balance, liability);
        if (newTao == 0) return (0, 0);
        return VaultMath.syncAmounts(newTao, vault.totalSupply(tokenId));
    }

    /// @dev Earned-but-unrecorded TAO for the account at the given index level.
    function _pendingAt(address account, uint256 tokenId, uint256 index) private view returns (uint256) {
        uint256 earnedToDate = VaultMath.earnedAt(vault.balanceOf(account, tokenId), index);
        uint256 debt = vault.taoIndexDebt(tokenId, account);
        return earnedToDate > debt ? earnedToDate - debt : 0;
    }
}
