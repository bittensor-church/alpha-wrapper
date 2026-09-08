// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { ERC1155Supply } from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
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
    ConsolidationBelowFloor,
    DepositTooSmall,
    GatherBelowFloor,
    InsufficientShares,
    NetuidOutOfRange,
    NothingToRecover,
    NothingToUnwrap,
    Parked,
    ParkingHotkeyUnavailable,
    RecoveryIncomplete,
    ShortfallOnFile,
    SlippageExceeded,
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
    /// @dev One shortfall clock per token. A parked position rests on `parkingHotkey` until the
    ///      registry nonce moves past `parkedAtNonce`.
    struct Recovery {
        uint64 shortSince;
        uint64 parkedAtNonce;
        bool parked;
    }

    address public immutable mailboxLogic;
    address public immutable subnetLogic;
    IValidatorRegistry public immutable validatorRegistry;
    /// @notice Seconds from a declared shortfall until `syncBacking` may write it off.
    uint256 public immutable recoveryWindow;
    /// @notice Hotkey owned by this contract's coldkey; recovered and written-down positions rest here.
    bytes32 public immutable parkingHotkey;

    mapping(address => bool) public cloneDeployed;
    mapping(uint256 => address) public subnetClone;

    mapping(uint256 => VaultReads.Slot[]) private _slots;
    mapping(uint256 => Recovery) private _recovery;

    /// @dev Scaled by `TAO_INDEX_PRECISION`; native TAO is accounted separately from alpha backing.
    mapping(uint256 => uint256) public cumulativeTaoPerShare;

    /// @dev Reserved for claims; excluded from dissolved-subnet redemptions.
    mapping(uint256 => uint256) public taoLiability;

    /// @dev Already-settled index earnings for the account's current balance.
    mapping(uint256 => mapping(address => uint256)) public taoIndexDebt;

    mapping(uint256 => mapping(address => uint256)) public claimableTao;

    uint16 private constant BPS_BASE = 10_000;
    /// @dev The true price is below the rounded-down read plus this quantum.
    uint256 private constant ALPHA_PRICE_QUANTUM_E18 = 1e9;
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
        mailboxLogic = _mailboxLogic;
        subnetLogic = _subnetLogic;
        validatorRegistry = IValidatorRegistry(_validatorRegistry);
        recoveryWindow = _recoveryWindow;
        parkingHotkey = _parkingHotkey;
    }

    /// @dev Low 16 bits identify the netuid; upper bits identify its registration, isolating reused netuids.
    function currentTokenId(uint256 netuid) public view returns (uint256) {
        if (netuid > type(uint16).max) revert NetuidOutOfRange();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 nid = uint16(netuid);
        uint64 registrationBlock = ISubnet(SUBNET_PRECOMPILE).getNetworkRegistrationBlock(nid);
        if (registrationBlock == 0) revert SubnetNotRegistered();
        return uint256(nid) | (uint256(registrationBlock) << 16);
    }

    function createSubnetProxy(uint256 netuid) external {
        uint256 tokenId = currentTokenId(netuid);
        if (subnetClone[tokenId] != address(0)) return;
        _deploySubnetClone(tokenId);
    }

    function getDepositAddress(address user, uint256 netuid) public view returns (address) {
        if (netuid > type(uint16).max) revert NetuidOutOfRange();
        bytes32 salt = _cloneSalt(user, netuid);
        return Clones.predictDeterministicAddress(mailboxLogic, salt, address(this));
    }

    function recovery(uint256 tokenId) external view returns (Recovery memory) {
        return _recovery[tokenId];
    }

    /// @notice Whether deposits and weight alignment wait for an attestation newer than the parking one.
    function awaitingAttestation(uint256 tokenId) public view returns (bool) {
        Recovery storage state = _recovery[tokenId];
        return state.parked && validatorRegistry.nonces(VaultMath.netuidOf(tokenId)) == state.parkedAtNonce;
    }

    /// @notice Collect the caller's mailbox stake under one currently attested hotkey and mint shares.
    /// @dev Consolidates dropped validators and aligns weights. Unresolved backing blocks collection;
    ///      use mailbox reclaim if a swap or registry update leaves the deposit under an unlisted key.
    function wrap(uint256 netuid, bytes32 chosenHotkey, uint256 minSharesOut) external nonReentrant {
        if (chosenHotkey == bytes32(0)) revert ZeroHotkey();

        uint256 tokenId = currentTokenId(netuid);
        if (awaitingAttestation(tokenId)) revert Parked();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 nid = uint16(netuid);
        VaultReads.requireNotDissolving(nid);
        (bytes32[] memory hotkeys, uint16[] memory weights) = VaultReads.resolveValidators(validatorRegistry, nid);
        uint256 chosenIndex = VaultMath.indexOf(hotkeys, chosenHotkey);
        if (chosenIndex == type(uint256).max) revert ChosenHotkeyNotInSet();

        address clone = subnetClone[tokenId];
        if (clone == address(0)) clone = _deploySubnetClone(tokenId);

        address userClone = _ensureMailboxClone(msg.sender, netuid);
        bytes32 destColdkey = VaultReads.coldkeyOf(clone);

        (VaultReads.Slot[] memory slots, VaultReads.Backing memory backing) = _openBacking(tokenId, destColdkey, nid);
        bytes32[] memory actives = _assignFundableActives(slots, backing, hotkeys, nid);

        uint256 totalDeposit = _mailboxBalance(userClone, chosenHotkey, nid);
        if (totalDeposit == 0) revert ZeroAmount();

        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(nid);
        if (_isBelowFloorAtReadPrice(totalDeposit, alphaPriceE18)) {
            revert DepositTooSmall();
        }

        // A fresh deposit can carry rotated-out dust through above-floor consolidation hops.
        _flush(userClone, chosenHotkey, destColdkey, nid, totalDeposit);
        // Mint pricing reads only active keys; move the deposit onto one before pricing.
        if (!VaultMath.contains(actives, chosenHotkey)) {
            _move(
                clone,
                chosenHotkey,
                actives[chosenIndex],
                nid,
                IStaking(STAKING_PRECOMPILE).getStake(chosenHotkey, destColdkey, netuid)
            );
        }
        _consolidateRotatedStake(clone, destColdkey, nid, backing.keys, actives, alphaPriceE18, false);
        _rebalance(tokenId, clone, actives, weights, destColdkey, alphaPriceE18);
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
        VaultReads.requireNotHeldByDissolution(tokenId);
        address clone = subnetClone[tokenId];

        if (VaultReads.isIssuedForDissolvedSubnet(tokenId)) {
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
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender, tokenId) < shares) revert InsufficientShares();
        address clone = subnetClone[tokenId];
        uint16 netuid = VaultMath.netuidOf(tokenId);
        VaultReads.requireNotHeldByDissolution(tokenId);

        if (VaultReads.isIssuedForDissolvedSubnet(tokenId)) revert NothingToUnwrap();

        bytes32 vaultColdkey = VaultReads.coldkeyOf(clone);
        (, VaultReads.Backing memory backing) = _openBacking(tokenId, vaultColdkey, netuid);
        bytes32[] memory hotkeys = backing.keys;
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
        uint256 remaining = _sellRound(clone, netuid, hotkeys, balances, assets, dustThresholdTao, false);
        _sellRound(clone, netuid, hotkeys, balances, remaining, dustThresholdTao, true);

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
        bytes32 coldkey = VaultReads.coldkeyOf(clone);
        (VaultReads.Slot[] memory slots, VaultReads.Backing memory backing) = _openBacking(tokenId, coldkey, netuid);
        bytes32[] memory hotkeys;
        uint16[] memory weights;
        bytes32[] memory actives;
        bytes32 retired;
        if (awaitingAttestation(tokenId)) {
            // A parked position pays from the parking hotkey and stays there.
            hotkeys = backing.keys;
            actives = backing.keys;
            weights = new uint16[](1);
            weights[0] = BPS_BASE;
        } else {
            (hotkeys, weights) = VaultReads.resolveValidators(validatorRegistry, netuid);
            (actives, retired) = _assignActives(slots, backing, hotkeys, netuid);
            // Conservatively block all dropped-stake consolidation if any receiving entry is unusable.
            if (retired != bytes32(0) && _holdsRotatedOutStake(backing, actives)) {
                revert AttestedHotkeyRetired(retired);
            }
        }
        // No pool trades on this path, so one price read covers all moves.
        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);
        _consolidateRotatedStake(clone, coldkey, netuid, backing.keys, actives, alphaPriceE18, false);

        uint256[] memory balances = VaultReads.fetchBalances(actives, coldkey, netuid);
        uint256 totalAlpha = VaultMath.sumBalances(balances);
        // Zero floor explicitly forfeits these shares' claim on late recovery; accrued TAO survives.
        if (totalAlpha == 0) {
            if (minAlphaOut != 0) revert SlippageExceeded(0);
            _settle(tokenId, coldkey, hotkeys, actives);
            _burn(msg.sender, tokenId, shares);
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
        uint256 alphaOut = _deliverAndAlign(
            tokenId, clone, actives, weights, balances, coldkey, userSubstrateColdkey, assets, alphaPriceE18
        );
        if (alphaOut < minAlphaOut) revert SlippageExceeded(alphaOut);
        _settle(tokenId, coldkey, hotkeys, actives);

        emit Unwrapped(msg.sender, tokenId, shares, alphaOut);
    }

    function _deliverAndAlign(
        uint256 tokenId,
        address clone,
        bytes32[] memory hotkeys,
        uint16[] memory weights,
        uint256[] memory balances,
        bytes32 coldkey,
        bytes32 userColdkey,
        uint256 assets,
        uint256 alphaPriceE18
    ) private returns (uint256 alphaOut) {
        uint16 netuid = VaultMath.netuidOf(tokenId);
        uint256 deliveryIndex;
        for (uint256 i = 1; i < balances.length;) {
            if (balances[i] > balances[deliveryIndex]) deliveryIndex = i;
            unchecked {
                ++i;
            }
        }
        // Gather hops can round down, so summed balances cannot determine the final deliverable amount.
        uint256 deliverable = balances[deliveryIndex];
        if (balances[deliveryIndex] < assets) {
            // Start with the largest slot; reject an unmovable pile before forwarding gas to the chain.
            if (_isBelowFloorAtAnyPrice(balances[deliveryIndex], alphaPriceE18)) {
                revert GatherBelowFloor();
            }
            // Re-read every hop: requesting a cached sum can exceed the balance after chain rounding.
            for (uint256 i; i < balances.length && balances[deliveryIndex] < assets;) {
                if (i != deliveryIndex && balances[i] != 0) {
                    uint256 pile = IStaking(STAKING_PRECOMPILE).getStake(hotkeys[deliveryIndex], coldkey, netuid);
                    _move(clone, hotkeys[deliveryIndex], hotkeys[i], netuid, pile);
                    balances[i] += balances[deliveryIndex];
                    balances[deliveryIndex] = 0;
                    deliveryIndex = i;
                }
                unchecked {
                    ++i;
                }
            }
            deliverable = IStaking(STAKING_PRECOMPILE).getStake(hotkeys[deliveryIndex], coldkey, netuid);
        }
        uint256 requested = assets < deliverable ? assets : deliverable;
        alphaOut = _flushMeasured(clone, hotkeys[deliveryIndex], userColdkey, netuid, requested);
        // Chain rounding also changes the balances available to rebalance.
        uint256[] memory postBalances = VaultReads.fetchBalances(hotkeys, coldkey, netuid);
        _alignToWeights(tokenId, clone, hotkeys, weights, postBalances, alphaPriceE18);
    }

    /// @dev Bound slippage against actual recipient credit, including chain-side stake-share rounding.
    function _flushMeasured(address clone, bytes32 hotkey, bytes32 userColdkey, uint16 netuid, uint256 amount)
        private
        returns (uint256)
    {
        uint256 recipientBefore = IStaking(STAKING_PRECOMPILE).getStake(hotkey, userColdkey, netuid);
        _flush(clone, hotkey, userColdkey, netuid, amount);
        uint256 recipientAfter = IStaking(STAKING_PRECOMPILE).getStake(hotkey, userColdkey, netuid);
        return recipientAfter > recipientBefore ? recipientAfter - recipientBefore : 0;
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
        (bytes32[] memory hotkeys, uint16[] memory weights) = VaultReads.resolveValidators(validatorRegistry, nid);
        bytes32 coldkey = VaultReads.coldkeyOf(clone);
        (VaultReads.Slot[] memory slots, VaultReads.Backing memory backing) = _openBacking(tokenId, coldkey, nid);
        bytes32[] memory actives = _assignFundableActives(slots, backing, hotkeys, nid);
        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(nid);
        _consolidateRotatedStake(clone, coldkey, nid, backing.keys, actives, alphaPriceE18, false);
        _rebalance(tokenId, clone, actives, weights, coldkey, alphaPriceE18);
        _settle(tokenId, coldkey, hotkeys, actives);
    }

    function _rebalance(
        uint256 tokenId,
        address clone,
        bytes32[] memory hotkeys,
        uint16[] memory weights,
        bytes32 coldkey,
        uint256 alphaPriceE18
    ) private {
        uint256[] memory balances = VaultReads.fetchBalances(hotkeys, coldkey, VaultMath.netuidOf(tokenId));
        _alignToWeights(tokenId, clone, hotkeys, weights, balances, alphaPriceE18);
    }

    function _alignToWeights(
        uint256 tokenId,
        address clone,
        bytes32[] memory hotkeys,
        uint16[] memory weights,
        uint256[] memory balances,
        uint256 alphaPriceE18
    ) private {
        uint256 total = VaultMath.sumBalances(balances);

        if (weights.length == 1 || total == 0) return;

        uint256 lastIndex = weights.length - 1;
        uint256[] memory targets = new uint256[](weights.length);
        {
            uint256 assigned;
            for (uint256 i; i < lastIndex;) {
                targets[i] = (total * weights[i]) / BPS_BASE;
                assigned += targets[i];
                unchecked {
                    ++i;
                }
            }
            targets[lastIndex] = total - assigned;
        }

        // Each step settles a slot; after N-1 steps the last follows from conservation.
        uint256 minStakeTao = _minStakeTao();
        for (uint256 round; round < lastIndex;) {
            if (!_rebalanceStep(tokenId, clone, hotkeys, balances, targets, alphaPriceE18, minStakeTao)) break;
            unchecked {
                ++round;
            }
        }
    }

    function _rebalanceStep(
        uint256 tokenId,
        address clone,
        bytes32[] memory hotkeys,
        uint256[] memory balances,
        uint256[] memory targets,
        uint256 alphaPriceE18,
        uint256 minStakeTao
    ) private returns (bool) {
        uint256 overIndex;
        uint256 maxOver;
        uint256 underIndex;
        uint256 maxUnder;
        for (uint256 i; i < balances.length;) {
            if (balances[i] > targets[i]) {
                uint256 over = balances[i] - targets[i];
                if (over > maxOver) {
                    maxOver = over;
                    overIndex = i;
                }
            } else if (balances[i] < targets[i]) {
                uint256 under = targets[i] - balances[i];
                if (under > maxUnder) {
                    maxUnder = under;
                    underIndex = i;
                }
            }
            unchecked {
                ++i;
            }
        }

        if (maxOver == 0 || maxUnder == 0) return false;

        uint256 moveAmount = maxOver < maxUnder ? maxOver : maxUnder;
        // A rejected precompile call consumes forwarded gas. Skip unproven moves and tolerate weight drift.
        if (alphaPriceE18 == 0 || _taoValue(moveAmount, alphaPriceE18) < minStakeTao) return false;
        _move(clone, hotkeys[overIndex], hotkeys[underIndex], VaultMath.netuidOf(tokenId), moveAmount);
        emit Rebalanced(tokenId, hotkeys[overIndex], hotkeys[underIndex], moveAmount);
        balances[overIndex] -= moveAmount;
        balances[underIndex] += moveAmount;
        return true;
    }

    /// @dev Deploys the mailbox lazily: refunds can arrive at its predicted address before deployment.
    function reclaimTaoFromMailbox(uint256 netuid) external nonReentrant {
        address predicted = getDepositAddress(msg.sender, netuid);
        uint256 amount = predicted.balance;
        if (amount == 0) revert ZeroAmount();
        _ensureMailboxClone(msg.sender, netuid);
        DepositMailbox(payable(predicted)).unwrapTao(payable(msg.sender), amount);
    }

    /// @dev Unlike wrapping, reclaim accepts hotkeys outside the current registry set.
    function reclaimAlphaFromMailbox(uint256 netuid, bytes32 hotkey, bytes32 destSubstrateColdkey)
        external
        nonReentrant
    {
        if (hotkey == bytes32(0)) revert ZeroHotkey();
        if (destSubstrateColdkey == bytes32(0)) revert ZeroColdkey();

        address predicted = getDepositAddress(msg.sender, netuid);
        bytes32 mailboxColdkey = VaultReads.coldkeyOf(predicted);
        uint256 amount = IStaking(STAKING_PRECOMPILE).getStake(hotkey, mailboxColdkey, netuid);
        if (amount == 0) revert ZeroAmount();

        _ensureMailboxClone(msg.sender, netuid);
        // forge-lint: disable-next-line(unsafe-typecast)
        _flush(predicted, hotkey, destSubstrateColdkey, uint16(netuid), amount);
    }

    /// @param minTaoOut Minimum native TAO in EVM wei.
    function reclaimMailboxAlphaAsTao(uint256 netuid, bytes32 hotkey, uint256 minTaoOut) external nonReentrant {
        if (netuid > type(uint16).max) revert NetuidOutOfRange();
        if (hotkey == bytes32(0)) revert ZeroHotkey();
        address predicted = getDepositAddress(msg.sender, netuid);
        bytes32 mailboxColdkey = VaultReads.coldkeyOf(predicted);
        uint256 amount = IStaking(STAKING_PRECOMPILE).getStake(hotkey, mailboxColdkey, netuid);
        if (amount == 0) revert ZeroAmount();

        _ensureMailboxClone(msg.sender, netuid);
        uint256 balanceBefore = predicted.balance;
        // forge-lint: disable-next-line(unsafe-typecast)
        _sell(predicted, hotkey, uint16(netuid), amount);

        uint256 taoOut = predicted.balance - balanceBefore;
        if (taoOut < minTaoOut) revert SlippageExceeded(taoOut);
        DepositMailbox(payable(predicted)).unwrapTao(payable(msg.sender), taoOut);
        emit MailboxAlphaSoldForTao(msg.sender, netuid, hotkey, amount, taoOut);
    }

    function _isRotatedOut(bytes32 hotkey, bytes32[] memory currentSet) private pure returns (bool) {
        return !VaultMath.contains(currentSet, hotkey);
    }

    function _taoValue(uint256 alphaAmount, uint256 alphaPriceE18) private pure returns (uint256) {
        return (alphaAmount * alphaPriceE18) / 1e18;
    }

    /// @dev The only exposed minimum is for unstakes; using it for transfers/moves is conservative.
    function _minStakeTao() private view returns (uint256) {
        return IStaking(STAKING_PRECOMPILE).getDefaultMinStake();
    }

    /// @dev A rounded-down price can reject a valid amount. Zero proves nothing; full unstakes must bypass this.
    function _isBelowFloorAtReadPrice(uint256 alphaAmount, uint256 alphaPriceE18) private view returns (bool) {
        return alphaPriceE18 != 0 && _taoValue(alphaAmount, alphaPriceE18) < _minStakeTao();
    }

    /// @dev Reject only if the amount is below the floor even at the upper bound hidden by price rounding.
    function _isBelowFloorAtAnyPrice(uint256 alphaAmount, uint256 alphaPriceE18) private view returns (bool) {
        return alphaPriceE18 != 0 && _taoValue(alphaAmount, alphaPriceE18 + ALPHA_PRICE_QUANTUM_E18) < _minStakeTao();
    }

    function _sellRound(
        address clone,
        uint16 netuid,
        bytes32[] memory hotkeys,
        uint256[] memory balances,
        uint256 remaining,
        uint256 dustThresholdTao,
        bool includePartials
    ) private returns (uint256) {
        for (uint256 i; i < hotkeys.length && remaining != 0;) {
            uint256 balance = balances[i];
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
        uint256 minLeftover = dustThresholdTao == 0 ? 0 : Math.ceilDiv((dustThresholdTao + 1) * 1e18, alphaPriceE18);
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

    /// @dev Move all dropped-key backing onto tracked destinations before rewriting the record.
    ///      A write-off leaves an unmovable pile where it is; every other caller refuses it.
    function _consolidateRotatedStake(
        address clone,
        bytes32 coldkey,
        uint16 netuid,
        bytes32[] memory sourceKeys,
        bytes32[] memory currentSet,
        uint256 alphaPriceE18,
        bool leaveUnmovable
    ) private {
        (bytes32 rollerHotkey, uint256 richestBalance, uint256[] memory sourceBalances, bool hasRotatedOutBalance) =
            VaultAllocation.chooseRichestSlot(sourceKeys, currentSet, coldkey, netuid);
        if (!hasRotatedOutBalance) return;
        // The pile starts at the largest balance, then only grows; its starting size bounds every hop.
        if (_isBelowFloorAtAnyPrice(richestBalance, alphaPriceE18)) {
            if (leaveUnmovable) return;
            revert ConsolidationBelowFloor();
        }
        _rollRotatedStake(clone, coldkey, netuid, sourceKeys, currentSet, rollerHotkey, sourceBalances);
    }

    /// @dev Never revisit the starting key: its cached balance is stale once the pile leaves.
    function _rollRotatedStake(
        address clone,
        bytes32 coldkey,
        uint16 netuid,
        bytes32[] memory sourceKeys,
        bytes32[] memory currentSet,
        bytes32 rollerHotkey,
        uint256[] memory sourceBalances
    ) private {
        bytes32 richestHotkey = rollerHotkey;
        for (uint256 i; i < sourceBalances.length;) {
            bytes32 sourceHotkey = sourceKeys[i];
            if (sourceHotkey != richestHotkey && _isRotatedOut(sourceHotkey, currentSet) && sourceBalances[i] > 0) {
                // Read the live pile; summing earlier credits would over-ask after chain rounding.
                uint256 pile = IStaking(STAKING_PRECOMPILE).getStake(rollerHotkey, coldkey, netuid);
                _move(clone, rollerHotkey, sourceHotkey, netuid, pile);
                rollerHotkey = sourceHotkey;
            }
            unchecked {
                ++i;
            }
        }
        if (_isRotatedOut(rollerHotkey, currentSet)) {
            uint256 pile = IStaking(STAKING_PRECOMPILE).getStake(rollerHotkey, coldkey, netuid);
            _move(clone, rollerHotkey, currentSet[0], netuid, pile);
        }
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

    /// @notice Bring the vault's own alpha home from keys the record does not list.
    /// @dev Permissionless and never pays the caller. With a shortfall, every located balance parks on
    ///      the vault's own hotkey and stays there until the registry publishes a newer set. Without one,
    ///      the strays join the live backing; a late recovery belongs to the holders at that time.
    function recoverStray(uint256 tokenId, bytes32[] calldata sources) external nonReentrant {
        address clone = subnetClone[tokenId];
        if (clone == address(0)) revert NothingToUnwrap();
        uint16 netuid = VaultMath.netuidOf(tokenId);
        VaultReads.requireNotHeldByDissolution(tokenId);
        if (VaultReads.isIssuedForDissolvedSubnet(tokenId)) revert NothingToRecover();

        VaultReads.Slot[] memory slots = _slots[tokenId];
        if (slots.length == 0) revert NothingToRecover();
        bytes32 coldkey = VaultReads.coldkeyOf(clone);
        VaultReads.Backing memory backing = VaultReads.resolveBacking(slots, coldkey, netuid);
        bytes32[] memory strays = _novel(backing.keys, sources);

        if (VaultReads.firstShortOf(backing.short) == type(uint256).max) {
            _annex(tokenId, clone, coldkey, netuid, backing.keys[0], strays);
            return;
        }
        uint256 parked = _park(tokenId, clone, coldkey, netuid, VaultMath.concat(backing.keys, strays), false);
        uint256 slack = VaultReads.TRACKED_SLACK_RAO * slots.length;
        if (parked + slack < _totalTracked(slots)) revert RecoveryIncomplete();
    }

    /// @dev Sources the record already lists, and repeats, leave an empty entry that holds nothing.
    function _novel(bytes32[] memory keys, bytes32[] calldata sources) private pure returns (bytes32[] memory strays) {
        strays = new bytes32[](sources.length);
        for (uint256 i; i < sources.length;) {
            bytes32 source = sources[i];
            bool novel =
                source != bytes32(0) && !VaultMath.contains(keys, source) && !VaultMath.contains(strays, source);
            if (novel) strays[i] = source;
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Roll every located balance onto the parking hotkey and collapse the record to that one slot.
    function _park(
        uint256 tokenId,
        address clone,
        bytes32 coldkey,
        uint16 netuid,
        bytes32[] memory located,
        bool writeOff
    ) private returns (uint256 parked) {
        parked = _gather(clone, coldkey, netuid, located, parkingHotkey, writeOff);
        VaultReads.Slot[] storage tokenSlots = _slots[tokenId];
        while (tokenSlots.length > 1) {
            tokenSlots.pop();
        }
        tokenSlots[0] = VaultReads.Slot({ logical: parkingHotkey, active: parkingHotkey, tracked: parked });
        uint256 nonce = validatorRegistry.nonces(netuid);
        _recovery[tokenId] = Recovery({ shortSince: 0, parkedAtNonce: uint64(nonce), parked: true });
        emit BackingParked(tokenId, parked, nonce);
    }

    /// @dev With nothing short, strays join the first slot the way a dropped validator's stake does:
    ///      carried by the slot's own pile, so even dust comes home.
    function _annex(
        uint256 tokenId,
        address clone,
        bytes32 coldkey,
        uint16 netuid,
        bytes32 home,
        bytes32[] memory strays
    ) private {
        uint256 before = IStaking(STAKING_PRECOMPILE).getStake(home, coldkey, netuid);
        uint256 balance = _gather(clone, coldkey, netuid, strays, home, false);
        if (balance <= before) revert NothingToRecover();
        _slots[tokenId][0].tracked = balance;
        emit BackingRecovered(tokenId, home, balance - before);
    }

    /// @dev Roll the sources onto one destination and report what it holds afterwards.
    function _gather(
        address clone,
        bytes32 coldkey,
        uint16 netuid,
        bytes32[] memory sources,
        bytes32 destination,
        bool leaveUnmovable
    ) private returns (uint256) {
        bytes32[] memory destinations = new bytes32[](1);
        destinations[0] = destination;
        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);
        _consolidateRotatedStake(clone, coldkey, netuid, sources, destinations, alphaPriceE18, leaveUnmovable);
        return IStaking(STAKING_PRECOMPILE).getStake(destination, coldkey, netuid);
    }

    /// @notice Declare, clear or write off a shortfall, without moving stake before the window is out.
    /// @dev A declared shortfall holds priced operations shut until this call observes full coverage.
    ///      After `recoveryWindow`, the located remainder parks and the difference is written off.
    function syncBacking(uint256 tokenId) external nonReentrant {
        address clone = subnetClone[tokenId];
        if (clone == address(0)) revert NothingToUnwrap();
        uint16 netuid = VaultMath.netuidOf(tokenId);
        VaultReads.requireNotHeldByDissolution(tokenId);
        if (VaultReads.isIssuedForDissolvedSubnet(tokenId)) revert BackingUnchanged();

        Recovery storage state = _recovery[tokenId];
        if (state.parked) revert BackingUnchanged();
        VaultReads.Slot[] memory slots = _slots[tokenId];
        bytes32 coldkey = VaultReads.coldkeyOf(clone);
        VaultReads.Backing memory backing = VaultReads.resolveBacking(slots, coldkey, netuid);
        bool short = VaultReads.firstShortOf(backing.short) != type(uint256).max;
        uint256 expected = _totalTracked(slots);

        // forge-lint: disable-next-line(block-timestamp)
        uint64 timestamp = uint64(block.timestamp);
        if (state.shortSince == 0) {
            if (!short) revert BackingUnchanged();
            state.shortSince = timestamp;
            emit BackingShortfallDeclared(tokenId, expected, backing.total);
        } else if (!short) {
            state.shortSince = 0;
            emit BackingShortfallCleared(tokenId);
        } else if (timestamp >= state.shortSince + recoveryWindow) {
            emit BackingWrittenOff(tokenId, expected, backing.total);
            _park(tokenId, clone, coldkey, netuid, backing.keys, true);
        } else {
            revert BackingUnchanged();
        }
    }

    function recordedSlots(uint256 tokenId) external view returns (VaultReads.Slot[] memory) {
        return _slots[tokenId];
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
        if (_recovery[tokenId].shortSince != 0) revert ShortfallOnFile();
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
        uint16 netuid
    ) private view returns (bytes32[] memory actives) {
        bytes32 retired;
        (actives, retired) = _assignActives(slots, backing, currentSet, netuid);
        if (retired != bytes32(0)) revert AttestedHotkeyRetired(retired);
    }

    function _assignActives(
        VaultReads.Slot[] memory slots,
        VaultReads.Backing memory backing,
        bytes32[] memory currentSet,
        uint16 netuid
    ) private view returns (bytes32[] memory actives, bytes32 retired) {
        return VaultAllocation.assignActives(
            validatorRegistry, VaultReads.logicalsOf(slots), backing.keys, backing.balances, currentSet, netuid
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
            bytes32 active = actives[i];
            if (i < tokenSlots.length) {
                VaultReads.Slot storage slot = tokenSlots[i];
                if (slot.logical != currentSet[i]) slot.logical = currentSet[i];
                if (slot.active != active) slot.active = active;
                if (slot.tracked != tracked) slot.tracked = tracked;
            } else {
                tokenSlots.push(VaultReads.Slot({ logical: currentSet[i], active: active, tracked: tracked }));
            }
            total += tracked;
            unchecked {
                ++i;
            }
        }
        // An exit paid from the parking hotkey leaves the position parked.
        if (!awaitingAttestation(tokenId)) delete _recovery[tokenId];
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

    function _mailboxBalance(address userClone, bytes32 chosenHotkey, uint16 netuid) private view returns (uint256) {
        return IStaking(STAKING_PRECOMPILE).getStake(chosenHotkey, VaultReads.coldkeyOf(userClone), netuid);
    }

    function _ensureMailboxClone(address user, uint256 netuid) private returns (address userClone) {
        bytes32 salt = _cloneSalt(user, netuid);
        userClone = Clones.predictDeterministicAddress(mailboxLogic, salt, address(this));
        if (!cloneDeployed[userClone]) {
            Clones.cloneDeterministic(mailboxLogic, salt);
            DepositMailbox(payable(userClone)).initialize(address(this));
            cloneDeployed[userClone] = true;
        }
    }

    function _cloneSalt(address user, uint256 netuid) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(user, netuid));
    }

    function _deploySubnetClone(uint256 tokenId) private returns (address clone) {
        clone = Clones.clone(subnetLogic);
        SubnetClone(payable(clone)).initialize(address(this));
        subnetClone[tokenId] = clone;
        emit SubnetProxyCreated(tokenId, clone);
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
