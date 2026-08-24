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
    ChosenHotkeyNotInSet,
    ClaimBelowNativePrecision,
    ConsolidationBelowFloor,
    DepositTooSmall,
    GatherBelowFloor,
    InsufficientShares,
    NetuidOutOfRange,
    NothingToUnwrap,
    SlippageExceeded,
    BackingIntact,
    BackingShortfall,
    HotkeyClaimedTwice,
    NoOpenDestination,
    NothingStrayUnder,
    SubnetNotRegistered,
    SupplyCapExceeded,
    WithdrawTooSmall,
    ZeroAddress,
    ZeroAmount,
    ZeroColdkey,
    ZeroHotkey
} from "./VaultErrors.sol";

/// @title AlphaVault
/// @notice ERC1155 multi-vault that wraps Bittensor Alpha Stake into fungible share tokens.
///         Each subnet has its own EIP-1167 clone holding alpha under an isolated coldkey.
///
/// @dev Architecture:
///   - Token ID = (netuid | registrationBlock << 16). No registration needed - vaults materialize on first deposit.
///   - Each vault tracks its own share price independently: backing alpha over totalSupply(tokenId).
///     Every quote lives on `AlphaVaultLens`, deployed alongside and reading this contract's
///     getters; it holds no state of its own and can be redeployed without touching the vault.
///   - EIP-1167 clones serve as deterministic "Mailbox" deposit addresses per (user, netuid).
///   - Validators + weights are read exclusively from ValidatorRegistry (no on-chain fallback).
///     Its address is immutable and the vault has no admin; weights are attested by a threshold of
///     registry signers, whose membership the registry admin rotates - the one privileged role left.
///   - Deposits and unwraps rebalance toward the attested weights (up to N-1 pre-checked
///     `moveStake`s; sub-floor and zero-price moves are skipped).
///   - Explicit `rebalance(netuid)` is still callable if rebalancing is desired immediately.
///   - State-mutating calls consolidate alpha off hotkeys dropped from the registry by rolling the
///     whole position through them; any consolidation failure reverts the call, so stake is never
///     stranded. The last-seen validator set is tracked per token.
///   - Per-subnet clones isolate alpha and TAO returned by dissolved subnets.
///   - Native TAO credited to a clone while its subnet is live (forced dust sales, donations) backs
///     claims through a cumulative per-share index, never the share price. Arrivals are recorded at
///     the next balance change or claim; whatever is still unrecorded when dissolution starts folds
///     into the pro-rata refund.
contract AlphaVault is ERC1155, ERC1155Supply, ReentrancyGuard {
    // -------------------- Immutables --------------------------------------------
    address public immutable mailboxLogic;
    address public immutable subnetLogic;
    IValidatorRegistry public immutable validatorRegistry;

    // -------------------- State -------------------------------------------------
    mapping(address => bool) public cloneDeployed;
    mapping(uint256 => address) public subnetClone;

    /// @dev One record per validator the position is spread across, written only at the end of a
    ///      clean operation, so a failed one leaves the evidence in place for the next caller.
    mapping(uint256 => VaultReads.Slot[]) private _slots;

    /// @notice Cumulative TAO credited per share over a token's lifetime, scaled by
    ///         `VaultMath.TAO_INDEX_PRECISION`. Grows when the clone receives TAO the vault did not pay out.
    mapping(uint256 => uint256) public cumulativeTaoPerShare;

    /// @notice TAO recognized for holders through the index but not yet claimed. This portion of
    ///         the clone's balance backs claims, never redemptions.
    mapping(uint256 => uint256) public taoLiability;

    /// @dev Index level already settled for an account's current balance; the difference to the
    ///      live index times the balance is the account's unrecorded entitlement.
    mapping(uint256 => mapping(address => uint256)) public taoIndexDebt;

    /// @notice TAO an account has earned and can withdraw via `claimTao`.
    mapping(uint256 => mapping(address => uint256)) public claimableTao;

    // -------------------- Precision ---------------------------------------------
    uint16 private constant BPS_BASE = 10_000;
    /// @dev `getAlphaPrice` rounds down to a multiple of this (e18 scale), so the true price is
    ///      always below the read plus one step.
    uint256 private constant ALPHA_PRICE_QUANTUM_E18 = 1e9;
    /// @dev Post-mint share-supply bound. Below it a synchronization's flooring loses less than
    ///      one native quantum and any whole-quantum arrival moves the claim index; only a
    ///      swept-then-recapitalized position can approach it.
    uint256 private constant SUPPLY_CAP = VaultMath.TAO_NATIVE_QUANTUM * VaultMath.TAO_INDEX_PRECISION;

    // -------------------- Events ------------------------------------------------
    event Deposited(address indexed user, uint256 indexed tokenId, uint256 assets, uint256 shares);
    /// @notice A live-subnet alpha unwrap. `alphaOut` is the alpha RAO sent by the successful
    ///         transfer, capped at the backing available after gather rounding.
    event Unwrapped(address indexed user, uint256 indexed tokenId, uint256 shares, uint256 alphaOut);
    /// @notice A dissolved-subnet unwrap. `taoOut` is native TAO paid in EVM wei.
    event DissolvedSubnetUnwrapped(address indexed user, uint256 indexed tokenId, uint256 shares, uint256 taoOut);
    /// @notice Emitted only for weight-alignment moves; consolidation and gather hops are silent, so
    ///         off-chain volume comes from Deposited and the Unwrapped / UnwrappedForTao /
    ///         DissolvedSubnetUnwrapped / MailboxAlphaSoldForTao exit events, never from internal
    ///         stake moves.
    event Rebalanced(uint256 indexed tokenId, bytes32 indexed fromHotkey, bytes32 indexed toHotkey, uint256 amount);
    event SubnetProxyCreated(uint256 indexed tokenId, address clone);
    /// @notice A live-subnet unwrap paid by selling the alpha. `shares` and `alphaSold` are net of
    ///         any refund, so both count only what left the vault; `taoOut` is native TAO in wei.
    event UnwrappedForTao(
        address indexed user, uint256 indexed tokenId, uint256 shares, uint256 alphaSold, uint256 taoOut
    );
    event MailboxAlphaSoldForTao(
        address indexed user, uint256 indexed netuid, bytes32 indexed hotkey, uint256 alpha, uint256 taoOut
    );
    /// @notice A holder withdrew accumulated native TAO. `amount` is in EVM wei.
    event TaoClaimed(address indexed user, uint256 indexed tokenId, address recipient, uint256 amount);
    /// @notice The record followed a hotkey swap: the slot that answered for `oldHotkey` now
    ///         answers for `newHotkey`.
    event HotkeySwapFollowed(uint256 indexed tokenId, bytes32 indexed oldHotkey, bytes32 indexed newHotkey);
    /// @notice The vault recorded backing under `hotkey` it cannot account for, starting the
    ///         window in which anyone can still point it at the missing alpha.
    event ShortfallDeclared(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 owed);
    /// @notice A recorded loss waited out its window unanswered: the record stops expecting `owed`
    ///         alpha under `hotkey`, and whatever the chain still reports there re-anchors as
    ///         ordinary backing.
    event ShortfallWrittenOff(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 owed);
    /// @notice Alpha the vault had given up on was found under `hotkey` and is backing shares again.
    event BackingRecovered(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 found);

    // -------------------- Constructor -------------------------------------------
    /// @param _uri ERC1155 metadata URI template, fixed for the contract's lifetime.
    constructor(string memory _uri, address _mailboxLogic, address _subnetLogic, address _validatorRegistry)
        ERC1155(_uri)
    {
        if (_mailboxLogic == address(0) || _subnetLogic == address(0) || _validatorRegistry == address(0)) {
            revert ZeroAddress();
        }
        mailboxLogic = _mailboxLogic;
        subnetLogic = _subnetLogic;
        validatorRegistry = IValidatorRegistry(_validatorRegistry);
    }

    // -------------------- Token ID & Subnet Proxy --------------------------------

    /// @notice Compute the current ERC1155 tokenId for a netuid.
    /// @dev    Low 16 bits = netuid, upper bits = subnet registration block.
    ///         Reverts with `SubnetNotRegistered` if no subnet is currently registered at `netuid`.
    /// @param  netuid Subnet id.
    /// @return tokenId Packed (registrationBlock << 16) | netuid identifier.
    function currentTokenId(uint256 netuid) public view returns (uint256) {
        if (netuid > type(uint16).max) revert NetuidOutOfRange();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 nid = uint16(netuid);
        uint64 registrationBlock = ISubnet(SUBNET_PRECOMPILE).getNetworkRegistrationBlock(nid);
        if (registrationBlock == 0) revert SubnetNotRegistered();
        return uint256(nid) | (uint256(registrationBlock) << 16);
    }

    /// @notice Deploy the per-subnet clone that will hold this subnet's alpha under an isolated coldkey.
    /// @dev    Idempotent: returns silently if a clone already exists for the current tokenId.
    function createSubnetProxy(uint256 netuid) external {
        uint256 tokenId = currentTokenId(netuid);
        if (subnetClone[tokenId] != address(0)) return;
        _deploySubnetClone(tokenId);
    }

    // -------------------- Deposit Flow ------------------------------------------

    /// @notice Predict the mailbox clone address for a user on a subnet.
    function getDepositAddress(address user, uint256 netuid) public view returns (address) {
        if (netuid > type(uint16).max) revert NetuidOutOfRange();
        bytes32 salt = _cloneSalt(user, netuid);
        return Clones.predictDeterministicAddress(mailboxLogic, salt, address(this));
    }

    function wrap(uint256 netuid, bytes32 chosenHotkey) external nonReentrant {
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

        VaultReads.Plan memory plan = _resolveAndFollow(tokenId, nid, destColdkey, hotkeys, true);
        bytes32[] memory barred = _barredActives(tokenId, plan.unaccounted);
        bytes32[] memory effective = _effectiveSet(tokenId, hotkeys);
        // The mailbox follows its own successor trail: a hotkey swap carries its stake like
        // everyone else's, and the record only follows swaps the position held stake through.
        (bytes32 mailboxKey, uint256 totalDeposit) =
            DepositMailbox(payable(userClone)).resolveDeposit(effective[chosenIndex], nid);
        if (totalDeposit == 0) revert ZeroAmount();

        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(nid);
        if (alphaPriceE18 != 0 && _isBelowFloorAtReadPrice(totalDeposit, alphaPriceE18)) {
            revert DepositTooSmall();
        }

        // The deposit settles where every other mover may land it: the chosen validator's key when
        // that one is open, the first open attested key otherwise.
        bytes32 landing = effective[chosenIndex];
        if (!_isOpenDestination(landing, barred)) landing = effective[_openLandingIndex(effective, barred)];
        DepositMailbox(payable(userClone)).flush(destColdkey, mailboxKey, netuid, totalDeposit);
        if (mailboxKey != landing) {
            SubnetClone(payable(clone))
                .moveStake(
                    mailboxKey, landing, netuid, IStaking(STAKING_PRECOMPILE).getStake(mailboxKey, destColdkey, netuid)
                );
        }
        _consolidateRotatedStake(tokenId, clone, destColdkey, hotkeys, effective, alphaPriceE18, barred);

        uint256 totalAlpha = _rebalance(tokenId, clone, hotkeys, effective, weights, destColdkey, alphaPriceE18, barred);

        uint256 preStake = totalAlpha > totalDeposit ? totalAlpha - totalDeposit : 0;
        uint256 shares = VaultMath.sharesFor(preStake, totalSupply(tokenId), totalDeposit);
        if (shares == 0) revert ZeroAmount();
        // Recapitalizing a swept position multiplies supply toward the bound; retiring the swept
        // shares through the zero-backing unwrap resets supply and lifts it.
        if (totalSupply(tokenId) + shares > SUPPLY_CAP) revert SupplyCapExceeded();

        _mint(msg.sender, tokenId, shares, "");

        emit Deposited(msg.sender, tokenId, totalDeposit, shares);
    }

    // -------------------- Unwrap Flow -----------------------------------------

    function unwrap(uint256 tokenId, uint256 shares, bytes32 userSubstrateColdkey) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender, tokenId) < shares) revert InsufficientShares();
        uint16 netuid = VaultMath.netuidOf(tokenId);
        VaultReads.requireNotDissolving(netuid);
        address clone = subnetClone[tokenId];

        if (VaultReads.isIssuedForDissolvedSubnet(tokenId)) {
            _unwrapFromDissolvedSubnet(tokenId, shares, clone);
        } else {
            _unwrapFromLiveSubnet(tokenId, shares, userSubstrateColdkey, clone, netuid);
        }
    }

    function unwrapForTao(uint256 tokenId, uint256 shares, uint256 minTaoOut) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender, tokenId) < shares) revert InsufficientShares();
        address clone = subnetClone[tokenId];
        uint16 netuid = VaultMath.netuidOf(tokenId);
        VaultReads.requireNotDissolving(netuid);

        bytes32 vaultColdkey = VaultReads.coldkeyOf(clone);
        VaultReads.Plan memory plan;
        // A dissolved token's backing legitimately became TAO, so its zero is the honest state and
        // there is no record left to hold it to.
        bool dissolved = VaultReads.isIssuedForDissolvedSubnet(tokenId);
        if (!dissolved) {
            (bytes32[] memory logicalSet,) = VaultReads.resolveValidators(validatorRegistry, netuid);
            plan = _resolveAndFollow(tokenId, netuid, vaultColdkey, logicalSet, false);
        }
        (bytes32[] memory hotkeys, uint256[] memory balances, uint256 total) =
            VaultReads.backingStake(validatorRegistry, VaultReads.activesOf(_slots[tokenId]), vaultColdkey, netuid);
        // The dissolving window is excluded above and completed dissolution zeroes the alpha
        // balance, so a non-zero total implies a live subnet and a zero total cannot be
        // exited via this rail regardless of cause.
        if (total == 0) revert NothingToUnwrap();

        uint256 supply = totalSupply(tokenId);
        // A full burn claims the whole backing exactly: the rounded-down conversion can price it
        // a few RAO short, which would degrade the floor-exempt full drains into floored partials
        // the chain rejects - locking the last holder's sub-floor dust out of its only exit.
        uint256 assets = shares == supply ? total : VaultMath.assetsFor(total, supply, shares);
        if (assets == 0) revert ZeroAmount();

        _burn(msg.sender, tokenId, shares);

        uint256 balanceBefore = clone.balance;
        uint256 dustThresholdTao = IStaking(STAKING_PRECOMPILE).getNominatorMinRequiredStake();
        // Round one sells only slots that empty completely - the chain exempts those from its
        // minimum. Round two sells checked partial amounts from what then remains, at prices the
        // earlier sells have moved; partials go last so their shrinking can never eat an amount a
        // later slot would have emptied exactly.
        uint256 remaining = _sellRound(clone, netuid, hotkeys, balances, assets, dustThresholdTao, false);
        _sellRound(clone, netuid, hotkeys, balances, remaining, dustThresholdTao, true);

        uint256 taoOut = clone.balance - balanceBefore;
        if (taoOut == 0) revert WithdrawTooSmall();
        if (taoOut < minTaoOut) revert SlippageExceeded(taoOut);

        // A sell the chain accepts can still fill short at the pool's price floor, so the position
        // reports what left. Selling past the request means the chain swept backing that belongs to
        // the holders who stay; the subtraction refuses to pay it out.
        uint256 sold = total - VaultMath.sumBalances(VaultReads.fetchBalances(hotkeys, vaultColdkey, netuid));
        // The chain's own sweep can fold a leftover into the payout, selling past the request.
        uint256 unsold = assets > sold ? assets - sold : 0;
        // The chain keeps a RAO or so of every sale; refunding that to a full exit would mint a
        // sub-floor position no rail can ever sell. A partial burn keeps it - it merges into the
        // balance already held.
        if (unsold != 0 && shares == supply) {
            uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);
            if (alphaPriceE18 != 0 && _isBelowFloorAtReadPrice(unsold, alphaPriceE18)) unsold = 0;
        }

        // A dissolved token has no record left to hold to, and the plan above never ran for it.
        if (!dissolved) _reanchorTracked(tokenId, vaultColdkey, netuid, plan.unaccounted);

        SubnetClone(payable(clone)).unwrapTao(payable(msg.sender), taoOut);

        // The mint must follow the payout: proceeds still in the clone would be folded into the
        // claim index and promised to every holder, this caller included.
        uint256 refundShares = VaultMath.sharesFor(total - assets, supply - shares, unsold);
        if (refundShares != 0) _mint(msg.sender, tokenId, refundShares, "");

        emit UnwrappedForTao(msg.sender, tokenId, shares - refundShares, sold, taoOut);
    }

    /// @notice Pay out the caller's accumulated TAO entitlement for `tokenId` to `recipient`.
    /// @dev    Entitlement is settled before every balance change, so it survives transfers and
    ///         full exits and can be claimed at any time, including during and after dissolution.
    ///         Pays in whole native-transfer quantums and keeps the sub-quantum remainder
    ///         reserved; an entitlement below one quantum reverts `ClaimBelowNativePrecision`.
    /// @param  tokenId   Vault token id the entitlement was earned on.
    /// @param  recipient Address receiving the native TAO.
    function claimTao(uint256 tokenId, address payable recipient) external nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        _syncTao(tokenId);
        _checkpoint(msg.sender, tokenId, cumulativeTaoPerShare[tokenId]);
        uint256 entitlement = claimableTao[tokenId][msg.sender];
        uint256 liability = taoLiability[tokenId];
        // What the liability cannot back stays recorded rather than being erased.
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
        uint16 netuid
    ) private {
        (bytes32[] memory logicalSet, uint16[] memory weights) = VaultReads.resolveValidators(validatorRegistry, netuid);
        bytes32 coldkey = VaultReads.coldkeyOf(clone);
        VaultReads.Plan memory plan = _resolveAndFollow(tokenId, netuid, coldkey, logicalSet, false);
        bytes32[] memory barred = _barredActives(tokenId, plan.unaccounted);
        bytes32[] memory hotkeys = _effectiveSet(tokenId, logicalSet);
        // Nothing on this path trades against the pool, so one price read holds for the whole call.
        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);
        _consolidateRotatedStake(tokenId, clone, coldkey, logicalSet, hotkeys, alphaPriceE18, barred);

        // After consolidation the whole backing sits on the current validators, so their
        // balances count everything this rail can deliver.
        uint256[] memory balances = _reachableBalances(hotkeys, coldkey, netuid, barred);
        uint256 totalAlpha = VaultMath.sumBalances(balances);
        // A fully swept position cannot regain alpha, and the burn's checkpoint keeps any
        // swept-sale proceeds claimable, so the shares are retired instead of trapped. Backing
        // this rail cannot reach is another matter: the TAO rail sells it, so the burn refuses.
        if (totalAlpha == 0 && plan.total != 0) revert GatherBelowFloor();
        if (totalAlpha == 0) {
            _burn(msg.sender, tokenId, shares);
            _settleRecord(tokenId, coldkey, netuid, logicalSet, hotkeys, plan);
            emit Unwrapped(msg.sender, tokenId, shares, 0);
            return;
        }

        uint256 assets = VaultMath.assetsFor(totalAlpha, totalSupply(tokenId), shares);
        if (assets == 0) revert ZeroAmount();

        // A sub-floor request is undeliverable on the alpha rail (the chain rejects the transfer);
        // reverting keeps delivery exact and points dust positions at unwrapForTao. A zero read
        // falls through to the chain on the delivery below.
        if (alphaPriceE18 != 0 && _isBelowFloorAtReadPrice(assets, alphaPriceE18)) {
            revert WithdrawTooSmall();
        }

        _burn(msg.sender, tokenId, shares);
        uint256 alphaOut =
            _gatherAndDeliver(tokenId, clone, hotkeys, balances, coldkey, userSubstrateColdkey, assets, alphaPriceE18);
        // Re-read live balances so the weight re-split never moves more than a slot holds.
        uint256[] memory postBalances = VaultReads.fetchBalances(hotkeys, coldkey, netuid);
        _alignToWeights(tokenId, clone, hotkeys, weights, postBalances, alphaPriceE18, barred);
        _settleRecord(tokenId, coldkey, netuid, logicalSet, hotkeys, plan);

        emit Unwrapped(msg.sender, tokenId, shares, alphaOut);
    }

    function _reachableBalances(bytes32[] memory hotkeys, bytes32 coldkey, uint16 netuid, bytes32[] memory barred)
        private
        view
        returns (uint256[] memory balances)
    {
        balances = VaultReads.fetchBalances(hotkeys, coldkey, netuid);
        for (uint256 i; i < balances.length; ++i) {
            if (balances[i] != 0 && VaultMath.contains(barred, hotkeys[i])) balances[i] = 0;
        }
    }

    function _gatherAndDeliver(
        uint256 tokenId,
        address clone,
        bytes32[] memory hotkeys,
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
        // When the largest slot already covers the request, its fetched balance is still exact. A
        // gather is different: the chain can credit each move slightly short, so summed balances
        // overstate what a slot holds and the delivery slot is re-read after a gather runs.
        uint256 deliverable = balances[deliveryIndex];
        if (balances[deliveryIndex] < assets) {
            // Every gather hop moves at least the largest slot's balance, so if even that cannot
            // clear the floor, no hop can: refuse up front rather than forward a call that could
            // burn the whole budget.
            if (_isBelowFloorAtAnyPrice(balances[deliveryIndex], alphaPriceE18)) {
                revert GatherBelowFloor();
            }
            // Each hop re-reads the moving balance from the chain: the previous hop may have been
            // credited one RAO short, and asking for more than the slot holds would revert.
            // `balances` still tracks which slots are drained and when the gather has enough.
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
        // Deliver the entitlement, capped at what the gathered slot holds after the gather's rounding.
        alphaOut = assets < deliverable ? assets : deliverable;
        SubnetClone(payable(clone)).flush(userColdkey, hotkeys[deliveryIndex], netuid, alphaOut);
    }

    function _unwrapFromDissolvedSubnet(uint256 tokenId, uint256 shares, address clone) private {
        uint256 backing = VaultMath.unreservedTao(clone.balance, taoLiability[tokenId]);
        if (backing == 0) revert NothingToUnwrap();

        uint256 supplyBefore = totalSupply(tokenId);
        uint256 userTao = VaultMath.proRata(backing, shares, supplyBefore);
        _burn(msg.sender, tokenId, shares);
        if (userTao > 0) SubnetClone(payable(clone)).unwrapTao(payable(msg.sender), userTao);
        emit DissolvedSubnetUnwrapped(msg.sender, tokenId, shares, userTao);
    }

    // -------------------- Rebalance -------------------------------------------

    function rebalance(uint256 netuid) external nonReentrant {
        uint256 tokenId = currentTokenId(netuid);
        address clone = subnetClone[tokenId];
        if (clone == address(0)) return;

        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 nid = uint16(netuid);
        VaultReads.requireNotDissolving(nid);
        (bytes32[] memory logicalSet, uint16[] memory weights) = VaultReads.resolveValidators(validatorRegistry, nid);
        bytes32 coldkey = VaultReads.coldkeyOf(clone);
        VaultReads.Plan memory plan = _resolveAndFollow(tokenId, nid, coldkey, logicalSet, true);
        bytes32[] memory barred = _barredActives(tokenId, plan.unaccounted);
        bytes32[] memory effective = _effectiveSet(tokenId, logicalSet);
        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(nid);
        _consolidateRotatedStake(tokenId, clone, coldkey, logicalSet, effective, alphaPriceE18, barred);
        _rebalance(tokenId, clone, logicalSet, effective, weights, coldkey, alphaPriceE18, barred);
    }

    function _rebalance(
        uint256 tokenId,
        address clone,
        bytes32[] memory logicalSet,
        bytes32[] memory effectiveSet,
        uint16[] memory weights,
        bytes32 coldkey,
        uint256 alphaPriceE18,
        bytes32[] memory barred
    ) private returns (uint256 total) {
        uint256[] memory balances = VaultReads.fetchBalances(effectiveSet, coldkey, VaultMath.netuidOf(tokenId));
        total = _alignToWeights(tokenId, clone, effectiveSet, weights, balances, alphaPriceE18, barred);
        _settleSlots(tokenId, coldkey, logicalSet, effectiveSet);
    }

    function _alignToWeights(
        uint256 tokenId,
        address clone,
        bytes32[] memory hotkeys,
        uint16[] memory weights,
        uint256[] memory balances,
        uint256 alphaPriceE18,
        bytes32[] memory barred
    ) private returns (uint256 total) {
        total = VaultMath.sumBalances(balances);

        // A single validator holds everything by definition; there is nothing to move against.
        if (weights.length == 1 || total == 0) return total;

        // A key that cannot take stake is never chosen as a destination; its share of the split
        // drifts, which the step comment below already accepts.
        bool[] memory open = new bool[](hotkeys.length);
        for (uint256 i; i < hotkeys.length;) {
            open[i] = _isOpenDestination(hotkeys[i], barred);
            unchecked {
                ++i;
            }
        }

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

        // Each step settles at least one slot exactly at its target, and surpluses and deficits
        // cancel out, so settling all but one slot settles the last one too. The floor cannot
        // change mid-transaction, so one read serves every step.
        uint256 minStakeTao = _minStakeTao();
        for (uint256 round; round < lastIndex;) {
            if (!_rebalanceStep(tokenId, clone, hotkeys, balances, targets, alphaPriceE18, minStakeTao, open)) break;
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
        uint256 minStakeTao,
        bool[] memory open
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
            } else if (open[i] && balances[i] < targets[i]) {
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
        // A move the chain rejects burns all the gas sent with it, so a move below the floor is
        // skipped, never attempted. Nothing that passes can be rejected as too small: nothing here
        // trades against the pool and the price read only rounds down. A skipped move (including
        // every move at a zero price read) leaves the split drifted - harmless, since share value
        // depends on the total, not the split.
        if (alphaPriceE18 == 0 || _taoValue(moveAmount, alphaPriceE18) < minStakeTao) return false;
        SubnetClone(payable(clone))
            .moveStake(hotkeys[overIndex], hotkeys[underIndex], VaultMath.netuidOf(tokenId), moveAmount);
        emit Rebalanced(tokenId, hotkeys[overIndex], hotkeys[underIndex], moveAmount);
        balances[overIndex] -= moveAmount;
        balances[underIndex] += moveAmount;
        return true;
    }

    // -------------------- Mailbox Recovery --------------------------------------

    /// @notice Reclaim native TAO stuck in the caller's mailbox clone after subnet deregistration.
    /// @dev    Deploys the mailbox clone lazily if it was never materialized, so the TAO refund
    ///         credited directly to the deterministic address can still be recovered.
    ///         Reverts with `ZeroAmount` if the mailbox holds no balance.
    /// @param  netuid Subnet id whose mailbox clone should be drained to the caller.
    function reclaimTaoFromMailbox(uint256 netuid) external nonReentrant {
        address predicted = getDepositAddress(msg.sender, netuid);
        uint256 amount = predicted.balance;
        if (amount == 0) revert ZeroAmount();
        _ensureMailboxClone(msg.sender, netuid);
        DepositMailbox(payable(predicted)).unwrapTao(payable(msg.sender), amount);
    }

    /// @notice Reclaim alpha stake parked in the caller's mailbox back to a substrate coldkey.
    /// @dev    Recovery path for any alpha sitting in the mailbox; works for in-set hotkeys
    ///         (change of mind before depositing) and out-of-set hotkeys (wrong choice, or the
    ///         set rotated before the user could deposit). Deploys the mailbox clone lazily;
    ///         substrate stake can park on the mailbox coldkey before the EVM-side clone exists.
    ///         Reverts with `ZeroAmount` if the mailbox holds no stake under `hotkey`.
    /// @param  netuid               Subnet id whose mailbox should be drained for this hotkey.
    /// @param  hotkey               Hotkey under which the stranded stake sits.
    /// @param  destSubstrateColdkey Destination coldkey for the recovered alpha.
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

    /// @notice Swap a user's mailbox alpha for native TAO and send it to the caller.
    /// @param  netuid     Subnet id of the mailbox.
    /// @param  hotkey     Hotkey under which the alpha sits in the mailbox.
    /// @param  minTaoOut  Slippage floor; revert if realized TAO is less.
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

    // -------------------- Internal Helpers --------------------------------------

    function _isRotatedOut(bytes32 hotkey, bytes32[] memory currentSet) private pure returns (bool) {
        return !VaultMath.contains(currentSet, hotkey);
    }

    /// @dev Tao value of `alphaAmount` at `alphaPriceE18`, rounded down - the same arithmetic the
    ///      chain applies at full precision to same-subnet transfers and moves.
    function _taoValue(uint256 alphaAmount, uint256 alphaPriceE18) private pure returns (uint256) {
        return (alphaAmount * alphaPriceE18) / 1e18;
    }

    /// @dev Tao floor for skipping stake operations the chain would reject as too small, read from
    ///      the chain so a runtime change needs no redeploy. Exact for the unstake rail; the chain
    ///      floors transfers and same-subnet moves lower but exposes no getter, so applying this to
    ///      them also refuses moves the chain would have taken - those exit via the TAO rail.
    function _minStakeTao() private view returns (uint256) {
        return IStaking(STAKING_PRECOMPILE).getDefaultMinStake();
    }

    /// @dev The rounded-down read can under-value the amount, so this can reject what the chain
    ///      would accept, never the reverse. Must never gate a
    ///      full-balance unstake: those are floor-exempt and the only exit for sub-floor positions.
    ///      A zero read proves nothing; callers choose their own fall-through.
    function _isBelowFloorAtReadPrice(uint256 alphaAmount, uint256 alphaPriceE18) private view returns (bool) {
        return _taoValue(alphaAmount, alphaPriceE18) < _minStakeTao();
    }

    /// @dev True only when the amount cannot clear the floor even at the highest price the
    ///      rounded-down read could be hiding. A zero read carries no bound, so it never rejects.
    function _isBelowFloorAtAnyPrice(uint256 alphaAmount, uint256 alphaPriceE18) private view returns (bool) {
        return alphaPriceE18 != 0 && _taoValue(alphaAmount, alphaPriceE18 + ALPHA_PRICE_QUANTUM_E18) < _minStakeTao();
    }

    /// @dev One selling round over the union slots: full drains always; checked partials only
    ///      when `includePartials`. Returns what is left of `remaining`.
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

    /// @dev Largest chunk of `remaining` a slot holding `balance` can sell cleanly; 0 skips the
    ///      slot. Two chain rules bind a partial sell: the chunk's post-fee output must clear the
    ///      stake floor, and the leftover must stay above the dust threshold - the chain force-sells
    ///      a smaller leftover into this exit's payout, leaking the remaining holders' backing.
    function _sellableChunk(uint16 netuid, uint256 remaining, uint256 balance, uint256 dustThresholdTao)
        private
        view
        returns (uint256)
    {
        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);
        if (alphaPriceE18 == 0) return 0;

        // One extra RAO of leftover value covers the rounding of the leftover's quote below, so a
        // leftover that passes that check is truly above the threshold.
        uint256 minLeftover = dustThresholdTao == 0 ? 0 : Math.ceilDiv((dustThresholdTao + 1) * 1e18, alphaPriceE18);
        if (balance <= minLeftover) return 0;

        uint256 maxChunk = balance - minLeftover;
        uint256 chunk = maxChunk < remaining ? maxChunk : remaining;
        // The spot pre-check keeps the sim swap - whose rejection consumes all forwarded gas - away
        // from dust it cannot price.
        if (_isBelowFloorAtReadPrice(chunk, alphaPriceE18)) return 0;

        uint256 chunkQuote = IAlpha(ALPHA_PRECOMPILE).simSwapAlphaForTao(netuid, _saturateU64(chunk));
        if (chunkQuote < _minStakeTao()) return 0;

        // The chain values the leftover at the post-sale price, so it must clear the threshold on
        // its marginal quote - full-balance quote minus chunk quote, a lower bound on that value.
        // An oversized balance would saturate the sim's u64 input and under-quote, so the check
        // runs only on a faithful full-balance quote.
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

    function _consolidateRotatedStake(
        uint256 tokenId,
        address clone,
        bytes32 coldkey,
        bytes32[] memory logicalSet,
        bytes32[] memory currentSet,
        uint256 alphaPriceE18,
        bytes32[] memory barred
    ) private {
        // Whether a slot was rotated out is a question about the validator the registry named, not
        // about where a hotkey swap has since carried its alpha. A slot whose `logical` is still
        // attested stays put, wherever `active` now points.
        bytes32[] memory lastSeen = _rotatedOutActiveKeys(tokenId, logicalSet);
        if (lastSeen.length != 0) {
            uint16 netuid = VaultMath.netuidOf(tokenId);
            (
                bytes32 rollerHotkey,
                uint256 richestBalance,
                uint256[] memory lastSeenBalances,
                bool hasRotatedOutBalance
            ) = _chooseRichestSlot(lastSeen, currentSet, coldkey, netuid);
            // Every hop moves the whole pile and the pile only grows, so the richest balance - where
            // the roll starts - is the binding floor check for the entire roll.
            if (hasRotatedOutBalance && _isBelowFloorAtAnyPrice(richestBalance, alphaPriceE18)) {
                revert ConsolidationBelowFloor();
            }
            // The richest slot's balance is already in the pile; its cached balance goes stale once
            // the pile departs, so the roll must never revisit it. No other slot can repeat: a
            // validator set holds no duplicate hotkeys.
            bytes32 richestHotkey = rollerHotkey;
            for (uint256 i; i < lastSeenBalances.length;) {
                bytes32 lastSeenHotkey = lastSeen[i];
                if (
                    lastSeenHotkey != richestHotkey && _isRotatedOut(lastSeenHotkey, currentSet)
                        && lastSeenBalances[i] > 0
                ) {
                    if (VaultMath.contains(barred, lastSeenHotkey)) {
                        // Pulled onto the roll it stays counted, and a settle that forgets the key
                        // drops nothing.
                        _pullBarredBalance(
                            clone, netuid, lastSeenHotkey, rollerHotkey, lastSeenBalances[i], alphaPriceE18
                        );
                    } else {
                        // Move the live pile: a same-subnet move can credit the roller one RAO short,
                        // so a carried arithmetic sum would over-ask the next hop. Reading the balance
                        // off the chain moves exactly what sits on the roller.
                        uint256 pile = IStaking(STAKING_PRECOMPILE).getStake(rollerHotkey, coldkey, netuid);
                        SubnetClone(payable(clone)).moveStake(rollerHotkey, lastSeenHotkey, netuid, pile);
                        rollerHotkey = lastSeenHotkey;
                    }
                }
                unchecked {
                    ++i;
                }
            }
            if (_isRotatedOut(rollerHotkey, currentSet)) {
                uint256 pile = IStaking(STAKING_PRECOMPILE).getStake(rollerHotkey, coldkey, netuid);
                SubnetClone(payable(clone))
                    .moveStake(rollerHotkey, currentSet[_openLandingIndex(currentSet, barred)], netuid, pile);
            }
        }
    }

    /// @dev Picks the richest hotkey across the remembered and current sets as the roll's start. Its
    ///      balance is the roll's binding floor check, so starting from anything smaller could trip
    ///      `ConsolidationBelowFloor` on a pile the chain would accept, and starting from rotated-out
    ///      dust would forfeit the self-healing case where a later above-floor deposit is the richest
    ///      balance and carries the rotated-out stake over. When no rotated-out balance remains, the
    ///      returned hotkey is only a placeholder.
    function _chooseRichestSlot(bytes32[] memory lastSeen, bytes32[] memory currentSet, bytes32 coldkey, uint16 netuid)
        private
        view
        returns (
            bytes32 richestHotkey,
            uint256 richestBalance,
            uint256[] memory lastSeenBalances,
            bool hasRotatedOutBalance
        )
    {
        lastSeenBalances = new uint256[](lastSeen.length);
        bytes32 richestRotatedOut;
        uint256 richestRotatedOutBalance;
        for (uint256 i; i < lastSeenBalances.length;) {
            bytes32 candidate = lastSeen[i];
            if (_isRotatedOut(candidate, currentSet)) {
                uint256 balance = IStaking(STAKING_PRECOMPILE).getStake(candidate, coldkey, netuid);
                lastSeenBalances[i] = balance;
                if (balance > richestRotatedOutBalance) {
                    richestRotatedOut = candidate;
                    richestRotatedOutBalance = balance;
                }
            }
            unchecked {
                ++i;
            }
        }
        if (richestRotatedOutBalance == 0) return (currentSet[0], 0, lastSeenBalances, false);

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

    function _rotatedOutActiveKeys(uint256 tokenId, bytes32[] memory logicalSet)
        private
        view
        returns (bytes32[] memory rotated)
    {
        VaultReads.Slot[] storage tokenSlots = _slots[tokenId];
        rotated = new bytes32[](tokenSlots.length);
        uint256 size;
        for (uint256 i; i < tokenSlots.length;) {
            if (!VaultMath.contains(logicalSet, tokenSlots[i].logical)) {
                rotated[size] = tokenSlots[i].active;
                unchecked {
                    ++size;
                }
            }
            unchecked {
                ++i;
            }
        }
        VaultMath.truncate(rotated, size);
    }

    function _barredActives(uint256 tokenId, bool[] memory unaccounted) private view returns (bytes32[] memory barred) {
        VaultReads.Slot[] storage tokenSlots = _slots[tokenId];
        barred = new bytes32[](unaccounted.length);
        uint256 size;
        for (uint256 i; i < unaccounted.length; ++i) {
            if (unaccounted[i]) {
                uint64 shortSince = tokenSlots[i].shortSince;
                // forge-lint: disable-next-line(block-timestamp)
                if (shortSince == 0 || block.timestamp < shortSince + VaultReads.RECOVERY_WINDOW) {
                    barred[size] = tokenSlots[i].active;
                    unchecked {
                        ++size;
                    }
                }
            }
        }
        VaultMath.truncate(barred, size);
    }

    function _isOpenDestination(bytes32 hotkey, bytes32[] memory barred) private view returns (bool) {
        if (VaultMath.contains(barred, hotkey)) return false;
        (bool exists,) = IStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkey);
        return exists;
    }

    function _openLandingIndex(bytes32[] memory currentSet, bytes32[] memory barred) private view returns (uint256) {
        for (uint256 i; i < currentSet.length;) {
            if (_isOpenDestination(currentSet[i], barred)) return i;
            unchecked {
                ++i;
            }
        }
        revert NoOpenDestination();
    }

    function _pullBarredBalance(
        address clone,
        uint16 netuid,
        bytes32 from,
        bytes32 collector,
        uint256 balance,
        uint256 alphaPriceE18
    ) private returns (bool) {
        if (_isBelowFloorAtAnyPrice(balance, alphaPriceE18)) return false;
        SubnetClone(payable(clone)).moveStake(from, collector, netuid, balance);
        return true;
    }

    /// @notice The keys the position's backing currently sits under.
    function lastSeenHotkeys(uint256 tokenId) external view returns (bytes32[] memory) {
        return VaultReads.activesOf(_slots[tokenId]);
    }

    // -------------------- Backing resolution -------------------------------------

    function recoverStray(uint256 tokenId, uint256 slotIndex, bytes32 hotkey) external nonReentrant {
        address clone = subnetClone[tokenId];
        if (clone == address(0)) revert NothingToUnwrap();
        uint16 netuid = VaultMath.netuidOf(tokenId);
        VaultReads.requireNotDissolving(netuid);

        VaultReads.Slot[] storage tokenSlots = _slots[tokenId];
        VaultReads.Slot storage slot = tokenSlots[slotIndex];
        // Naming a key another slot answers for would lean two expectations on one balance, and
        // naming an attested key while this slot's validator is also still attested would resolve
        // two validators onto one key. An attested key answering for a validator the set has
        // dropped is a genuine find: the registry replacing a swapped key is the common way home.
        (bytes32[] memory attested,) = VaultReads.resolveValidators(validatorRegistry, netuid);
        if (
            VaultMath.contains(VaultReads.activesOf(tokenSlots), hotkey)
                || (VaultMath.contains(attested, hotkey) && VaultMath.contains(attested, slot.logical))
        ) {
            revert HotkeyClaimedTwice();
        }

        bytes32 coldkey = VaultReads.coldkeyOf(clone);
        uint256 tracked = slot.tracked;
        if (
            IStaking(STAKING_PRECOMPILE).getStake(slot.active, coldkey, netuid) + VaultReads.TRACKED_SLACK_RAO
                >= tracked
        ) {
            revert BackingIntact();
        }
        uint256 found = IStaking(STAKING_PRECOMPILE).getStake(hotkey, coldkey, netuid);
        if (found + VaultReads.TRACKED_SLACK_RAO < tracked) revert NothingStrayUnder();

        slot.active = hotkey;
        // Finding the alpha shows the vault was wrong to have given up on it.
        slot.shortSince = 0;
        emit BackingRecovered(tokenId, hotkey, found);
    }

    function declareShortfall(uint256 tokenId) external nonReentrant {
        address clone = subnetClone[tokenId];
        if (clone == address(0)) revert NothingToUnwrap();
        uint16 netuid = VaultMath.netuidOf(tokenId);
        VaultReads.requireNotDissolving(netuid);
        if (VaultReads.isIssuedForDissolvedSubnet(tokenId)) revert BackingIntact();
        (bytes32[] memory logicalSet,) = VaultReads.resolveValidators(validatorRegistry, netuid);

        VaultReads.Plan memory plan =
            VaultReads.planBacking(_slots[tokenId], logicalSet, VaultReads.coldkeyOf(clone), netuid);
        if (plan.shortIndex == type(uint256).max) revert BackingIntact();
        _applyFollows(tokenId, plan.keys);
        _syncShortfallClocks(tokenId, plan);
    }

    /// @dev Reverts on the first standing shortfall, deciding what stands through the same
    ///      library scan the lens quotes with, so a quote never promises what the call refuses.
    function _requireNoStandingShortfall(uint256 tokenId, uint16 netuid, VaultReads.Plan memory plan) private view {
        VaultReads.Slot[] memory slots = _slots[tokenId];
        uint256 first = VaultReads.firstStandingShortfall(slots, plan);
        if (first == type(uint256).max) return;
        revert BackingShortfall(netuid, slots[first].active, slots[first].tracked);
    }

    function _syncShortfallClocks(uint256 tokenId, VaultReads.Plan memory plan) private {
        VaultReads.Slot[] storage tokenSlots = _slots[tokenId];
        for (uint256 i; i < plan.unaccounted.length;) {
            VaultReads.Slot storage slot = tokenSlots[i];
            if (plan.unaccounted[i]) {
                if (slot.shortSince == 0) {
                    // forge-lint: disable-next-line(block-timestamp)
                    slot.shortSince = uint64(block.timestamp);
                    emit ShortfallDeclared(tokenId, slot.active, slot.tracked);
                }
            } else if (slot.shortSince != 0) {
                slot.shortSince = 0;
            }
            unchecked {
                ++i;
            }
        }
    }

    function _resolveAndFollow(
        uint256 tokenId,
        uint16 netuid,
        bytes32 coldkey,
        bytes32[] memory logicalSet,
        bool refuseShortfall
    ) private returns (VaultReads.Plan memory plan) {
        plan = VaultReads.planBacking(_slots[tokenId], logicalSet, coldkey, netuid);
        // A rail that would mint waits out every standing window - it reverts, and a revert cannot
        // leave a stamp behind. Exits pass regardless: they pay out of what is located, and their
        // clock sync below is the vault's only chance to notice a loss unprompted.
        if (refuseShortfall) _requireNoStandingShortfall(tokenId, netuid, plan);
        _applyFollows(tokenId, plan.keys);
        _syncShortfallClocks(tokenId, plan);
    }

    function _applyFollows(uint256 tokenId, bytes32[] memory keys) private {
        VaultReads.Slot[] storage tokenSlots = _slots[tokenId];
        for (uint256 i; i < tokenSlots.length;) {
            if (tokenSlots[i].active != keys[i]) {
                emit HotkeySwapFollowed(tokenId, tokenSlots[i].active, keys[i]);
                tokenSlots[i].active = keys[i];
            }
            unchecked {
                ++i;
            }
        }
    }

    function _effectiveSet(uint256 tokenId, bytes32[] memory logicalSet)
        private
        view
        returns (bytes32[] memory effective)
    {
        VaultReads.Slot[] storage tokenSlots = _slots[tokenId];
        uint256 slotCount = tokenSlots.length;
        effective = new bytes32[](logicalSet.length);
        for (uint256 i; i < logicalSet.length;) {
            bytes32 logical = logicalSet[i];
            effective[i] = logical;
            // The record is written in set order, so it stays aligned until the attesters reorder.
            if (i < slotCount && tokenSlots[i].logical == logical) {
                effective[i] = tokenSlots[i].active;
            } else {
                for (uint256 j; j < slotCount;) {
                    if (tokenSlots[j].logical == logical) {
                        effective[i] = tokenSlots[j].active;
                        break;
                    }
                    unchecked {
                        ++j;
                    }
                }
            }
            unchecked {
                ++i;
            }
        }
        // A followed hotkey swap can land on a key another slot already answers for, and two slots
        // leaning on one balance would count it twice. Only a slot a swap has moved can collide -
        // the registry rejects a set naming one validator twice - so an untouched set pays a single
        // comparison per entry. The attesters clear a real collision by dropping one of the pair.
        for (uint256 i; i < logicalSet.length;) {
            if (effective[i] != logicalSet[i] && _appearsTwice(effective, i)) {
                revert HotkeyClaimedTwice();
            }
            unchecked {
                ++i;
            }
        }
    }

    function _appearsTwice(bytes32[] memory set, uint256 index) private pure returns (bool) {
        bytes32 key = set[index];
        return VaultMath.keysHold(set, 0, index, key) || VaultMath.keysHold(set, index + 1, set.length, key);
    }

    function _retireStamp(uint256 tokenId, VaultReads.Slot storage slot) private {
        if (slot.shortSince == 0) return;
        slot.shortSince = 0;
        emit ShortfallWrittenOff(tokenId, slot.active, slot.tracked);
    }

    function _settleRecord(
        uint256 tokenId,
        bytes32 coldkey,
        uint16 netuid,
        bytes32[] memory logicalSet,
        bytes32[] memory effectiveSet,
        VaultReads.Plan memory plan
    ) private {
        if (plan.shortIndex == type(uint256).max) {
            _settleSlots(tokenId, coldkey, logicalSet, effectiveSet);
        } else {
            _reanchorTracked(tokenId, coldkey, netuid, plan.unaccounted);
        }
    }

    function _settleSlots(uint256 tokenId, bytes32 coldkey, bytes32[] memory logicalSet, bytes32[] memory effectiveSet)
        private
    {
        VaultReads.Slot[] storage tokenSlots = _slots[tokenId];
        uint16 netuid = VaultMath.netuidOf(tokenId);
        for (uint256 i; i < tokenSlots.length;) {
            _retireStamp(tokenId, tokenSlots[i]);
            unchecked {
                ++i;
            }
        }
        while (tokenSlots.length > logicalSet.length) {
            tokenSlots.pop();
        }
        for (uint256 i; i < logicalSet.length;) {
            uint256 tracked = IStaking(STAKING_PRECOMPILE).getStake(effectiveSet[i], coldkey, netuid);
            if (i < tokenSlots.length) {
                VaultReads.Slot storage slot = tokenSlots[i];
                slot.logical = logicalSet[i];
                slot.active = effectiveSet[i];
                slot.tracked = tracked;
            } else {
                tokenSlots.push(
                    VaultReads.Slot({
                        logical: logicalSet[i], active: effectiveSet[i], tracked: tracked, shortSince: 0
                    })
                );
            }
            unchecked {
                ++i;
            }
        }
    }

    function _reanchorTracked(uint256 tokenId, bytes32 coldkey, uint16 netuid, bool[] memory unaccounted) private {
        VaultReads.Slot[] storage tokenSlots = _slots[tokenId];
        for (uint256 i; i < tokenSlots.length;) {
            // A slot the plan could not account for keeps its expectation and its clock: lowering
            // either here would be the write-off, which only a full settle takes.
            if (!unaccounted[i]) {
                VaultReads.Slot storage slot = tokenSlots[i];
                uint256 stake = IStaking(STAKING_PRECOMPILE).getStake(slot.active, coldkey, netuid);
                if (slot.tracked != stake) slot.tracked = stake;
            }
            unchecked {
                ++i;
            }
        }
    }

    function recordedSlots(uint256 tokenId) external view returns (VaultReads.Slot[] memory) {
        return _slots[tokenId];
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

    // -------------------- TAO Claim Index ----------------------------------------

    /// @dev Folds TAO the clone received since the last synchronization into the per-share index.
    function _syncTao(uint256 tokenId) private {
        address clone = subnetClone[tokenId];
        if (clone == address(0)) return;
        // An empty clone is the common case on every balance change, so it exits before the
        // liability lookup.
        uint256 balance = clone.balance;
        if (balance == 0) return;
        uint256 newTao = VaultReads.indexableTao(tokenId, balance, taoLiability[tokenId]);
        if (newTao == 0) return;
        (uint256 indexIncrease, uint256 liabilityIncrease) = VaultMath.syncAmounts(newTao, totalSupply(tokenId));
        if (indexIncrease == 0) return;
        cumulativeTaoPerShare[tokenId] += indexIncrease;
        taoLiability[tokenId] += liabilityIncrease;
    }

    /// @dev Banks the account's earned-but-unrecorded TAO and re-anchors its debt at `index`;
    ///      repeating it at an unchanged balance is a no-op.
    function _checkpoint(address account, uint256 tokenId, uint256 index) private {
        uint256 earned = VaultMath.earnedAt(balanceOf(account, tokenId), index);
        uint256 credit = VaultMath.pendingTao(earned, taoIndexDebt[tokenId][account]);
        if (credit != 0) claimableTao[tokenId][account] += credit;
        taoIndexDebt[tokenId][account] = earned;
    }

    function _settleIndexDebt(address account, uint256 tokenId, uint256 index) private {
        taoIndexDebt[tokenId][account] = VaultMath.earnedAt(balanceOf(account, tokenId), index);
    }

    // -------------------- Overrides ---------------------------------------------

    /// @dev Settles the TAO claim index around every balance change: checkpoints against
    ///      pre-change balances, then re-anchors debts to post-change balances before any
    ///      acceptance callback runs. Checkpointing settles as it credits, so repeated ids and
    ///      self-transfers are natural no-ops.
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override(ERC1155, ERC1155Supply)
    {
        for (uint256 i; i < ids.length;) {
            uint256 id = ids[i];
            _syncTao(id);
            uint256 index = cumulativeTaoPerShare[id];
            // A zero index means no TAO was ever indexed for this id, so no debt or entitlement
            // can exist and settlement is a no-op.
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
