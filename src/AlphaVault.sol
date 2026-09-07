// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { ERC1155Supply } from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SubnetClone } from "./SubnetClone.sol";
import { DepositMailbox } from "./DepositMailbox.sol";
import { IStaking, STAKING_PRECOMPILE } from "./interfaces/IStaking.sol";
import { IAlpha, ALPHA_PRECOMPILE } from "./interfaces/IAlpha.sol";
import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";
import { ISubnet, SUBNET_PRECOMPILE } from "./interfaces/ISubnet.sol";
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
    RecoveryBelowFloor,
    RecoveryIncomplete,
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
///      See docs/hotkey-swaps.md for temporary exit restrictions and recovery policy.
contract AlphaVault is ERC1155, ERC1155Supply, ReentrancyGuard {
    address public immutable mailboxLogic;
    address public immutable subnetLogic;
    IValidatorRegistry public immutable validatorRegistry;
    /// @notice Seconds from a slot's recorded shortfall until `syncBacking` may write it off.
    uint256 public immutable recoveryWindow;

    mapping(address => bool) public cloneDeployed;
    mapping(uint256 => address) public subnetClone;

    mapping(uint256 => VaultReads.Slot[]) private _slots;

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
    event BackingShortfallDeclared(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 expected, uint256 located);
    /// @dev Loss falls on holders at write-off; later recovery belongs to holders at recovery time.
    event BackingWrittenOff(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 expected, uint256 located);
    event BackingRecovered(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 amount);

    constructor(
        string memory _uri,
        address _mailboxLogic,
        address _subnetLogic,
        address _validatorRegistry,
        uint256 _recoveryWindow
    ) ERC1155(_uri) {
        if (_mailboxLogic == address(0) || _subnetLogic == address(0) || _validatorRegistry == address(0)) {
            revert ZeroAddress();
        }
        if (_recoveryWindow == 0) revert ZeroAmount();
        mailboxLogic = _mailboxLogic;
        subnetLogic = _subnetLogic;
        validatorRegistry = IValidatorRegistry(_validatorRegistry);
        recoveryWindow = _recoveryWindow;
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

    /// @notice Collect the caller's mailbox stake under one currently attested hotkey and mint shares.
    /// @dev Consolidates dropped validators and aligns weights. Unresolved backing blocks collection;
    ///      use mailbox reclaim if a swap or registry update leaves the deposit under an unlisted key.
    function wrap(uint256 netuid, bytes32 chosenHotkey, uint256 minSharesOut) external nonReentrant {
        if (chosenHotkey == bytes32(0)) revert ZeroHotkey();

        uint256 tokenId = currentTokenId(netuid);
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
        DepositMailbox(payable(userClone)).flush(destColdkey, chosenHotkey, netuid, totalDeposit);
        // Mint pricing reads only active keys; move the deposit onto one before pricing.
        if (!VaultMath.contains(actives, chosenHotkey)) {
            SubnetClone(payable(clone))
                .moveStake(
                    chosenHotkey,
                    actives[chosenIndex],
                    netuid,
                    IStaking(STAKING_PRECOMPILE).getStake(chosenHotkey, destColdkey, netuid)
                );
        }
        _consolidateRotatedStake(clone, destColdkey, nid, backing.keys, actives, alphaPriceE18);
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
    ///      Watcher recovery may be required; neither exit is unconditionally available.
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
        (bytes32[] memory hotkeys, uint16[] memory weights) = VaultReads.resolveValidators(validatorRegistry, netuid);
        bytes32 coldkey = VaultReads.coldkeyOf(clone);
        (VaultReads.Slot[] memory slots, VaultReads.Backing memory backing) = _openBacking(tokenId, coldkey, netuid);
        (bytes32[] memory actives, bytes32 retired) = _assignActives(slots, backing, hotkeys, netuid);
        // Conservatively block all dropped-stake consolidation if any receiving entry is ownerless.
        if (retired != bytes32(0) && _holdsRotatedOutStake(backing, actives)) revert AttestedHotkeyRetired(retired);
        // No pool trades on this path, so one price read covers all moves.
        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);
        _consolidateRotatedStake(clone, coldkey, netuid, backing.keys, actives, alphaPriceE18);

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
        // Partial exits must retain weight alignment, even if an ownerless entry's move would be sub-floor.
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
                    SubnetClone(payable(clone)).moveStake(hotkeys[deliveryIndex], hotkeys[i], netuid, pile);
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
        // Bound slippage against actual recipient credit, including chain-side stake-share rounding.
        uint256 requested = assets < deliverable ? assets : deliverable;
        uint256 recipientBefore = IStaking(STAKING_PRECOMPILE).getStake(hotkeys[deliveryIndex], userColdkey, netuid);
        SubnetClone(payable(clone)).flush(userColdkey, hotkeys[deliveryIndex], netuid, requested);
        uint256 recipientAfter = IStaking(STAKING_PRECOMPILE).getStake(hotkeys[deliveryIndex], userColdkey, netuid);
        alphaOut = recipientAfter > recipientBefore ? recipientAfter - recipientBefore : 0;
        // Chain rounding also changes the balances available to rebalance.
        uint256[] memory postBalances = VaultReads.fetchBalances(hotkeys, coldkey, netuid);
        _alignToWeights(tokenId, clone, hotkeys, weights, postBalances, alphaPriceE18);
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
    function rebalance(uint256 netuid) external nonReentrant {
        uint256 tokenId = currentTokenId(netuid);
        address clone = subnetClone[tokenId];
        if (clone == address(0)) return;

        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 nid = uint16(netuid);
        VaultReads.requireNotDissolving(nid);
        (bytes32[] memory hotkeys, uint16[] memory weights) = VaultReads.resolveValidators(validatorRegistry, nid);
        bytes32 coldkey = VaultReads.coldkeyOf(clone);
        (VaultReads.Slot[] memory slots, VaultReads.Backing memory backing) = _openBacking(tokenId, coldkey, nid);
        bytes32[] memory actives = _assignFundableActives(slots, backing, hotkeys, nid);
        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(nid);
        _consolidateRotatedStake(clone, coldkey, nid, backing.keys, actives, alphaPriceE18);
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
        SubnetClone(payable(clone))
            .moveStake(hotkeys[overIndex], hotkeys[underIndex], VaultMath.netuidOf(tokenId), moveAmount);
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
        DepositMailbox(payable(predicted)).flush(destSubstrateColdkey, hotkey, netuid, amount);
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
        DepositMailbox(payable(predicted)).sellAlphaForTao(hotkey, netuid, amount);

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
                SubnetClone(payable(clone)).sellAlphaForTao(hotkeys[i], netuid, chunk);
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
    function _consolidateRotatedStake(
        address clone,
        bytes32 coldkey,
        uint16 netuid,
        bytes32[] memory sourceKeys,
        bytes32[] memory currentSet,
        uint256 alphaPriceE18
    ) private {
        if (_anyRotatedOut(sourceKeys, currentSet)) {
            (bytes32 rollerHotkey, uint256 richestBalance, uint256[] memory sourceBalances, bool hasRotatedOutBalance) =
                _chooseRichestSlot(sourceKeys, currentSet, coldkey, netuid);
            // The pile starts at the largest balance, then only grows; its starting size bounds every hop.
            if (hasRotatedOutBalance && _isBelowFloorAtAnyPrice(richestBalance, alphaPriceE18)) {
                revert ConsolidationBelowFloor();
            }
            // Never revisit the starting key: its cached balance is stale once the pile leaves.
            bytes32 richestHotkey = rollerHotkey;
            for (uint256 i; i < sourceBalances.length;) {
                bytes32 sourceHotkey = sourceKeys[i];
                if (sourceHotkey != richestHotkey && _isRotatedOut(sourceHotkey, currentSet) && sourceBalances[i] > 0) {
                    // Read the live pile; summing earlier credits would over-ask after chain rounding.
                    uint256 pile = IStaking(STAKING_PRECOMPILE).getStake(rollerHotkey, coldkey, netuid);
                    SubnetClone(payable(clone)).moveStake(rollerHotkey, sourceHotkey, netuid, pile);
                    rollerHotkey = sourceHotkey;
                }
                unchecked {
                    ++i;
                }
            }
            if (_isRotatedOut(rollerHotkey, currentSet)) {
                uint256 pile = IStaking(STAKING_PRECOMPILE).getStake(rollerHotkey, coldkey, netuid);
                SubnetClone(payable(clone)).moveStake(rollerHotkey, currentSet[0], netuid, pile);
            }
        }
    }

    function _anyRotatedOut(bytes32[] memory sourceKeys, bytes32[] memory currentSet) private pure returns (bool) {
        for (uint256 i; i < sourceKeys.length;) {
            if (_isRotatedOut(sourceKeys[i], currentSet)) return true;
            unchecked {
                ++i;
            }
        }
        return false;
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

    /// @dev Start at the richest source or destination, letting a fresh deposit carry rotated-out dust.
    function _chooseRichestSlot(
        bytes32[] memory sourceKeys,
        bytes32[] memory currentSet,
        bytes32 coldkey,
        uint16 netuid
    )
        private
        view
        returns (
            bytes32 richestHotkey,
            uint256 richestBalance,
            uint256[] memory sourceBalances,
            bool hasRotatedOutBalance
        )
    {
        sourceBalances = new uint256[](sourceKeys.length);
        bytes32 richestRotatedOut;
        uint256 richestRotatedOutBalance;
        for (uint256 i; i < sourceBalances.length;) {
            bytes32 candidate = sourceKeys[i];
            if (_isRotatedOut(candidate, currentSet)) {
                uint256 balance = IStaking(STAKING_PRECOMPILE).getStake(candidate, coldkey, netuid);
                sourceBalances[i] = balance;
                if (balance > richestRotatedOutBalance) {
                    richestRotatedOut = candidate;
                    richestRotatedOutBalance = balance;
                }
            }
            unchecked {
                ++i;
            }
        }
        if (richestRotatedOutBalance == 0) return (currentSet[0], 0, sourceBalances, false);

        hasRotatedOutBalance = true;
        richestHotkey = currentSet[0];
        for (uint256 i; i < currentSet.length;) {
            uint256 balance = IStaking(STAKING_PRECOMPILE).getStake(currentSet[i], coldkey, netuid);
            if (balance > richestBalance) {
                richestHotkey = currentSet[i];
                richestBalance = balance;
            }
            unchecked {
                ++i;
            }
        }
        if (richestRotatedOutBalance > richestBalance) {
            richestHotkey = richestRotatedOut;
            richestBalance = richestRotatedOutBalance;
        }
    }

    /// @notice Return untracked stake under the vault's coldkey to a recorded slot.
    /// @dev Permissionless, but never transfers to the caller. Source and destination need owner records.
    ///      Requires full coverage of a short slot; with no shortfall, credits slot zero as new backing.
    ///      A merged find reassigns other short slots' expectations to the recovered backing.
    ///      Does not associate hotkeys or update the registry. Late recovery benefits current holders.
    function recoverStray(uint256 tokenId, bytes32 sourceHotkey) external nonReentrant {
        address clone = subnetClone[tokenId];
        if (clone == address(0)) revert NothingToUnwrap();
        uint16 netuid = VaultMath.netuidOf(tokenId);
        VaultReads.requireNotHeldByDissolution(tokenId);

        bytes32 coldkey = VaultReads.coldkeyOf(clone);
        VaultReads.Slot[] memory slots = _slots[tokenId];
        if (slots.length == 0) revert NothingToRecover();
        VaultReads.Backing memory backing = VaultReads.resolveBacking(slots, coldkey, netuid);
        if (VaultMath.contains(backing.keys, sourceHotkey)) revert NothingToRecover();

        uint256 amount = IStaking(STAKING_PRECOMPILE).getStake(sourceHotkey, coldkey, netuid);
        if (amount == 0) revert NothingToRecover();
        if (_isBelowFloorAtAnyPrice(amount, IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid))) {
            revert RecoveryBelowFloor();
        }

        uint256 chosen = _chooseRecoverySlot(slots, backing, amount);

        VaultReads.Slot storage slot = _slots[tokenId][chosen];
        bytes32 target = backing.keys[chosen];
        SubnetClone(payable(clone)).moveStake(sourceHotkey, target, netuid, amount);
        if (slot.active != target) slot.active = target;

        uint256 recovered = IStaking(STAKING_PRECOMPILE).getStake(target, coldkey, netuid);
        if (!VaultReads.coversTracked(recovered, slot.tracked)) revert RecoveryIncomplete();
        uint256 surplus = recovered > slot.tracked ? recovered - slot.tracked : 0;
        if (slot.tracked != recovered) slot.tracked = recovered;
        if (slot.shortSince != 0) slot.shortSince = 0;
        _reassignRecoveredBacking(tokenId, backing, chosen, surplus);
        emit BackingRecovered(tokenId, target, amount);
    }

    /// @dev Transfer expectations only against the destination's measured surplus, never rounding slack.
    ///      Persist every resolved key, even after the surplus runs out: a reduced expectation must not
    ///      claim a successor already covering another slot and move the shortfall onto a fresh clock.
    function _reassignRecoveredBacking(
        uint256 tokenId,
        VaultReads.Backing memory backing,
        uint256 chosen,
        uint256 surplus
    ) private {
        VaultReads.Slot[] storage tokenSlots = _slots[tokenId];
        for (uint256 i; i < tokenSlots.length;) {
            VaultReads.Slot storage slot = tokenSlots[i];
            if (slot.active != backing.keys[i]) slot.active = backing.keys[i];
            if (i != chosen && backing.short[i] && surplus != 0) {
                uint256 credit = Math.min(slot.tracked - backing.balances[i], surplus);
                slot.tracked -= credit;
                surplus -= credit;
                if (slot.shortSince != 0 && VaultReads.coversTracked(backing.balances[i], slot.tracked)) {
                    slot.shortSince = 0;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function _chooseRecoverySlot(VaultReads.Slot[] memory slots, VaultReads.Backing memory backing, uint256 amount)
        private
        pure
        returns (uint256 chosen)
    {
        chosen = type(uint256).max;
        bool lossStands;
        for (uint256 i; i < backing.short.length;) {
            if (backing.short[i]) {
                lossStands = true;
                bool covers = VaultReads.coversTracked(amount + backing.balances[i], slots[i].tracked);
                if (covers && (chosen == type(uint256).max || slots[i].tracked > slots[chosen].tracked)) {
                    chosen = i;
                }
            }
            unchecked {
                ++i;
            }
        }
        if (lossStands && chosen == type(uint256).max) revert RecoveryIncomplete();
        if (!lossStands) chosen = 0;
    }

    /// @notice Start/clear shortfall clocks or finalize expired losses, without moving stake.
    /// @dev Only this call writes off losses. It cannot restore hotkey ownership.
    function syncBacking(uint256 tokenId) external nonReentrant {
        address clone = subnetClone[tokenId];
        if (clone == address(0)) revert NothingToUnwrap();
        uint16 netuid = VaultMath.netuidOf(tokenId);
        VaultReads.requireNotHeldByDissolution(tokenId);
        if (VaultReads.isIssuedForDissolvedSubnet(tokenId)) revert BackingUnchanged();

        bytes32 coldkey = VaultReads.coldkeyOf(clone);
        VaultReads.Slot[] storage tokenSlots = _slots[tokenId];
        VaultReads.Backing memory backing = VaultReads.resolveBacking(_slots[tokenId], coldkey, netuid);

        bool changed;
        for (uint256 i; i < tokenSlots.length;) {
            VaultReads.Slot storage slot = tokenSlots[i];
            if (slot.active != backing.keys[i]) {
                slot.active = backing.keys[i];
                changed = true;
            }
            if (!backing.short[i]) {
                if (slot.shortSince != 0) {
                    slot.shortSince = 0;
                    changed = true;
                }
            } else if (slot.shortSince == 0) {
                // forge-lint: disable-next-line(block-timestamp)
                slot.shortSince = uint64(block.timestamp);
                emit BackingShortfallDeclared(tokenId, slot.active, slot.tracked, backing.balances[i]);
                changed = true;
            } else {
                // forge-lint: disable-next-line(block-timestamp)
                if (block.timestamp >= slot.shortSince + recoveryWindow) {
                    emit BackingWrittenOff(tokenId, slot.active, slot.tracked, backing.balances[i]);
                    slot.tracked = backing.balances[i];
                    slot.shortSince = 0;
                    changed = true;
                }
            }
            unchecked {
                ++i;
            }
        }
        if (!changed) revert BackingUnchanged();
    }

    function recordedSlots(uint256 tokenId) external view returns (VaultReads.Slot[] memory) {
        return _slots[tokenId];
    }

    function _openBacking(uint256 tokenId, bytes32 coldkey, uint16 netuid)
        private
        view
        returns (VaultReads.Slot[] memory slots, VaultReads.Backing memory backing)
    {
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

    /// @dev Keep funded slots on resolved keys; empty slots need an owned receiving key.
    ///      Keys remain exclusive even for empty slots. `retired` reports an unresolved empty entry,
    ///      not an ownership check of every funded source.
    function _assignActives(
        VaultReads.Slot[] memory slots,
        VaultReads.Backing memory backing,
        bytes32[] memory currentSet,
        uint16 netuid
    ) private view returns (bytes32[] memory actives, bytes32 retired) {
        bytes32[] memory logicals = new bytes32[](slots.length);
        for (uint256 i; i < logicals.length;) {
            logicals[i] = slots[i].logical;
            unchecked {
                ++i;
            }
        }

        actives = new bytes32[](currentSet.length);
        for (uint256 i; i < currentSet.length;) {
            bytes32 name = currentSet[i];
            uint256 at = VaultMath.indexOf(logicals, name);
            bytes32 key;
            bool live = true;
            if (at != type(uint256).max && backing.balances[at] != 0) {
                key = backing.keys[at];
            } else if (_keyHeldElsewhere(backing, logicals, currentSet, name, at)) {
                if (at == type(uint256).max) revert SwappedHotkeyStillAttested();
                key = backing.keys[at];
                live = _hasOwner(key);
            } else {
                (key, live) = _receivingKey(backing, logicals, currentSet, name, at, netuid);
                if (key != name && VaultMath.contains(actives, key)) revert SwappedHotkeyStillAttested();
            }
            actives[i] = key;
            if (!live && retired == bytes32(0)) retired = name;
            unchecked {
                ++i;
            }
        }
    }

    /// @dev A still-attested slot reserves its resolved key even while empty.
    function _keyHeldElsewhere(
        VaultReads.Backing memory backing,
        bytes32[] memory logicals,
        bytes32[] memory currentSet,
        bytes32 key,
        uint256 ownSlot
    ) private pure returns (bool) {
        uint256 holder = VaultMath.indexOf(backing.keys, key);
        if (holder == type(uint256).max || holder == ownSlot) return false;
        return VaultMath.contains(currentSet, logicals[holder]);
    }

    /// @dev Prefer an owned attested name, then the recorded active key, then its one-hop successor.
    ///      Resume from the record: the logical name's edge may predate swaps already followed.
    ///      Association can make the original name usable again without erasing its successor edge.
    function _receivingKey(
        VaultReads.Backing memory backing,
        bytes32[] memory logicals,
        bytes32[] memory currentSet,
        bytes32 name,
        uint256 ownSlot,
        uint16 netuid
    ) private view returns (bytes32 key, bool live) {
        if (_hasOwner(name)) return (name, true);

        key = ownSlot == type(uint256).max ? name : backing.keys[ownSlot];
        live = key != name && _hasOwner(key);
        if (!live) {
            bytes32 successor = VaultReads.hotkeySuccessor(key, netuid);
            if (successor != bytes32(0) && _hasOwner(successor)) {
                key = successor;
                live = true;
            }
        }
        if (
            key != name
                && (VaultMath.contains(currentSet, key)
                    || _keyHeldElsewhere(backing, logicals, currentSet, key, ownSlot))
        ) {
            revert SwappedHotkeyStillAttested();
        }
    }

    function _hasOwner(bytes32 hotkey) private view returns (bool exists) {
        (exists,) = IStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkey);
    }

    /// @dev Replace the registry-aligned record with actual post-move balances; shortfalls were checked on entry.
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
                if (slot.shortSince != 0) slot.shortSince = 0;
            } else {
                tokenSlots.push(
                    VaultReads.Slot({ logical: currentSet[i], active: active, tracked: tracked, shortSince: 0 })
                );
            }
            total += tracked;
            unchecked {
                ++i;
            }
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
            if (slot.shortSince != 0) slot.shortSince = 0;
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
