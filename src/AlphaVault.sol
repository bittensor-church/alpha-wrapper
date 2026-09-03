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
///     stranded.
///   - Each token carries one compact record per attested validator, holding the exact alpha the
///     last call read under it. A validator hotkey swap is resolved from the chain's own successor
///     edge, one hop and no further. Backing that record cannot account for shuts every
///     share-pricing and alpha-moving path until `syncBacking` books it, which it may do once
///     the recovery window fixed at deployment has run. Anyone may call `recoverStray`
///     meanwhile; whatever is still missing then falls across the holders of the moment.
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
    /// @notice How long anyone has to point the vault at missing alpha before the remainder is
    ///         written off across the holders of the moment. Each slot's loss runs its own window.
    uint256 public immutable recoveryWindow;

    // -------------------- State -------------------------------------------------
    mapping(address => bool) public cloneDeployed;
    mapping(uint256 => address) public subnetClone;

    /// @dev What the vault expects to find and where, one record per attested validator; rewritten
    ///      from the chain by every call that moves the position.
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
    /// @notice Backing the vault could not account for, and the moment its recovery window started.
    ///         Until that window runs out every share-pricing and alpha-moving path refuses.
    event BackingShortfallDeclared(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 expected, uint256 located);
    /// @notice A recovery window ran out with backing still missing: the remainder is given up on
    ///         and the loss falls on everyone holding shares from here on.
    event BackingWrittenOff(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 expected, uint256 located);
    /// @notice Alpha of the vault's own was moved back under the key a slot expects it at.
    event BackingRecovered(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 amount);

    // -------------------- Constructor -------------------------------------------
    /// @param _uri ERC1155 metadata URI template, fixed for the contract's lifetime.
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

    /// @notice Flush the caller's mailbox stake under `chosenHotkey` to the subnet clone and
    ///         rebalance the position to the attested BPS weights.
    /// @dev    Shares mint to the caller; no account can flush another account's mailbox.
    ///         The call flushes only the mailbox balance recorded under `chosenHotkey`; a mailbox
    ///         holding stake under multiple hotkeys requires one `wrap` per hotkey.
    ///         `chosenHotkey` must be in the current attested validator set; reverts with
    ///         `ChosenHotkeyNotInSet` otherwise. Use `reclaimAlphaFromMailbox` to recover alpha
    ///         parked under any other key, a deposit a hotkey swap carried away included.
    ///         Reverts `BackingShortfall` while the position holds backing it cannot account for -
    ///         before the mailbox is flushed, so a deposit never recapitalizes a standing loss.
    ///         Reverts `DepositTooSmall` when the deposit's tao value is below the chain's stake
    ///         floor at a readable price; at a zero price read the flush falls through to the chain.
    ///         The fresh deposit lands before the consolidation so the roll can start from it,
    ///         letting rotated-out dust be consolidated even when it is the only other balance.
    ///         Rebalance moves below the stake floor are skipped pre-call, so small deposits may
    ///         leave the position drifted from target weights until a later deposit or unwrap
    ///         produces a movable residual.
    ///         Reverts `SubnetInDissolutionBlackoutPeriod` while a dissolving subnet still has a
    ///         registration block, then `SubnetNotRegistered` once cleanup has removed it.
    ///         `minSharesOut` bounds the mint against rate movement between quote and execution,
    ///         and is sized from the lens `previewWrap`, which prices the same backing.
    /// @param  netuid       Subnet the deposit sits on.
    /// @param  chosenHotkey Attested validator hotkey the mailbox balance is staked under.
    /// @param  minSharesOut Slippage floor; revert if fewer shares would mint.
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
        bytes32[] memory actives = _assignActives(slots, backing, hotkeys);

        uint256 totalDeposit = _mailboxBalance(userClone, chosenHotkey, nid);
        if (totalDeposit == 0) revert ZeroAmount();

        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(nid);
        if (_isBelowFloorAtReadPrice(totalDeposit, alphaPriceE18)) {
            revert DepositTooSmall();
        }

        // Flush before the consolidation so the roll can start from the fresh deposit.
        DepositMailbox(payable(userClone)).flush(destColdkey, chosenHotkey, netuid, totalDeposit);
        // Pricing reads only the active keys, so the deposit must sit under one before the mint.
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
        // Recapitalizing a swept position multiplies supply toward the bound; retiring the swept
        // shares through the zero-backing unwrap resets supply and lifts it.
        if (totalSupply(tokenId) + shares > SUPPLY_CAP) revert SupplyCapExceeded();

        _mint(msg.sender, tokenId, shares, "");

        emit Deposited(msg.sender, tokenId, totalDeposit, shares);
    }

    // -------------------- Unwrap Flow -----------------------------------------

    /// @notice Burn shares and pay out the underlying position.
    /// @dev    Reverts `SubnetInDissolutionBlackoutPeriod` while subtensor's asynchronous
    ///         cleanup of the netuid is in progress (alpha and TAO refunds are in flux). A
    ///         position a later subnet has already replaced keeps paying through that subnet's
    ///         cleanup, except in its late window once the registration block reads zero.
    ///         Then dispatches on subnet state:
    ///           - permanently dissolved (tokenId's registrationBlock no longer current): pays pro-rata
    ///             native TAO from the clone's refund balance.
    ///           - live: consolidates the position onto one hotkey and delivers the full pro-rata
    ///             alpha to `userSubstrateColdkey` in a single transfer (exact to within a few RAO
    ///             of chain-side share rounding, or reverting - never partial), then re-splits the
    ///             remainder toward the attested weights.
    ///             At a readable price, reverts `WithdrawTooSmall` when the request is below the
    ///             chain's floor, `GatherBelowFloor` when the gather's largest slot provably cannot
    ///             clear it, and `ConsolidationBelowFloor` when pending rotated-out stake cannot be
    ///             consolidated above it; such positions exit via `unwrapForTao`.
    ///             Reverts `ZeroColdkey` when the live-path destination is the zero Substrate account.
    ///             `minAlphaOut` bounds the alpha sent. A positive bound also protects
    ///             a caller whose transaction crosses into dissolution, where this function pays
    ///             TAO rather than alpha. Passing zero explicitly permits that payout and permits
    ///             retiring shares for zero alpha after all backing has been written off; any alpha
    ///             recovered later belongs to the shares still outstanding at recovery time.
    ///             Reverts `BackingShortfall` while the position holds backing it cannot account
    ///             for; `syncBacking` reopens the token by booking the loss.
    /// @param  tokenId              ERC1155 tokenId identifying the (netuid, registrationBlock) position.
    /// @param  shares               Shares to burn.
    /// @param  userSubstrateColdkey Destination coldkey for alpha on the live path (unused on dissolved path).
    /// @param  minAlphaOut           Slippage floor; revert if alpha sent is less. Set to zero to
    ///                               accept a dissolved TAO payout or a zero-backing share retirement.
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

    /// @notice Burn vault shares pro-rata and pay the caller native TAO from selling the backing alpha.
    /// @dev    Opt-in risk exit - prefer `unwrap` wherever the chain still moves stake.
    ///         This rail liquidates the backing through the subnet's constant-product AMM, and the
    ///         two sell rounds move that pool's price permanently. The proceeds go to the caller
    ///         (`minTaoOut` included), but the depressed price stays with the holders who remain:
    ///         an on-chain sell here taxes the stayers, never the withdrawer. `unwrap` pays the same
    ///         shares out as staked alpha with no pool interaction at all, so use this rail only
    ///         when `unwrap` is unavailable (subnet owner disabled alpha transfers) or the floor
    ///         makes `unwrap` refuse.
    ///         Full-balance sells go straight to the chain - full drains are exempt from its
    ///         minimum - and their failures bubble.
    ///         A full burn claims the exact backing, so every slot drains fully and nothing is
    ///         withheld - the only exit for a sub-floor position. On a partial burn the remainder
    ///         is sold only when the chain is sure to take it cleanly - to within one RAO of quote
    ///         rounding; whatever stays staked is refunded as shares, so selling less than the
    ///         request costs the caller nothing but the retry. A full burn drops a sub-floor
    ///         remainder rather than mint a position that would need exiting again.
    ///         `minTaoOut` guards the caller against a fill smaller than they will accept;
    ///         `WithdrawTooSmall` fires when nothing sells. It is also the exit to use when the
    ///         subnet's alpha price reads zero on EVM: there the alpha rail can revert at full gas
    ///         while consolidating rotated-out dust, and only a full burn here still exits - while
    ///         the pool can sell it.
    ///         Reverts `SubnetInDissolutionBlackoutPeriod` while the subnet is being dissolved.
    /// @param  tokenId    Vault token id.
    /// @param  shares     Shares to burn.
    /// @param  minTaoOut  Slippage floor; revert if realized TAO is less.
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
        uint256[] memory postBalances = VaultReads.fetchBalances(hotkeys, vaultColdkey, netuid);
        uint256 sold = total - VaultMath.sumBalances(postBalances);
        // The sells moved no stake between validators, so the record only re-anchors what each slot
        // holds; the attested set has nothing to say about it.
        _reanchor(tokenId, hotkeys, postBalances);
        uint256 unsold = assets - sold;
        // The chain keeps a RAO or so of every sale; refunding that to a full exit would mint a
        // sub-floor position no rail can ever sell. A partial burn keeps it - it merges into the
        // balance already held.
        if (unsold != 0 && shares == supply) {
            uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);
            if (_isBelowFloorAtReadPrice(unsold, alphaPriceE18)) unsold = 0;
        }

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
        uint16 netuid,
        uint256 minAlphaOut
    ) private {
        (bytes32[] memory hotkeys, uint16[] memory weights) = VaultReads.resolveValidators(validatorRegistry, netuid);
        bytes32 coldkey = VaultReads.coldkeyOf(clone);
        (VaultReads.Slot[] memory slots, VaultReads.Backing memory backing) = _openBacking(tokenId, coldkey, netuid);
        bytes32[] memory actives = _assignActives(slots, backing, hotkeys);
        // Nothing on this path trades against the pool, so one price read holds for the whole call.
        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);
        _consolidateRotatedStake(clone, coldkey, netuid, backing.keys, actives, alphaPriceE18);

        // After consolidation the whole backing sits on the keys the record is about to name, so
        // their balances count everything.
        uint256[] memory balances = VaultReads.fetchBalances(actives, coldkey, netuid);
        uint256 totalAlpha = VaultMath.sumBalances(balances);
        // After a complete write-off these shares have no current alpha entitlement. A zero floor
        // explicitly accepts their retirement; a positive one preserves them for a possible late
        // recovery. The burn's checkpoint keeps any swept-sale proceeds claimable either way.
        if (totalAlpha == 0) {
            if (minAlphaOut != 0) revert SlippageExceeded(0);
            _settle(tokenId, coldkey, hotkeys, actives);
            _burn(msg.sender, tokenId, shares);
            emit Unwrapped(msg.sender, tokenId, shares, 0);
            return;
        }

        uint256 assets = VaultMath.assetsFor(totalAlpha, totalSupply(tokenId), shares);
        if (assets == 0) revert ZeroAmount();
        if (assets < minAlphaOut) revert SlippageExceeded(assets);

        // A sub-floor request is undeliverable on the alpha rail (the chain rejects the transfer);
        // reverting keeps delivery exact and points dust positions at unwrapForTao. A zero read
        // falls through to the chain on the delivery below.
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

    /// @dev Delivers `assets` to `userColdkey` in one transfer - gathering the position onto a
    ///      single hotkey first when no slot covers the request - then re-splits what remains toward
    ///      `weights`. Reverts `GatherBelowFloor` when the gather's largest slot provably cannot
    ///      clear the stake floor.
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
        // Re-read live balances so the weight re-split never moves more than a slot holds.
        uint256[] memory postBalances = VaultReads.fetchBalances(hotkeys, coldkey, netuid);
        _alignToWeights(tokenId, clone, hotkeys, weights, postBalances, alphaPriceE18);
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

    /// @notice Rebalance vault stake for a subnet toward registry target weights.
    ///         Anyone can call this (e.g. after validator registry update).
    /// @dev    Sub-floor and zero-price moves are skipped. Reverts `ConsolidationBelowFloor` when
    ///         pending rotated-out stake cannot be consolidated above the chain's floor; any other
    ///         rejected move bubbles the chain's error.
    ///         Reverts `BackingShortfall` while the position holds backing it cannot account for;
    ///         once `syncBacking` books the loss and reopens the token, this call settles the
    ///         record on what is left.
    ///         Reverts `SubnetInDissolutionBlackoutPeriod` while a dissolving subnet still has a
    ///         registration block, then `SubnetNotRegistered` once cleanup has removed it.
    /// @param netuid The subnet to rebalance.
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
        bytes32[] memory actives = _assignActives(slots, backing, hotkeys);
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

        // Each step settles at least one slot exactly at its target, and surpluses and deficits
        // cancel out, so settling all but one slot settles the last one too. The floor cannot
        // change mid-transaction, so one read serves every step.
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
    ///      A zero read proves nothing and never rejects; the amount falls through to the chain.
    function _isBelowFloorAtReadPrice(uint256 alphaAmount, uint256 alphaPriceE18) private view returns (bool) {
        return alphaPriceE18 != 0 && _taoValue(alphaAmount, alphaPriceE18) < _minStakeTao();
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

    /// @dev Rolls stake stranded on keys the record is about to stop naming back onto the ones it
    ///      will, so the position's backing always sits where the next call will look for it.
    ///      Reverts `ConsolidationBelowFloor` when even the richest balance provably cannot clear
    ///      the stake floor; a zero price read skips the guard, so a roll the chain then rejects
    ///      burns the forwarded gas.
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
            // Every hop moves the whole pile and the pile only grows, so the richest balance - where
            // the roll starts - is the binding floor check for the entire roll.
            if (hasRotatedOutBalance && _isBelowFloorAtAnyPrice(richestBalance, alphaPriceE18)) {
                revert ConsolidationBelowFloor();
            }
            // The richest slot's balance is already in the pile; its cached balance goes stale once
            // the pile departs, so the roll must never revisit it. No other slot can repeat: a
            // validator set holds no duplicate hotkeys.
            bytes32 richestHotkey = rollerHotkey;
            for (uint256 i; i < sourceBalances.length;) {
                bytes32 sourceHotkey = sourceKeys[i];
                if (sourceHotkey != richestHotkey && _isRotatedOut(sourceHotkey, currentSet) && sourceBalances[i] > 0) {
                    // Move the live pile: a same-subnet move can credit the roller one RAO short, so a
                    // carried arithmetic sum would over-ask the next hop. Reading the balance off the
                    // chain moves exactly what sits on the roller.
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

    /// @dev Picks the richest hotkey across the source and destination keys as the roll's start. Its
    ///      balance is the roll's binding floor check, so starting from anything smaller could trip
    ///      `ConsolidationBelowFloor` on a pile the chain would accept, and starting from rotated-out
    ///      dust would forfeit the self-healing case where a later above-floor deposit is the richest
    ///      balance and carries the rotated-out stake over. When no rotated-out balance remains, the
    ///      returned hotkey is only a placeholder.
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

    // -------------------- Backing record ----------------------------------------

    /// @notice Move alpha of the vault's own back under the key of the slot it makes whole.
    /// @dev    Safe to leave permissionless: only the subnet clone can move stake held under its
    ///         coldkey. Third parties can transfer stake in, but moving any balance found there
    ///         between the clone's keys can only bring it into view as holders' backing.
    ///         The chain moves stake entries whole - a swap migrates the full balance, the dust
    ///         sweep removes an entire entry - so a slot's loss sits under exactly one key. The
    ///         vault aims the find at the short slot with the largest expectation it covers; a
    ///         source that covers none is not where the backing went (`RecoveryIncomplete`). A
    ///         whole record takes a late find on its first slot as new backing.
    ///         A key some slot resolves to is refused as source because one slot is never
    ///         recapitalized out of another.
    ///         Both keys must be owned on chain: a watcher claims an abandoned hotkey before
    ///         pointing the vault at it, and the move here reverts until they have.
    /// @param  tokenId      ERC1155 tokenId identifying the (netuid, registrationBlock) position.
    /// @param  sourceHotkey The key currently holding the alpha.
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
        // Anchor the expectation to the re-read, as every settling rail does: a lump larger than
        // the loss raises what the slot answers for from here on.
        if (slot.tracked != recovered) slot.tracked = recovered;
        if (slot.shortSince != 0) slot.shortSince = 0;
        emit BackingRecovered(tokenId, target, amount);
    }

    /// @dev The short slot with the largest expectation `amount` covers. Reverts when a loss
    ///      stands and the source covers none of it; a whole record takes the find on slot 0.
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

    /// @notice Bring the record in line with the chain without moving any alpha: start a recovery
    ///         window on backing that has gone missing, end one on backing that came back, and
    ///         write off what nobody recovered before its window ran out.
    /// @param  tokenId ERC1155 tokenId identifying the (netuid, registrationBlock) position.
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

    /// @notice The full record for a token, one entry per attested validator.
    function recordedSlots(uint256 tokenId) external view returns (VaultReads.Slot[] memory) {
        return _slots[tokenId];
    }

    /// @dev Reads the record and refuses the call while any backing is unaccounted for. Every rail
    ///      that prices shares or moves alpha starts here.
    function _openBacking(uint256 tokenId, bytes32 coldkey, uint16 netuid)
        private
        view
        returns (VaultReads.Slot[] memory slots, VaultReads.Backing memory backing)
    {
        slots = _slots[tokenId];
        backing = VaultReads.resolveBacking(slots, coldkey, netuid);
        // Deliberately regardless of the clock: only `syncBacking` books a loss.
        VaultReads.requireIntact(slots, backing, netuid);
    }

    /// @dev The key each attested validator's alpha sits under: the slot's resolved key while it
    ///      holds anything, the attested name otherwise. No two entries may land on one key, so
    ///      an emptied entry whose name carries another slot's alpha keeps its resolved key, and
    ///      a name with no key of its own in that position reverts `SwappedHotkeyStillAttested` -
    ///      only the attesters can untangle a set listing a swapped-away name beside its
    ///      successor.
    function _assignActives(
        VaultReads.Slot[] memory slots,
        VaultReads.Backing memory backing,
        bytes32[] memory currentSet
    ) private pure returns (bytes32[] memory actives) {
        // The loop below runs `indexOf` - a linear scan - per entry, so the names are read into
        // a flat array once instead of per scan.
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
            if (at != type(uint256).max && backing.balances[at] != 0) {
                actives[i] = backing.keys[at];
            } else {
                // Another slot may answer under this entry's name. It keeps that key while its
                // own validator stays attested, even while empty, and releases it once dropped.
                uint256 holder = VaultMath.indexOf(backing.keys, name);
                bool nameTaken =
                    holder != type(uint256).max && holder != at && VaultMath.contains(currentSet, logicals[holder]);
                if (!nameTaken) {
                    actives[i] = name;
                } else if (at != type(uint256).max) {
                    actives[i] = backing.keys[at];
                } else {
                    revert SwappedHotkeyStillAttested();
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Rewrites the record from the chain once the position has been moved: one slot per
    ///      attested validator, anchored to the balance its key holds now. Clocks clear here, which
    ///      is what turns a lapsed expectation into a written-off one.
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
                // Write only the fields that changed: at the validator cap the record spans
                // hundreds of storage words, and an ordinary call leaves most of them as they were.
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

    /// @dev Takes what each slot's key holds now as its new expectation, for a call that changed
    ///      balances without moving the position between validators. Every slot keeps the key the
    ///      resolver put it on, emptied or not: those are distinct, while attested names are not -
    ///      a swap can carry one validator's alpha onto another's name, and falling back here would
    ///      leave two slots on one balance. The next settle picks the name up where that is safe.
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
