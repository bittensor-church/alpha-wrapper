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
///         Never price a position from inside a callback: a quote read while a vault call is in
///         flight can see a mid-operation state.
contract AlphaVaultLens {
    AlphaVault public immutable vault;
    /// @notice The registry the vault takes its validator sets from, resolved once at construction
    ///         because the vault holds it immutably.
    IValidatorRegistry public immutable validatorRegistry;
    /// @notice How long a recorded loss stays recoverable before it may be written off, resolved
    ///         once at construction because the vault holds it immutably.
    uint256 public immutable recoveryWindow;

    constructor(AlphaVault _vault) {
        if (address(_vault) == address(0)) revert ZeroAddress();
        vault = _vault;
        validatorRegistry = _vault.validatorRegistry();
        recoveryWindow = _vault.recoveryWindow();
    }

    /// @notice Total alpha backing this token's shares. Returns 0 before the clone exists.
    /// @dev    Reverts `BackingShortfall` while any backing is unaccounted for: the figure it
    ///         would otherwise give counts only what the vault can locate, so it understates the
    ///         holding and steps back up the moment the alpha is found.
    ///         `locatedStake` gives that figure regardless, and `isBackingIntact` and
    ///         `frozenUntil` report the state without reverting.
    ///
    ///         While the subnet is dissolving the chain is draining the balances, so the value is
    ///         the in-flux total with no shortfall judgment - unstable until
    ///         `isSubnetDissolving(netuid)` clears.
    /// @param  tokenId ERC1155 tokenId identifying the (netuid, registrationBlock) position.
    /// @return Alpha staked under the clone for this token.
    function totalStake(uint256 tokenId) public view returns (uint256) {
        (VaultReads.Slot[] memory slots, VaultReads.Backing memory backing) = _readBacking(tokenId);
        VaultReads.requireIntact(slots, backing, VaultMath.netuidOf(tokenId));
        return backing.total;
    }

    /// @notice Alpha the vault can find for this token, whether or not that is all of it.
    /// @dev    The figure behind `totalStake`, answering where that one refuses. For watching a
    ///         position while a loss is chased, never for valuing a holding.
    function locatedStake(uint256 tokenId) external view returns (uint256) {
        (, VaultReads.Backing memory backing) = _readBacking(tokenId);
        return backing.total;
    }

    /// @notice The keys the position's backing is currently expected under, one per attested
    ///         validator.
    function lastSeenHotkeys(uint256 tokenId) external view returns (bytes32[] memory) {
        return VaultReads.activesOf(vault.recordedSlots(tokenId));
    }

    /// @notice Whether the vault can account for the alpha it expects under every validator it
    ///         records. A hotkey swap it can follow on its own reads true, and so does a
    ///         dissolving subnet: the drain is not a loss to chase.
    /// @dev    False means every rail refuses, and keeps refusing past the deadline until
    ///         `syncBacking` books the loss.
    function isBackingIntact(uint256 tokenId) external view returns (bool) {
        (, VaultReads.Backing memory backing) = _readBacking(tokenId);
        return VaultReads.firstShortOf(backing.short) == type(uint256).max;
    }

    /// @notice When the losses on file become writable off, as a unix timestamp; zero when nothing
    ///         is missing.
    /// @dev    The latest deadline across the slots the vault cannot account for. A loss nobody
    ///         has recorded yet reads `type(uint256).max`, since no deadline exists until someone
    ///         calls `syncBacking` to start one. Past the timestamp the token stays shut until a
    ///         further `syncBacking` books the loss.
    function frozenUntil(uint256 tokenId) external view returns (uint256 deadline) {
        (VaultReads.Slot[] memory slots, VaultReads.Backing memory backing) = _readBacking(tokenId);
        for (uint256 i; i < backing.short.length;) {
            if (backing.short[i]) {
                uint64 shortSince = slots[i].shortSince;
                if (shortSince == 0) return type(uint256).max;
                uint256 slotDeadline = VaultReads.recoveryDeadline(shortSince, recoveryWindow);
                if (slotDeadline > deadline) deadline = slotDeadline;
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev The reading the vault's rails take, never applied. A dissolved or dissolving position
    ///      is simply totalled: its alpha became TAO, or is being drained by the chain, so no
    ///      expectation can be held against it.
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

    /// @notice Price of one share in 1e18 precision, expressed in alpha.
    /// @dev    Reverts `SubnetInDissolutionBlackoutPeriod` while the subnet is being dissolved,
    ///         `SubnetDissolved` once dissolution has completed or
    ///         the tokenId does not correspond to the currently-registered subnet,
    ///         `BackingShortfall` while any backing is unaccounted for, and
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
    /// @dev    Reverts `SubnetInDissolutionBlackoutPeriod` during the blackout,
    ///         `SubnetDissolved` for a tokenId whose subnet has been dissolved - deposits
    ///         route through `currentTokenId(netuid)` and cannot land on a stale tokenId - and
    ///         `BackingShortfall` while any backing is unaccounted for, exactly as `wrap` would.
    /// @param  tokenId ERC1155 tokenId identifying the (netuid, registrationBlock) position.
    /// @param  assets  Amount of alpha being deposited.
    /// @return Number of shares that would be minted.
    function previewWrap(uint256 tokenId, uint256 assets) external view returns (uint256) {
        _requireCurrentRegistration(tokenId);
        return VaultMath.sharesFor(totalStake(tokenId), vault.totalSupply(tokenId), assets);
    }

    /// @notice Preview the unwrap of `shares` for a position.
    /// @dev    Reverts `SubnetInDissolutionBlackoutPeriod` while the subnet is being dissolved,
    ///         `SubnetDissolved` for a dissolved position whose clone holds no TAO refund, and
    ///         `BackingShortfall` while any backing is unaccounted for, exactly as `unwrap` would.
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
        VaultReads.resolveValidators(validatorRegistry, netuid);

        return (VaultMath.assetsFor(totalStake(tokenId), supply, shares), 0);
    }

    /// @notice TAO withdrawable by `account` for `tokenId` right now: exactly what `claimTao`
    ///         would pay, including entitlement the storage has not settled yet, quoted at the
    ///         granularity a native transfer can deliver.
    function claimableTaoOf(address account, uint256 tokenId) external view returns (uint256) {
        return _claimableTaoOf(account, tokenId);
    }

    /// @notice `claimableTaoOf` for a set of positions at once, aligned to `tokenIds`.
    /// @dev    A holder spread across many subnets quotes its whole native entitlement in one
    ///         call. Each position is quoted independently: they share no state, so this is the
    ///         per-position quote repeated, never a different answer from the single-position one.
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
        return VaultMath.pendingTao(
            VaultMath.earnedAt(vault.balanceOf(account, tokenId), index), vault.taoIndexDebt(tokenId, account)
        );
    }
}
