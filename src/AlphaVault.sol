// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { ERC1155Supply } from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { CloneFactory } from "./CloneFactory.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { CloneBase } from "./CloneBase.sol";
import { SubnetClone } from "./SubnetClone.sol";
import { DepositMailbox } from "./DepositMailbox.sol";
import { IStaking, STAKING_PRECOMPILE } from "./interfaces/IStaking.sol";
import { IAlpha, ALPHA_PRECOMPILE } from "./interfaces/IAlpha.sol";
import { INeuron, NEURON_PRECOMPILE } from "./interfaces/INeuron.sol";
import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";
import { ISubnet, SUBNET_PRECOMPILE } from "./interfaces/ISubnet.sol";
import { VaultAllocation } from "./libraries/VaultAllocation.sol";
import { VaultMath } from "./libraries/VaultMath.sol";
import { VaultReads } from "./libraries/VaultReads.sol";
import {
    AttestedHotkeyRetired,
    BackingUnchanged,
    ChosenHotkeyNotInSet,
    ClaimBelowNativePrecision,
    InsufficientShares,
    LockedDeposit,
    LockedBacking,
    MailboxNotPrepared,
    SubnetCloneNotPrepared,
    NetuidOutOfRange,
    NothingToRecover,
    NothingToUnwrap,
    Parked,
    ParkingHotkeyUnavailable,
    BackingNotSecured,
    ShortfallOnFile,
    SlippageExceeded,
    SlotMaskOutOfRange,
    SubnetNotRegistered,
    SupplyCapExceeded,
    SwappedHotkeyStillAttested,
    WithdrawTooSmall,
    ZeroAddress,
    ZeroAmount,
    ZeroColdkey,
    ZeroHotkey
} from "./VaultErrors.sol";

/// @notice ERC-1155 shares of staked alpha, isolated by subnet registration in vault-controlled clones.
/// @dev No vault admin. Registry signers choose weights; watchers handle unresolved swaps.
///      Missing backing parks the position on the vault's own hotkey until the registry publishes a
///      newer set. See docs/hotkey-swaps.md for the exit restrictions and recovery policy.
contract AlphaVault is ERC1155, ERC1155Supply, ReentrancyGuard {
    // Keep errors bubbled by VaultAllocation in the vault ABI for callers and decoders.
    error ConsolidationBelowFloor();
    error GatherBelowFloor();
    error DepositTooSmall();
    error CloneProtectionFailed(address clone);
    error CloneContaminated(address candidate);

    /// @dev One shortfall clock per token. A parked position rests on `parkingHotkey` until the
    ///      registry nonce moves past `parkedAtNonce`; zero means the position is not parked.
    struct Recovery {
        uint64 shortSince;
        uint256 parkedAtNonce;
    }

    CloneFactory public immutable cloneFactory;
    IValidatorRegistry public immutable validatorRegistry;
    /// @notice Seconds from a declared shortfall until `syncBacking` may write it off.
    uint256 public immutable recoveryWindow;
    /// @notice Hotkey owned by this contract's coldkey; recovered and written-down positions rest here.
    bytes32 public immutable parkingHotkey;

    mapping(address => mapping(uint256 => address)) private _mailboxes;
    mapping(uint256 => address) public subnetClone;

    mapping(uint256 => VaultReads.Slot[]) private _slots;
    mapping(uint256 => Recovery) public recovery;

    /// @dev Scaled by `TAO_INDEX_PRECISION`; native TAO is accounted separately from alpha backing.
    mapping(uint256 => uint256) public cumulativeTaoPerShare;

    /// @dev Reserved for claims; excluded from dissolved-subnet redemptions.
    mapping(uint256 => uint256) public taoLiability;

    /// @dev Already-settled index earnings for the account's current balance.
    mapping(uint256 => mapping(address => uint256)) public taoIndexDebt;

    mapping(uint256 => mapping(address => uint256)) public claimableTao;

    /// @dev Keeps index-flooring loss below one native quantum and every whole-RAO arrival indexable.
    uint256 private constant SUPPLY_CAP = VaultMath.TAO_NATIVE_QUANTUM * VaultMath.TAO_INDEX_PRECISION;

    event Deposited(address indexed user, uint256 indexed tokenId, uint256 assets, uint256 shares);
    /// @dev `alphaOut` is observed recipient credit in alpha RAO, not the requested transfer.
    event Unwrapped(address indexed user, uint256 indexed tokenId, uint256 shares, uint256 alphaOut);
    /// @dev `taoOut` is native TAO in EVM wei.
    event DissolvedSubnetUnwrapped(address indexed user, uint256 indexed tokenId, uint256 shares, uint256 taoOut);
    /// @dev Weight-alignment moves only; excludes consolidation and payout-gather hops.
    event Rebalanced(uint256 indexed tokenId, bytes32 indexed fromHotkey, bytes32 indexed toHotkey, uint256 amount);
    event SubnetProxyCreated(uint256 indexed tokenId, address clone);
    event MailboxCreated(address indexed user, uint256 indexed netuid, address mailbox);
    /// @dev Net of refunds; `taoOut` is EVM wei. A full burn's empty-vault refund rate can mint
    ///      more shares than were burned, in which case the event's `shares` is zero.
    event UnwrappedForTao(
        address indexed user, uint256 indexed tokenId, uint256 shares, uint256 alphaSold, uint256 taoOut
    );
    event MailboxAlphaSoldForTao(
        address indexed user, uint256 indexed netuid, bytes32 indexed hotkey, uint256 alpha, uint256 taoOut
    );
    /// @dev `amount` is native TAO in EVM wei.
    event TaoClaimed(address indexed user, uint256 indexed tokenId, address recipient, uint256 amount);
    /// @dev The fixed window starts only after located backing has been secured on parking.
    event BackingShortfallDeclared(uint256 indexed tokenId, uint256 expected, uint256 located);
    event BackingShortfallCleared(uint256 indexed tokenId);
    /// @dev Loss falls on holders at write-off; later recovery belongs to holders at recovery time.
    event BackingWrittenOff(uint256 indexed tokenId, uint256 expected, uint256 located);
    /// @dev The position rests on the parking hotkey until an attestation newer than `registryNonce` lands.
    event BackingParked(uint256 indexed tokenId, uint256 backing, uint256 registryNonce);
    event BackingRecovered(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 amount);

    constructor(
        string memory _uri,
        address _mailboxLogic,
        address _subnetLogic,
        address _validatorRegistry,
        uint256 _recoveryWindow,
        bytes32 _parkingHotkey
    ) ERC1155(_uri) {
        if (_mailboxLogic == address(0) || _subnetLogic == address(0) || _validatorRegistry == address(0)) {
            revert ZeroAddress();
        }
        if (_recoveryWindow == 0) revert ZeroAmount();
        if (_parkingHotkey == bytes32(0)) revert ZeroHotkey();
        INeuron(NEURON_PRECOMPILE).tryAssociateHotkey(_parkingHotkey);
        if (!VaultReads.ownedBy(_parkingHotkey, VaultReads.coldkeyOf(address(this)))) {
            revert ParkingHotkeyUnavailable();
        }
        cloneFactory = new CloneFactory(_mailboxLogic, _subnetLogic);
        validatorRegistry = IValidatorRegistry(_validatorRegistry);
        recoveryWindow = _recoveryWindow;
        parkingHotkey = _parkingHotkey;
    }

    /// @dev Low 16 bits identify the netuid; upper bits identify its registration, isolating reused netuids.
    function currentTokenId(uint256 netuid) public view returns (uint256) {
        if (netuid > type(uint16).max) revert NetuidOutOfRange();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 nid = uint16(netuid);
        ISubnet subnet = ISubnet(SUBNET_PRECOMPILE);
        if (subnet.getNetworkRegistrationBlock(nid) == 0) revert SubnetNotRegistered();
        return uint256(nid) | (uint256(subnet.getRegisteredSubnetCounter(nid)) << VaultMath.NETUID_BITS);
    }

    /// @notice Prepare a protected mailbox before sending alpha. The first caller also prepares
    ///         the shared subnet clone. A fresh random UID lets a rejected candidate be retried.
    function createMailbox(uint256 netuid, bytes32 uid) external nonReentrant returns (address mailbox, address clone) {
        return VaultAllocation.prepareClones(cloneFactory, subnetClone, _mailboxes, currentTokenId(netuid), netuid, uid);
    }

    /// @notice Zero until `createMailbox` succeeds.
    function getDepositAddress(address user, uint256 netuid) public view returns (address) {
        if (netuid > type(uint16).max) revert NetuidOutOfRange();
        return _mailboxes[user][netuid];
    }

    /// @notice Whether deposits and weight alignment wait for an attestation newer than the parking one.
    function awaitingAttestation(uint256 tokenId) public view returns (bool) {
        uint256 parkedAtNonce = recovery[tokenId].parkedAtNonce;
        return parkedAtNonce != 0 && validatorRegistry.nonces(VaultMath.netuidOf(tokenId)) == parkedAtNonce;
    }

    /// @notice Collect the caller's mailbox stake under one currently attested hotkey and mint shares.
    /// @dev Consolidates dropped validators and aligns weights. Unresolved backing blocks collection;
    ///      use mailbox reclaim if a swap or registry update leaves the deposit under an unlisted key.
    ///      A mailbox holding conviction-locked alpha is refused; reclaim it to a coldkey that accepts locks.
    function wrap(uint256 netuid, bytes32 chosenHotkey, uint256 minSharesOut) external nonReentrant {
        if (chosenHotkey == bytes32(0)) revert ZeroHotkey();

        uint256 tokenId = currentTokenId(netuid);
        if (awaitingAttestation(tokenId)) revert Parked();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 nid = uint16(netuid);
        VaultReads.requireNotDissolving(nid);
        VaultReads.requireTransfersEnabled(nid);
        (bytes32[] memory hotkeys, uint16[] memory weights, bytes32[] memory owners) =
            VaultReads.resolveValidators(validatorRegistry, nid);
        uint256 chosenIndex = VaultMath.indexOf(hotkeys, chosenHotkey);
        if (chosenIndex == VaultMath.INDEX_NOT_FOUND) revert ChosenHotkeyNotInSet();

        address clone = subnetClone[tokenId];
        if (clone == address(0)) revert SubnetCloneNotPrepared();

        address userClone = _requireMailbox(msg.sender, netuid);
        bytes32 destColdkey = VaultReads.coldkeyOf(clone);
        (VaultReads.Slot[] memory slots, VaultReads.Backing memory backing) = _openBacking(tokenId, destColdkey, nid);
        bytes32[] memory actives = _assignFundableActives(slots, backing, hotkeys, owners, nid);

        (uint256 totalDeposit, uint256 alphaPriceE18) = VaultAllocation.admitDeposit(userClone, chosenHotkey, nid);

        uint256 heldBefore = IStaking(STAKING_PRECOMPILE).getStake(chosenHotkey, destColdkey, nid);
        // A fresh deposit can carry rotated-out dust through above-floor consolidation hops.
        _flush(userClone, chosenHotkey, destColdkey, nid, totalDeposit);
        // Mint pricing reads only active keys; move the deposit onto one before pricing. Anything else
        // sitting on a superseded name is a stray for recovery, not part of this mint.
        if (!VaultMath.contains(actives, chosenHotkey)) {
            uint256 landed = IStaking(STAKING_PRECOMPILE).getStake(chosenHotkey, destColdkey, nid) - heldBefore;
            _move(clone, chosenHotkey, actives[chosenIndex], nid, landed);
        }
        VaultAllocation.consolidateRotatedStake(clone, destColdkey, nid, backing.keys, actives, alphaPriceE18, false);
        VaultAllocation.rebalance(tokenId, clone, actives, weights, destColdkey, alphaPriceE18);
        uint256 totalAlpha = _settle(tokenId, destColdkey, hotkeys, actives);

        uint256 preStake = totalAlpha > totalDeposit ? totalAlpha - totalDeposit : 0;
        uint256 shares = VaultMath.sharesFor(preStake, totalSupply(tokenId), totalDeposit);
        if (shares == 0) revert ZeroAmount();
        if (shares < minSharesOut) revert SlippageExceeded(shares);
        // Repeated recapitalization of written-off shares can approach the index precision bound.
        if (totalSupply(tokenId) + shares > SUPPLY_CAP) revert SupplyCapExceeded();

        _mint(msg.sender, tokenId, shares, "");

        emit Deposited(msg.sender, tokenId, totalDeposit, shares);
    }

    /// @notice Redeem for staked alpha while live, or native TAO after dissolution.
    /// @dev Alpha exits consolidate dropped validators before payout and align the remainder afterwards.
    ///      A parked position pays from the parking hotkey and stays parked.
    /// @param minAlphaOut Minimum observed alpha RAO. Zero also permits dissolved TAO payout or
    ///                    burning worthless shares, forfeiting their claim on later-recovered alpha.
    function unwrap(uint256 tokenId, uint256 shares, bytes32 userSubstrateColdkey, uint256 minAlphaOut)
        external
        nonReentrant
    {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender, tokenId) < shares) revert InsufficientShares();
        uint16 netuid = VaultMath.netuidOf(tokenId);
        address clone = subnetClone[tokenId];

        if (VaultReads.isDissolved(tokenId)) {
            if (minAlphaOut != 0) revert SlippageExceeded(0);
            _unwrapFromDissolvedSubnet(tokenId, shares, clone);
        } else {
            if (userSubstrateColdkey == bytes32(0)) revert ZeroColdkey();
            _unwrapFromLiveSubnet(tokenId, shares, userSubstrateColdkey, clone, netuid, minAlphaOut);
        }
    }

    /// @notice Sell backing for native TAO; prefer `unwrap` to avoid moving the pool price.
    /// @dev Sells from recorded keys without registry alignment. Pool fees and price impact apply.
    ///      Unsold alpha is refunded as shares, except a full-supply burn discards a sub-floor remainder.
    ///      Full drains bypass the stake minimum, not ownership, backing or pool checks.
    /// @param minTaoOut Minimum native TAO in EVM wei (18 decimals, unlike alpha's 9).
    function unwrapForTao(uint256 tokenId, uint256 shares, uint256 minTaoOut) external nonReentrant {
        _unwrapForTao(tokenId, shares, minTaoOut, 0);
    }

    /// @notice `unwrapForTao` that leaves the recorded slots named in `excludedSlots` unsold.
    /// @dev Bit `i` excludes slot `i` of `recordedSlots(tokenId)` as the record stands at execution.
    ///      The pool refuses a sale it cannot pay for, and a refused precompile call burns all the gas
    ///      forwarded to it, so callers quote each slot off chain and exclude the ones the pool turns
    ///      down. Entitlement still counts every slot; what an excluded slot would have sold refunds
    ///      as shares under the usual rules.
    function unwrapForTao(uint256 tokenId, uint256 shares, uint256 minTaoOut, uint256 excludedSlots)
        external
        nonReentrant
    {
        _unwrapForTao(tokenId, shares, minTaoOut, excludedSlots);
    }

    function _unwrapForTao(uint256 tokenId, uint256 shares, uint256 minTaoOut, uint256 excludedSlots) private {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender, tokenId) < shares) revert InsufficientShares();
        address clone = subnetClone[tokenId];
        uint16 netuid = VaultMath.netuidOf(tokenId);
        if (VaultReads.isDissolved(tokenId)) revert NothingToUnwrap();

        bytes32 vaultColdkey = VaultReads.coldkeyOf(clone);
        (, VaultReads.Backing memory backing) = _openBacking(tokenId, vaultColdkey, netuid);
        bytes32[] memory hotkeys = backing.keys;
        if (excludedSlots >> hotkeys.length != 0) revert SlotMaskOutOfRange();
        uint256[] memory balances = backing.balances;
        uint256 total = backing.total;
        if (total == 0) revert NothingToUnwrap();

        uint256 supply = totalSupply(tokenId);
        // Exact backing makes every full-supply sale a floor-exempt full drain; virtual rounding would not.
        uint256 assets = shares == supply ? total : VaultMath.assetsFor(total, supply, shares);
        if (assets == 0) revert ZeroAmount();

        _burn(msg.sender, tokenId, shares);

        uint256 balanceBefore = clone.balance;
        uint256 dustThresholdTao = IStaking(STAKING_PRECOMPILE).getNominatorMinRequiredStake();
        // Full drains precede partials so a shrunken partial cannot consume a later floor-exempt drain.
        uint256 remaining = _sellRound(clone, netuid, hotkeys, balances, excludedSlots, assets, dustThresholdTao, false);
        _sellRound(clone, netuid, hotkeys, balances, excludedSlots, remaining, dustThresholdTao, true);

        uint256 taoOut = clone.balance - balanceBefore;
        if (taoOut == 0) revert WithdrawTooSmall();
        if (taoOut < minTaoOut) revert SlippageExceeded(taoOut);

        // Underflow rejects a sale that swept other holders' backing into this caller's payout.
        uint256[] memory postBalances = VaultReads.fetchBalances(hotkeys, vaultColdkey, netuid);
        uint256 sold = total - VaultMath.sumBalances(postBalances);
        _reanchor(tokenId, hotkeys, postBalances);
        uint256 unsold = assets - sold;
        // Do not refund a full exit as fresh sub-floor dust; partial refunds merge with remaining shares.
        if (unsold != 0 && shares == supply) {
            uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);
            if (_isBelowFloorAtReadPrice(unsold, alphaPriceE18)) unsold = 0;
        }

        SubnetClone(payable(clone)).unwrapTao(payable(msg.sender), taoOut);

        // Pay before minting: proceeds still on the clone would otherwise enter the claim index.
        uint256 refundShares = VaultMath.sharesFor(total - assets, supply - shares, unsold);
        if (refundShares != 0) _mint(msg.sender, tokenId, refundShares, "");
        // With no shares left there is nothing to keep parked.
        if (totalSupply(tokenId) == 0) delete recovery[tokenId];

        emit UnwrappedForTao(msg.sender, tokenId, refundShares < shares ? shares - refundShares : 0, sold, taoOut);
    }

    /// @dev Claims survive transfers and full exits, including dissolution. Sub-RAO residue stays reserved.
    function claimTao(uint256 tokenId, address payable recipient) external nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        _syncTao(tokenId);
        _checkpoint(msg.sender, tokenId, cumulativeTaoPerShare[tokenId]);
        uint256 entitlement = claimableTao[tokenId][msg.sender];
        uint256 liability = taoLiability[tokenId];
        // Keep any entitlement beyond the current liability recorded, not erased.
        uint256 amount = VaultMath.backedEntitlement(entitlement, liability);
        if (amount == 0) revert ZeroAmount();
        amount = VaultMath.toNativeQuantum(amount);
        if (amount == 0) revert ClaimBelowNativePrecision();
        claimableTao[tokenId][msg.sender] = entitlement - amount;
        taoLiability[tokenId] = liability - amount;
        SubnetClone(payable(subnetClone[tokenId])).unwrapTao(recipient, amount);
        emit TaoClaimed(msg.sender, tokenId, recipient, amount);
    }

    function _unwrapFromLiveSubnet(
        uint256 tokenId,
        uint256 shares,
        bytes32 userSubstrateColdkey,
        address clone,
        uint16 netuid,
        uint256 minAlphaOut
    ) private {
        VaultReads.requireTransfersEnabled(netuid);
        bytes32 coldkey = VaultReads.coldkeyOf(clone);
        (VaultReads.Slot[] memory slots, VaultReads.Backing memory backing) = _openBacking(tokenId, coldkey, netuid);
        bytes32[] memory hotkeys;
        uint16[] memory weights;
        bytes32[] memory owners;
        bytes32[] memory actives;
        bytes32 retired;
        if (awaitingAttestation(tokenId)) {
            // A parked position pays from the parking hotkey and stays there.
            hotkeys = backing.keys;
            actives = backing.keys;
            weights = new uint16[](1);
        } else {
            (hotkeys, weights, owners) = VaultReads.resolveValidators(validatorRegistry, netuid);
            (actives, retired) = _assignActives(slots, backing, hotkeys, owners, netuid);
            // Conservatively block all dropped-stake consolidation if any receiving entry is unusable.
            if (retired != bytes32(0) && _holdsRotatedOutStake(backing, actives)) {
                revert AttestedHotkeyRetired(retired);
            }
        }
        // No pool trades on this path, so one price read covers all moves.
        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);
        VaultAllocation.consolidateRotatedStake(clone, coldkey, netuid, backing.keys, actives, alphaPriceE18, false);

        uint256[] memory balances = VaultReads.fetchBalances(actives, coldkey, netuid);
        uint256 totalAlpha = VaultMath.sumBalances(balances);
        // Zero floor explicitly forfeits these shares' claim on late recovery; accrued TAO survives.
        if (totalAlpha == 0) {
            if (minAlphaOut != 0) revert SlippageExceeded(0);
            _burn(msg.sender, tokenId, shares);
            _settle(tokenId, coldkey, hotkeys, actives);
            emit Unwrapped(msg.sender, tokenId, shares, 0);
            return;
        }

        uint256 supply = totalSupply(tokenId);
        // Partial exits must retain weight alignment, even if an unusable entry's move would be sub-floor.
        if (retired != bytes32(0) && shares != supply) revert AttestedHotkeyRetired(retired);
        uint256 assets = VaultMath.assetsFor(totalAlpha, supply, shares);
        if (assets == 0) revert ZeroAmount();
        if (assets < minAlphaOut) revert SlippageExceeded(assets);

        if (_isBelowFloorAtReadPrice(assets, alphaPriceE18)) {
            revert WithdrawTooSmall();
        }

        _burn(msg.sender, tokenId, shares);
        uint256 alphaOut = VaultAllocation.deliverAndAlign(
            tokenId, clone, actives, weights, balances, coldkey, userSubstrateColdkey, assets, alphaPriceE18
        );
        if (alphaOut < minAlphaOut) revert SlippageExceeded(alphaOut);
        _settle(tokenId, coldkey, hotkeys, actives);

        emit Unwrapped(msg.sender, tokenId, shares, alphaOut);
    }

    function _unwrapFromDissolvedSubnet(uint256 tokenId, uint256 shares, address clone) private {
        uint256 backing = VaultMath.unreservedTao(clone.balance, taoLiability[tokenId]);
        if (backing == 0) revert NothingToUnwrap();

        // Sub-RAO residue stays in the refund pot for remaining holders.
        uint256 userTao = VaultMath.toNativeQuantum(VaultMath.proRata(backing, shares, totalSupply(tokenId)));
        if (userTao == 0) revert ClaimBelowNativePrecision();
        _burn(msg.sender, tokenId, shares);
        SubnetClone(payable(clone)).unwrapTao(payable(msg.sender), userTao);
        emit DissolvedSubnetUnwrapped(msg.sender, tokenId, shares, userTao);
    }

    /// @dev Consolidates dropped validators first; weight-alignment moves below the floor or at zero price skip.
    ///      The first call after a newer attestation moves a parked position back onto the attested set.
    function rebalance(uint256 netuid) external nonReentrant {
        uint256 tokenId = currentTokenId(netuid);
        address clone = subnetClone[tokenId];
        if (clone == address(0)) return;
        if (awaitingAttestation(tokenId)) revert Parked();

        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 nid = uint16(netuid);
        VaultReads.requireNotDissolving(nid);
        (bytes32[] memory hotkeys, uint16[] memory weights, bytes32[] memory owners) =
            VaultReads.resolveValidators(validatorRegistry, nid);
        bytes32 coldkey = VaultReads.coldkeyOf(clone);
        (VaultReads.Slot[] memory slots, VaultReads.Backing memory backing) = _openBacking(tokenId, coldkey, nid);
        bytes32[] memory actives = _assignFundableActives(slots, backing, hotkeys, owners, nid);
        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(nid);
        VaultAllocation.consolidateRotatedStake(clone, coldkey, nid, backing.keys, actives, alphaPriceE18, false);
        VaultAllocation.rebalance(tokenId, clone, actives, weights, coldkey, alphaPriceE18);
        _settle(tokenId, coldkey, hotkeys, actives);
    }

    /// @notice Reclaim native TAO from the caller's prepared mailbox, including after dissolution.
    function reclaimTaoFromMailbox(uint256 netuid) external nonReentrant {
        address predicted = _requireMailbox(msg.sender, netuid);
        uint256 amount = predicted.balance;
        if (amount == 0) revert ZeroAmount();
        DepositMailbox(payable(predicted)).unwrapTao(payable(msg.sender), amount);
    }

    /// @dev Unlike wrapping, reclaim accepts hotkeys outside the current registry set. A locked mailbox
    ///      empties only into a coldkey that accepts locked alpha; the lock moves with the alpha.
    function reclaimAlphaFromMailbox(uint256 netuid, bytes32 hotkey, bytes32 destSubstrateColdkey)
        external
        nonReentrant
    {
        if (hotkey == bytes32(0)) revert ZeroHotkey();
        if (destSubstrateColdkey == bytes32(0)) revert ZeroColdkey();

        address predicted = _requireMailbox(msg.sender, netuid);
        bytes32 mailboxColdkey = VaultReads.coldkeyOf(predicted);
        uint256 amount = IStaking(STAKING_PRECOMPILE).getStake(hotkey, mailboxColdkey, netuid);
        if (amount == 0) revert ZeroAmount();

        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 nid = uint16(netuid);
        VaultReads.requireTransfersEnabled(nid);
        // The chain refuses a locked transfer into a rejecting coldkey and burns the forwarded gas.
        if (
            VaultReads.lockedAlphaOf(mailboxColdkey, nid) != 0
                && IStaking(STAKING_PRECOMPILE).getRejectLockedAlpha(destSubstrateColdkey)
        ) revert LockedDeposit();
        _flush(predicted, hotkey, destSubstrateColdkey, nid, amount);
    }

    /// @param minTaoOut Minimum native TAO in EVM wei.
    function reclaimMailboxAlphaAsTao(uint256 netuid, bytes32 hotkey, uint256 minTaoOut) external nonReentrant {
        if (netuid > type(uint16).max) revert NetuidOutOfRange();
        if (hotkey == bytes32(0)) revert ZeroHotkey();
        address mailbox = _requireMailbox(msg.sender, netuid);
        bytes32 mailboxColdkey = VaultReads.coldkeyOf(mailbox);
        uint256 amount = IStaking(STAKING_PRECOMPILE).getStake(hotkey, mailboxColdkey, netuid);
        if (amount == 0) revert ZeroAmount();
        // Locked alpha cannot be sold; the chain would refuse and burn the forwarded gas.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (VaultReads.lockedAlphaOf(mailboxColdkey, uint16(netuid)) != 0) revert LockedDeposit();

        uint256 balanceBefore = mailbox.balance;
        // forge-lint: disable-next-line(unsafe-typecast)
        _sell(mailbox, hotkey, uint16(netuid), amount);

        uint256 taoOut = mailbox.balance - balanceBefore;
        if (taoOut < minTaoOut) revert SlippageExceeded(taoOut);
        DepositMailbox(payable(mailbox)).unwrapTao(payable(msg.sender), taoOut);
        emit MailboxAlphaSoldForTao(msg.sender, netuid, hotkey, amount, taoOut);
    }

    function _isRotatedOut(bytes32 hotkey, bytes32[] memory currentSet) private pure returns (bool) {
        return !VaultMath.contains(currentSet, hotkey);
    }

    function _taoValue(uint256 alphaAmount, uint256 alphaPriceE18) private pure returns (uint256) {
        return (alphaAmount * alphaPriceE18) / VaultMath.ALPHA_PRICE_SCALE;
    }

    /// @dev The only exposed minimum is for unstakes; using it for transfers/moves is conservative.
    function _minStakeTao() private view returns (uint256) {
        return IStaking(STAKING_PRECOMPILE).getDefaultMinStake();
    }

    /// @dev A rounded-down price can reject a valid amount. Zero proves nothing; full unstakes must bypass this.
    function _isBelowFloorAtReadPrice(uint256 alphaAmount, uint256 alphaPriceE18) private view returns (bool) {
        return alphaPriceE18 != 0 && _taoValue(alphaAmount, alphaPriceE18) < _minStakeTao();
    }

    function _sellRound(
        address clone,
        uint16 netuid,
        bytes32[] memory hotkeys,
        uint256[] memory balances,
        uint256 excludedSlots,
        uint256 remaining,
        uint256 dustThresholdTao,
        bool includePartials
    ) private returns (uint256) {
        for (uint256 i; i < hotkeys.length && remaining != 0;) {
            uint256 balance = (excludedSlots >> i) & 1 == 0 ? balances[i] : 0;
            uint256 chunk;
            if (balance <= remaining) {
                chunk = balance;
            } else if (includePartials) {
                chunk = _sellableChunk(netuid, remaining, balance, dustThresholdTao);
            }
            if (chunk != 0) {
                _sell(clone, hotkeys[i], netuid, chunk);
                balances[i] = balance - chunk;
                remaining -= chunk;
            }
            unchecked {
                ++i;
            }
        }
        return remaining;
    }

    /// @dev Partial sales must clear the post-fee minimum without leaving dust the chain would force-sell
    ///      into this caller's payout at the remaining holders' expense.
    function _sellableChunk(uint16 netuid, uint256 remaining, uint256 balance, uint256 dustThresholdTao)
        private
        view
        returns (uint256)
    {
        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);
        if (alphaPriceE18 == 0) return 0;

        // One extra RAO covers the leftover quote's rounding.
        uint256 minLeftover = dustThresholdTao == 0
            ? 0
            : Math.ceilDiv((dustThresholdTao + 1) * VaultMath.ALPHA_PRICE_SCALE, alphaPriceE18);
        if (balance <= minLeftover) return 0;

        uint256 maxChunk = balance - minLeftover;
        uint256 chunk = maxChunk < remaining ? maxChunk : remaining;
        // Keep gas-consuming simulation failures away from provably sub-floor inputs.
        if (_isBelowFloorAtReadPrice(chunk, alphaPriceE18)) return 0;

        uint256 chunkQuote = IAlpha(ALPHA_PRECOMPILE).simSwapAlphaForTao(netuid, _saturateU64(chunk));
        if (chunkQuote < _minStakeTao()) return 0;

        // The marginal quote bounds leftover value at the post-sale price. A saturated u64 quote is not faithful.
        if (dustThresholdTao != 0 && balance <= type(uint64).max) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 leftoverQuote = IAlpha(ALPHA_PRECOMPILE).simSwapAlphaForTao(netuid, uint64(balance)) - chunkQuote;
            if (leftoverQuote < dustThresholdTao) return 0;
        }
        return chunk;
    }

    function _saturateU64(uint256 value) private pure returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return value > type(uint64).max ? type(uint64).max : uint64(value);
    }

    function _holdsRotatedOutStake(VaultReads.Backing memory backing, bytes32[] memory currentSet)
        private
        pure
        returns (bool)
    {
        for (uint256 i; i < backing.keys.length;) {
            if (backing.balances[i] != 0 && _isRotatedOut(backing.keys[i], currentSet)) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /// @notice Collect the vault's alpha from one caller-supplied hotkey.
    /// @dev Sync declares and finalizes recovery; collection preserves its obligation and deadline.
    ///      With no shortfall, recovered alpha joins live backing, including after write-off.
    function recoverStray(uint256 tokenId, bytes32 source) external nonReentrant {
        address clone = subnetClone[tokenId];
        if (clone == address(0)) revert NothingToUnwrap();
        uint16 netuid = VaultMath.netuidOf(tokenId);
        if (VaultReads.isDissolved(tokenId)) revert NothingToRecover();
        if (_slots[tokenId].length == 0 || source == bytes32(0)) revert NothingToRecover();
        bytes32 coldkey = VaultReads.coldkeyOf(clone);
        bytes32[] memory sources = new bytes32[](1);
        sources[0] = source;
        if (recovery[tokenId].shortSince == 0) {
            (, VaultReads.Backing memory backing) = _openBacking(tokenId, coldkey, netuid);
            if (VaultMath.contains(backing.keys, source)) revert NothingToRecover();
            _annex(tokenId, clone, coldkey, netuid, backing.keys, sources);
            return;
        }
        if (source == parkingHotkey) revert NothingToRecover();
        uint256 before = IStaking(STAKING_PRECOMPILE).getStake(parkingHotkey, coldkey, netuid);
        uint256 parked = _secureBacking(clone, coldkey, netuid, sources);
        if (parked <= before) revert NothingToRecover();
        emit BackingRecovered(tokenId, parkingHotkey, parked - before);
    }

    /// @dev Keep resolved keys and old-key residue locations.
    function _collectionKeys(bytes32[] memory raw, bytes32[] memory resolved) private pure returns (bytes32[] memory) {
        bytes32[] memory extra = VaultAllocation.novelSources(resolved, raw);
        return VaultMath.concat(resolved, extra);
    }

    /// @dev Below-floor piles may stay exposed until write-off. Other collection failures revert.
    ///      A movable parking balance carries even sub-floor sources through consolidation.
    function _secureBacking(address clone, bytes32 coldkey, uint16 netuid, bytes32[] memory keys)
        private
        returns (uint256 parked)
    {
        bool leftBelowFloor;
        (parked, leftBelowFloor) = _gather(clone, coldkey, netuid, keys, parkingHotkey, true);
        if (leftBelowFloor) return parked;
        // Defensive invariant: a successful collection must drain exposed backing within slack.
        uint256 exposed;
        for (uint256 i; i < keys.length;) {
            if (keys[i] != bytes32(0) && keys[i] != parkingHotkey) {
                exposed += IStaking(STAKING_PRECOMPILE).getStake(keys[i], coldkey, netuid);
            }
            unchecked {
                ++i;
            }
        }
        if (exposed > VaultReads.TRACKED_SLACK_RAO) revert BackingNotSecured();
    }

    /// @dev Only parking carries the pooled obligation; other entries are collection locations.
    function _startRecovery(uint256 tokenId, bytes32[] memory keys, uint256 expected, uint256 parked) private {
        VaultReads.Slot[] storage slots = _slots[tokenId];
        _writeSlot(slots, 0, parkingHotkey, parkingHotkey, expected);
        uint256 count = 1;
        for (uint256 i; i < keys.length;) {
            if (keys[i] != bytes32(0) && keys[i] != parkingHotkey) {
                _writeSlot(slots, count, keys[i], keys[i], 0);
                unchecked {
                    ++count;
                }
            }
            unchecked {
                ++i;
            }
        }
        while (slots.length > count) slots.pop();
        // forge-lint: disable-next-line(block-timestamp)
        recovery[tokenId] = Recovery({ shortSince: uint64(block.timestamp), parkedAtNonce: 0 });
        emit BackingShortfallDeclared(tokenId, expected, parked);
    }

    function _finishRecovery(uint256 tokenId, uint256 parked) private {
        VaultReads.Slot[] storage slots = _slots[tokenId];
        _writeSlot(slots, 0, parkingHotkey, parkingHotkey, parked);
        while (slots.length > 1) slots.pop();
        uint256 nonce = validatorRegistry.nonces(VaultMath.netuidOf(tokenId));
        recovery[tokenId] = Recovery({ shortSince: 0, parkedAtNonce: nonce });
        emit BackingParked(tokenId, parked, nonce);
    }

    /// @dev With no shortfall, add strays to live backing. A movable pile also collects dust.
    function _annex(
        uint256 tokenId,
        address clone,
        bytes32 coldkey,
        uint16 netuid,
        bytes32[] memory keys,
        bytes32[] memory strays
    ) private {
        bytes32 home = keys[0];
        uint256 before = IStaking(STAKING_PRECOMPILE).getStake(home, coldkey, netuid);
        (uint256 balance,) = _gather(clone, coldkey, netuid, strays, home, false);
        if (balance <= before) revert NothingToRecover();
        _reanchor(tokenId, keys, VaultReads.fetchBalances(keys, coldkey, netuid));
        emit BackingRecovered(tokenId, home, balance - before);
    }

    function _gather(
        address clone,
        bytes32 coldkey,
        uint16 netuid,
        bytes32[] memory sources,
        bytes32 destination,
        bool leaveUnmovable
    ) private returns (uint256 balance, bool leftBelowFloor) {
        bytes32[] memory destinations = new bytes32[](1);
        destinations[0] = destination;
        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);
        leftBelowFloor = VaultAllocation.consolidateRotatedStake(
            clone, coldkey, netuid, sources, destinations, alphaPriceE18, leaveUnmovable
        );
        balance = IStaking(STAKING_PRECOMPILE).getStake(destination, coldkey, netuid);
    }

    /// @notice Secure located backing above the floor, then start or finalize one fixed recovery window.
    /// @dev Partial returns are collected into parking without restarting the clock. Full coverage
    ///      ends recovery; after expiry, only the remaining pooled deficit is written off.
    function syncBacking(uint256 tokenId) external nonReentrant {
        address clone = subnetClone[tokenId];
        if (clone == address(0)) revert NothingToUnwrap();
        uint16 netuid = VaultMath.netuidOf(tokenId);
        if (VaultReads.isDissolved(tokenId)) revert BackingUnchanged();
        Recovery storage state = recovery[tokenId];
        VaultReads.Slot[] memory slots = _slots[tokenId];
        bytes32 coldkey = VaultReads.coldkeyOf(clone);
        bytes32[] memory keys = VaultReads.activesOf(slots);
        if (state.shortSince == 0) {
            VaultReads.Backing memory backing = VaultReads.resolveBacking(slots, coldkey, netuid);
            if (VaultReads.firstShortOf(backing.short) == VaultReads.NO_SHORT_SLOT) {
                if (!_followedSwap(slots, backing.keys)) revert BackingUnchanged();
                _reanchor(tokenId, backing.keys, backing.balances);
                return;
            }
            keys = _collectionKeys(keys, backing.keys);
            uint256 initialExpected = _totalTracked(slots);
            uint256 secured = _secureBacking(clone, coldkey, netuid, keys);
            if (VaultReads.coversTracked(secured, initialExpected)) {
                _finishRecovery(tokenId, secured);
            } else {
                _startRecovery(tokenId, keys, initialExpected, secured);
            }
            return;
        }
        uint256 before = IStaking(STAKING_PRECOMPILE).getStake(parkingHotkey, coldkey, netuid);
        uint256 parked = _secureBacking(clone, coldkey, netuid, keys);
        uint256 expected = _totalTracked(slots);
        // forge-lint: disable-next-line(block-timestamp)
        uint256 timestamp = block.timestamp;
        if (VaultReads.coversTracked(parked, expected)) {
            emit BackingShortfallCleared(tokenId);
            _finishRecovery(tokenId, parked);
        } else if (timestamp >= state.shortSince + recoveryWindow) {
            emit BackingWrittenOff(tokenId, expected, parked);
            _finishRecovery(tokenId, parked);
        } else {
            if (parked <= before) revert BackingUnchanged();
            emit BackingRecovered(tokenId, parkingHotkey, parked - before);
        }
    }

    function recordedSlots(uint256 tokenId) external view returns (VaultReads.Slot[] memory) {
        return _slots[tokenId];
    }

    function _followedSwap(VaultReads.Slot[] memory slots, bytes32[] memory keys) private pure returns (bool) {
        for (uint256 i; i < slots.length;) {
            if (slots[i].active != keys[i]) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function _totalTracked(VaultReads.Slot[] memory slots) private pure returns (uint256 total) {
        for (uint256 i; i < slots.length;) {
            total += slots[i].tracked;
            unchecked {
                ++i;
            }
        }
    }

    function _openBacking(uint256 tokenId, bytes32 coldkey, uint16 netuid)
        private
        view
        returns (VaultReads.Slot[] memory slots, VaultReads.Backing memory backing)
    {
        if (recovery[tokenId].shortSince != 0) revert ShortfallOnFile();
        if (VaultReads.lockedAlphaOf(coldkey, netuid) != 0) revert LockedBacking();
        slots = _slots[tokenId];
        backing = VaultReads.resolveBacking(slots, coldkey, netuid);
        // Expiry permits a write-off; it does not authorize deposits or exits to book one implicitly.
        VaultReads.requireIntact(slots, backing, netuid);
    }

    /// @dev Reject unresolved receiving keys before a chain call can consume the forwarded gas.
    function _assignFundableActives(
        VaultReads.Slot[] memory slots,
        VaultReads.Backing memory backing,
        bytes32[] memory currentSet,
        bytes32[] memory owners,
        uint16 netuid
    ) private view returns (bytes32[] memory actives) {
        bytes32 retired;
        (actives, retired) = _assignActives(slots, backing, currentSet, owners, netuid);
        if (retired != bytes32(0)) revert AttestedHotkeyRetired(retired);
    }

    function _assignActives(
        VaultReads.Slot[] memory slots,
        VaultReads.Backing memory backing,
        bytes32[] memory currentSet,
        bytes32[] memory owners,
        uint16 netuid
    ) private view returns (bytes32[] memory actives, bytes32 retired) {
        return VaultAllocation.assignActives(
            VaultReads.logicalsOf(slots), backing.keys, backing.balances, currentSet, owners, netuid
        );
    }

    function _hasOwner(bytes32 hotkey) private view returns (bool exists) {
        (exists,) = IStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkey);
    }

    /// @dev The chain refuses to move stake through a hotkey with no owner record; claim one for the vault.
    function _ensureOwned(bytes32 hotkey) private {
        if (!_hasOwner(hotkey)) INeuron(NEURON_PRECOMPILE).tryAssociateHotkey(hotkey);
    }

    function _move(address clone, bytes32 fromHotkey, bytes32 toHotkey, uint16 netuid, uint256 amount) private {
        _ensureOwned(fromHotkey);
        _ensureOwned(toHotkey);
        SubnetClone(payable(clone)).moveStake(fromHotkey, toHotkey, netuid, amount);
    }

    function _flush(address holder, bytes32 hotkey, bytes32 destColdkey, uint16 netuid, uint256 amount) private {
        _ensureOwned(hotkey);
        CloneBase(payable(holder)).flush(destColdkey, hotkey, netuid, amount);
    }

    function _sell(address holder, bytes32 hotkey, uint16 netuid, uint256 amount) private {
        _ensureOwned(hotkey);
        CloneBase(payable(holder)).sellAlphaForTao(hotkey, netuid, amount);
    }

    /// @dev Replace the record with actual post-move balances; shortfalls were checked on entry.
    function _settle(uint256 tokenId, bytes32 coldkey, bytes32[] memory currentSet, bytes32[] memory actives)
        private
        returns (uint256 total)
    {
        VaultReads.Slot[] storage tokenSlots = _slots[tokenId];
        uint16 netuid = VaultMath.netuidOf(tokenId);
        while (tokenSlots.length > currentSet.length) {
            tokenSlots.pop();
        }
        for (uint256 i; i < currentSet.length;) {
            uint256 tracked = IStaking(STAKING_PRECOMPILE).getStake(actives[i], coldkey, netuid);
            _writeSlot(tokenSlots, i, currentSet[i], actives[i], tracked);
            total += tracked;
            unchecked {
                ++i;
            }
        }
        // An exit paid from the parking hotkey leaves the position parked while shares remain.
        if (!awaitingAttestation(tokenId) || totalSupply(tokenId) == 0) delete recovery[tokenId];
    }

    function _writeSlot(
        VaultReads.Slot[] storage tokenSlots,
        uint256 index,
        bytes32 logical,
        bytes32 active,
        uint256 tracked
    ) private {
        if (index < tokenSlots.length) {
            VaultReads.Slot storage slot = tokenSlots[index];
            if (slot.logical != logical) slot.logical = logical;
            if (slot.active != active) slot.active = active;
            if (slot.tracked != tracked) slot.tracked = tracked;
        } else {
            tokenSlots.push(VaultReads.Slot({ logical: logical, active: active, tracked: tracked }));
        }
    }

    /// @dev Preserve resolved keys even when emptied. Falling back to logical names can merge two slots
    ///      onto one balance after a swap; TAO exits do not apply the current registry.
    function _reanchor(uint256 tokenId, bytes32[] memory keys, uint256[] memory balances) private {
        VaultReads.Slot[] storage tokenSlots = _slots[tokenId];
        for (uint256 i; i < tokenSlots.length;) {
            VaultReads.Slot storage slot = tokenSlots[i];
            if (slot.active != keys[i]) slot.active = keys[i];
            if (slot.tracked != balances[i]) slot.tracked = balances[i];
            unchecked {
                ++i;
            }
        }
    }

    function _requireMailbox(address user, uint256 netuid) private view returns (address mailbox) {
        mailbox = getDepositAddress(user, netuid);
        if (mailbox == address(0)) revert MailboxNotPrepared();
    }

    function _syncTao(uint256 tokenId) private {
        address clone = subnetClone[tokenId];
        if (clone == address(0)) return;
        uint256 balance = clone.balance;
        if (balance == 0) return;
        uint256 newTao = VaultReads.indexableTao(tokenId, balance, taoLiability[tokenId]);
        if (newTao == 0) return;
        (uint256 indexIncrease, uint256 liabilityIncrease) = VaultMath.syncAmounts(newTao, totalSupply(tokenId));
        if (indexIncrease == 0) return;
        cumulativeTaoPerShare[tokenId] += indexIncrease;
        taoLiability[tokenId] += liabilityIncrease;
    }

    function _checkpoint(address account, uint256 tokenId, uint256 index) private {
        uint256 earned = VaultMath.earnedAt(balanceOf(account, tokenId), index);
        uint256 credit = VaultMath.pendingTao(earned, taoIndexDebt[tokenId][account]);
        if (credit != 0) claimableTao[tokenId][account] += credit;
        taoIndexDebt[tokenId][account] = earned;
    }

    function _settleIndexDebt(address account, uint256 tokenId, uint256 index) private {
        taoIndexDebt[tokenId][account] = VaultMath.earnedAt(balanceOf(account, tokenId), index);
    }

    /// @dev Checkpoint pre-transfer balances, then anchor post-transfer debt before acceptance callbacks.
    ///      Repeated ids and self-transfers must not accrue the same TAO twice.
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override(ERC1155, ERC1155Supply)
    {
        for (uint256 i; i < ids.length;) {
            uint256 id = ids[i];
            _syncTao(id);
            uint256 index = cumulativeTaoPerShare[id];
            if (index != 0) {
                if (from != address(0)) _checkpoint(from, id, index);
                if (to != address(0)) _checkpoint(to, id, index);
            }
            unchecked {
                ++i;
            }
        }
        super._update(from, to, ids, values);
        for (uint256 i; i < ids.length;) {
            uint256 id = ids[i];
            uint256 index = cumulativeTaoPerShare[id];
            if (index != 0) {
                if (from != address(0)) _settleIndexDebt(from, id, index);
                if (to != address(0)) _settleIndexDebt(to, id, index);
            }
            unchecked {
                ++i;
            }
        }
    }
}
