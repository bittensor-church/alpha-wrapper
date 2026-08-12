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
import { IAddressMapping, ADDRESS_MAPPING_PRECOMPILE } from "./interfaces/IAddressMapping.sol";
import { ISubnet, SUBNET_PRECOMPILE } from "./interfaces/ISubnet.sol";

/// @title AlphaVault
/// @notice ERC1155 multi-vault that wraps Bittensor Alpha Stake into fungible share tokens.
///         Each subnet has its own EIP-1167 clone holding alpha under an isolated coldkey.
///
/// @dev Architecture:
///   - Token ID = (netuid | registrationBlock << 16). No registration needed - vaults materialize on first deposit.
///   - Each vault tracks its own sharePrice independently: totalStake(tokenId) / totalSupply(tokenId).
///     Integrators should read `sharePrice`, which also reverts during dissolution.
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

    /// @dev Validators the clone's stake was distributed across at the last state-mutating call;
    ///      refreshed only after a clean consolidation.
    mapping(uint256 => bytes32[]) private _lastSeenHotkeys;

    /// @dev Registry set version behind `_lastSeenHotkeys`. While it matches the registry's, the
    ///      attested membership cannot have moved, so rotation handling reads no history at all -
    ///      the difference between one storage read and up to sixty-four on every call.
    mapping(uint256 => uint256) private _lastSeenVersion;

    /// @notice Cumulative TAO credited per share over a token's lifetime, scaled by
    ///         `TAO_INDEX_PRECISION`. Grows when the clone receives TAO the vault did not pay out.
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
    /// @dev Virtual shares/assets to prevent inflation attacks (ERC4626 pattern).
    uint256 private constant VIRTUAL_SHARES = 1e9;
    uint256 private constant VIRTUAL_ASSETS = 1;
    uint16 private constant BPS_BASE = 10_000;
    /// @dev Most hotkeys the staking precompile's batched balance read accepts in one call.
    uint256 private constant MAX_BATCH_HOTKEYS = 64;
    /// @dev `getAlphaPrice` rounds down to a multiple of this (e18 scale), so the true price is
    ///      always below the read plus one step.
    uint256 private constant ALPHA_PRICE_QUANTUM_E18 = 1e9;
    /// @dev Claim-index scale.
    uint256 private constant TAO_INDEX_PRECISION = 1e36;
    /// @dev Native TAO carries 9 decimals behind the 18-decimal EVM interface, so a value transfer
    ///      delivers only whole multiples of this quantum.
    uint256 private constant TAO_NATIVE_QUANTUM = 1e9;
    /// @dev Post-mint share-supply bound. Below it a synchronization's flooring loses less than
    ///      one native quantum and any whole-quantum arrival moves the claim index; only a
    ///      swept-then-recapitalized position can approach it.
    uint256 private constant SUPPLY_CAP = TAO_NATIVE_QUANTUM * TAO_INDEX_PRECISION;

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

    // -------------------- Errors ------------------------------------------------
    error ZeroAmount();
    error ZeroAddress();
    error ZeroHotkey();
    error ZeroColdkey();
    error InsufficientShares();
    error NoValidatorFound();
    error SubnetNotRegistered();
    error SubnetInDissolutionBlackoutPeriod();
    error SubnetDissolved();
    error NothingToUnwrap();
    error NoSharesOutstanding();
    error DepositTooSmall();
    error WithdrawTooSmall();
    error ClaimBelowNativePrecision();
    error SupplyCapExceeded();
    error NetuidOutOfRange();
    error ChosenHotkeyNotInSet();
    error SlippageExceeded(uint256 amountOut);
    error GatherBelowFloor();

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

    /// @notice Flush the caller's mailbox stake under `chosenHotkey` to the subnet clone and
    ///         rebalance the position to the attested BPS weights.
    /// @dev    Shares mint to the caller; no account can flush another account's mailbox.
    ///         The call flushes only the mailbox balance recorded under `chosenHotkey`; a mailbox
    ///         holding stake under multiple hotkeys requires one `wrap` per hotkey.
    ///         `chosenHotkey` must be in the current attested validator set; reverts with
    ///         `ChosenHotkeyNotInSet` otherwise. Use `reclaimAlphaFromMailbox` to recover alpha
    ///         parked under a non-attested hotkey.
    ///         Reverts `DepositTooSmall` when the deposit's tao value is below the chain's stake
    ///         floor at a readable price; at a zero price read the flush falls through to the chain.
    ///         The fresh deposit lands before the consolidation so the roll can start from it,
    ///         letting rotated-out dust be consolidated even when it is the only other balance.
    ///         Rebalance moves below the stake floor are skipped pre-call, so small deposits may
    ///         leave the position drifted from target weights until a later deposit or unwrap
    ///         produces a movable residual.
    ///         Reverts `SubnetInDissolutionBlackoutPeriod` while a dissolving subnet still has a
    ///         registration block, then `SubnetNotRegistered` once cleanup has removed it.
    function wrap(uint256 netuid, bytes32 chosenHotkey) external nonReentrant {
        if (chosenHotkey == bytes32(0)) revert ZeroHotkey();

        uint256 tokenId = currentTokenId(netuid);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 nid = uint16(netuid);
        _requireNotDissolving(nid);
        (bytes32[] memory hotkeys, uint16[] memory weights, uint256 version) = _resolveValidators(nid);

        if (!_contains(hotkeys, chosenHotkey)) revert ChosenHotkeyNotInSet();

        address clone = subnetClone[tokenId];
        if (clone == address(0)) clone = _deploySubnetClone(tokenId);

        address userClone = _ensureMailboxClone(msg.sender, netuid);
        bytes32 destColdkey = _coldkeyOf(clone);

        uint256 totalDeposit = IStaking(STAKING_PRECOMPILE).getStake(chosenHotkey, _coldkeyOf(userClone), netuid);
        if (totalDeposit == 0) revert ZeroAmount();

        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(nid);
        if (alphaPriceE18 != 0 && _isBelowFloorAtReadPrice(totalDeposit, alphaPriceE18)) {
            revert DepositTooSmall();
        }

        // Land the deposit before settling so the fresh alpha is available to carry rotated-out
        // dust that could not clear the floor on its own.
        DepositMailbox(payable(userClone)).flush(destColdkey, chosenHotkey, netuid, totalDeposit);

        uint256 totalAlpha = _realign(tokenId, clone, hotkeys, weights, version, destColdkey, alphaPriceE18);

        uint256 preStake = totalAlpha > totalDeposit ? totalAlpha - totalDeposit : 0;
        uint256 shares = _sharesFor(preStake, totalSupply(tokenId), totalDeposit);
        if (shares == 0) revert ZeroAmount();
        // Recapitalizing a swept position multiplies supply toward the bound; retiring the swept
        // shares through the zero-backing unwrap resets supply and lifts it.
        if (totalSupply(tokenId) + shares > SUPPLY_CAP) revert SupplyCapExceeded();

        _mint(msg.sender, tokenId, shares, "");

        emit Deposited(msg.sender, tokenId, totalDeposit, shares);
    }

    // -------------------- Unwrap Flow -----------------------------------------

    /// @notice Burn shares and pay out the underlying position.
    /// @dev    Reverts `SubnetInDissolutionBlackoutPeriod` while subtensor's asynchronous
    ///         cleanup of the netuid is in progress (alpha and TAO refunds are in flux),
    ///         then dispatches on subnet state:
    ///           - permanently dissolved (tokenId's registrationBlock no longer current): pays pro-rata
    ///             native TAO from the clone's refund balance.
    ///           - live: consolidates the position onto one hotkey and delivers the full pro-rata
    ///             alpha to `userSubstrateColdkey` in a single transfer (exact to within a few RAO
    ///             of chain-side share rounding, or reverting - never partial), then re-splits the
    ///             remainder toward the attested weights.
    ///             At a readable price, reverts `WithdrawTooSmall` when the request is below the
    ///             chain's floor and `GatherBelowFloor` when the gather's largest slot provably
    ///             cannot clear it; such positions exit via `unwrapForTao`.
    /// @param  tokenId              ERC1155 tokenId identifying the (netuid, registrationBlock) position.
    /// @param  shares               Shares to burn.
    /// @param  userSubstrateColdkey Destination coldkey for alpha on the live path (unused on dissolved path).
    function unwrap(uint256 tokenId, uint256 shares, bytes32 userSubstrateColdkey) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender, tokenId) < shares) revert InsufficientShares();
        uint16 netuid = _netuid(tokenId);
        _requireNotDissolving(netuid);
        address clone = subnetClone[tokenId];

        if (_isIssuedForDissolvedSubnet(tokenId)) {
            _unwrapFromDissolvedSubnet(tokenId, shares, clone);
        } else {
            _unwrapFromLiveSubnet(tokenId, shares, userSubstrateColdkey, clone, netuid);
        }
    }

    /// @notice Burn vault shares pro-rata and pay the caller native TAO from selling the backing alpha.
    /// @dev    Full-balance sells go straight to the chain - full drains are exempt from its
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
        uint16 netuid = _netuid(tokenId);
        _requireNotDissolving(netuid);

        // This rail sells in place and never drains, so it reads the full union: after a rotation
        // the backing sits on validators the set no longer names, and it is the only exit left for
        // a position the alpha rail cannot deliver.
        (bytes32[] memory hotkeys, uint256[] memory balances, uint256 total) = _unionStake(tokenId, netuid, clone);
        // The dissolving window is excluded above and completed dissolution zeroes the alpha
        // balance, so a non-zero total implies a live subnet and a zero total cannot be
        // exited via this rail regardless of cause.
        if (total == 0) revert NothingToUnwrap();

        uint256 supply = totalSupply(tokenId);
        // A full burn claims the whole backing exactly: the rounded-down conversion can price it
        // a few RAO short, which would degrade the floor-exempt full drains into floored partials
        // the chain rejects - locking the last holder's sub-floor dust out of its only exit.
        uint256 assets = shares == supply ? total : _assetsFor(total, supply, shares);
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
        uint256 sold = total - _unionStakeTotal(hotkeys, _coldkeyOf(clone), netuid);
        uint256 unsold = assets - sold;
        // The chain keeps a RAO or so of every sale; refunding that to a full exit would mint a
        // sub-floor position no rail can ever sell. A partial burn keeps it - it merges into the
        // balance already held.
        if (unsold != 0 && shares == supply) {
            uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);
            if (alphaPriceE18 != 0 && _isBelowFloorAtReadPrice(unsold, alphaPriceE18)) unsold = 0;
        }

        SubnetClone(payable(clone)).unwrapTao(payable(msg.sender), taoOut);

        // The mint must follow the payout: proceeds still in the clone would be folded into the
        // claim index and promised to every holder, this caller included.
        uint256 refundShares = _sharesFor(total - assets, supply - shares, unsold);
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
        // Per-holder accruals floor against a ceiling-rounded allocation, so summed entitlements
        // can overstate the recorded liability by stray wei; a claim pays only what the liability
        // backs - anything beyond it would draw on the dissolution backing - and keeps the
        // difference recorded instead of erasing it.
        uint256 liability = taoLiability[tokenId];
        uint256 amount = entitlement > liability ? liability : entitlement;
        if (amount == 0) revert ZeroAmount();
        // A native transfer delivers only whole quantums; deduct exactly what is delivered so the
        // sub-quantum remainder stays reserved for the caller instead of drifting back to the index.
        amount -= amount % TAO_NATIVE_QUANTUM;
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
        (bytes32[] memory hotkeys, uint16[] memory weights, uint256 version) = _resolveValidators(netuid);
        bytes32 coldkey = _coldkeyOf(clone);
        // Nothing on this path trades against the pool, so one price read holds for the whole call.
        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);

        // Settling happens after delivery, so the read spans rotated-out validators too and counts
        // the whole backing wherever it currently sits.
        bytes32[] memory slots = _slotsToSettle(tokenId, hotkeys, version);
        uint256[] memory balances = _fetchBalances(slots, coldkey, netuid);
        uint256 totalAlpha = _sumBalances(balances);
        // A fully swept position cannot regain alpha, and the burn's checkpoint keeps any
        // swept-sale proceeds claimable, so the shares are retired instead of trapped.
        if (totalAlpha == 0) {
            _burn(msg.sender, tokenId, shares);
            emit Unwrapped(msg.sender, tokenId, shares, 0);
            return;
        }

        uint256 assets = _assetsFor(totalAlpha, totalSupply(tokenId), shares);
        if (assets == 0) revert ZeroAmount();

        // A sub-floor request is undeliverable on the alpha rail (the chain rejects the transfer);
        // reverting keeps delivery exact and points dust positions at unwrapForTao. A zero read
        // falls through to the chain on the delivery below.
        if (alphaPriceE18 != 0 && _isBelowFloorAtReadPrice(assets, alphaPriceE18)) {
            revert WithdrawTooSmall();
        }

        _burn(msg.sender, tokenId, shares);
        uint256 alphaOut = _deliverAndAlign(
            tokenId, clone, slots, weights, balances, coldkey, userSubstrateColdkey, assets, alphaPriceE18
        );
        _rememberSet(tokenId, hotkeys, version, slots, balances);

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
        uint16 netuid = _netuid(tokenId);
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
        // Re-read live balances so the weight re-split never moves more than a slot holds. Writing
        // them back into `balances` leaves the caller holding where the position actually ended up,
        // which is what decides whether a dropped validator can be forgotten.
        uint256[] memory postBalances = _fetchBalances(hotkeys, coldkey, netuid);
        for (uint256 i; i < balances.length;) {
            balances[i] = postBalances[i];
            unchecked {
                ++i;
            }
        }
        _drainRotatedSlots(tokenId, clone, hotkeys, balances, weights.length, coldkey, alphaPriceE18);
        _alignToWeights(tokenId, clone, hotkeys, weights, balances, alphaPriceE18);
    }

    function _unwrapFromDissolvedSubnet(uint256 tokenId, uint256 shares, address clone) private {
        uint256 backing = _unreservedCloneTao(tokenId, clone);
        if (backing == 0) revert NothingToUnwrap();

        uint256 supplyBefore = totalSupply(tokenId);
        uint256 userTao = (backing * shares) / supplyBefore;
        _burn(msg.sender, tokenId, shares);
        if (userTao > 0) SubnetClone(payable(clone)).unwrapTao(payable(msg.sender), userTao);
        emit DissolvedSubnetUnwrapped(msg.sender, tokenId, shares, userTao);
    }

    // -------------------- Rebalance -------------------------------------------

    /// @notice Rebalance vault stake for a subnet toward registry target weights.
    ///         Anyone can call this (e.g. after validator registry update).
    /// @dev    Sub-floor and zero-price moves are skipped; a rejected move bubbles the chain's error.
    ///         Reverts `SubnetInDissolutionBlackoutPeriod` while a dissolving subnet still has a
    ///         registration block, then `SubnetNotRegistered` once cleanup has removed it.
    /// @param netuid The subnet to rebalance.
    function rebalance(uint256 netuid) external nonReentrant {
        uint256 tokenId = currentTokenId(netuid);
        address clone = subnetClone[tokenId];
        if (clone == address(0)) return;

        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 nid = uint16(netuid);
        _requireNotDissolving(nid);
        (bytes32[] memory hotkeys, uint16[] memory weights, uint256 version) = _resolveValidators(nid);
        bytes32 coldkey = _coldkeyOf(clone);
        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(nid);
        _realign(tokenId, clone, hotkeys, weights, version, coldkey, alphaPriceE18);
    }

    /// @dev Drains any rotated-out validator and settles the position on the attested weights in one
    ///      pass: a dropped validator is simply a slot whose target is zero, so both are the same
    ///      move. Returns the position's total alpha.
    function _realign(
        uint256 tokenId,
        address clone,
        bytes32[] memory hotkeys,
        uint16[] memory weights,
        uint256 version,
        bytes32 coldkey,
        uint256 alphaPriceE18
    ) private returns (uint256 total) {
        bytes32[] memory slots = _slotsToSettle(tokenId, hotkeys, version);
        uint256[] memory balances = _fetchBalances(slots, coldkey, _netuid(tokenId));
        _drainRotatedSlots(tokenId, clone, slots, balances, hotkeys.length, coldkey, alphaPriceE18);
        total = _alignToWeights(tokenId, clone, slots, weights, balances, alphaPriceE18);
        _rememberSet(tokenId, hotkeys, version, slots, balances);
    }

    /// @dev Empties every dropped validator, one full-balance move each, into the least-funded
    ///      current validator.
    ///      Weight alignment cannot do this job. It moves only the smaller of a slot's surplus and
    ///      another's deficit, and a dropped validator's balance spread over the remaining set
    ///      leaves every individual deficit far below the stake floor - so the move would be
    ///      skipped and stake many times the floor would sit on a validator the set no longer
    ///      names. Moving the whole balance at once is what keeps the drain above the floor.
    ///      A balance too small to move on its own is left in place rather than reverted: the
    ///      caller keeps remembering that slot, so the alpha stays tracked and stays in the backing
    ///      until a later deposit makes it movable.
    function _drainRotatedSlots(
        uint256 tokenId,
        address clone,
        bytes32[] memory slots,
        uint256[] memory balances,
        uint256 currentCount,
        bytes32 coldkey,
        uint256 alphaPriceE18
    ) private {
        uint16 netuid = _netuid(tokenId);

        for (uint256 i = currentCount; i < slots.length;) {
            uint256 balance = balances[i];
            // Refuse only what cannot clear the floor at the highest price the rounded-down read
            // could be hiding. The pessimistic check would strand stake the chain would have moved,
            // and a zero read carries no bound at all, so it never blocks the drain.
            if (balance != 0 && !_isBelowFloorAtAnyPrice(balance, alphaPriceE18)) {
                uint256 destination;
                for (uint256 j = 1; j < currentCount;) {
                    if (balances[j] < balances[destination]) destination = j;
                    unchecked {
                        ++j;
                    }
                }
                SubnetClone(payable(clone)).moveStake(slots[i], slots[destination], netuid, balance);
                balances[destination] += balance;
                balances[i] = 0;
            } else if (balance != 0) {
                // Dust too small to move on its own. Send the richest current slot into it first so
                // the combined pile clears the floor on the way back out - which is what lets a
                // fresh deposit carry off rotated-out dust that would otherwise sit unmovable.
                uint256 richest;
                for (uint256 j = 1; j < currentCount;) {
                    if (balances[j] > balances[richest]) richest = j;
                    unchecked {
                        ++j;
                    }
                }
                uint256 donor = balances[richest];
                if (donor != 0 && !_isBelowFloorAtAnyPrice(donor, alphaPriceE18)) {
                    SubnetClone(payable(clone)).moveStake(slots[richest], slots[i], netuid, donor);
                    // The inbound hop can credit a RAO short, so the pile leaves at its live size
                    // rather than at the sum we expected it to be.
                    uint256 pile = IStaking(STAKING_PRECOMPILE).getStake(slots[i], coldkey, netuid);
                    SubnetClone(payable(clone)).moveStake(slots[i], slots[richest], netuid, pile);
                    balances[richest] = donor + balance;
                    balances[i] = 0;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev `hotkeys` may run past `weights`: entries beyond the attested set are rotated-out
    ///      validators, which target zero. Any balance a full-balance drain could not shift is
    ///      below the floor, so alignment leaves it where it is.
    function _alignToWeights(
        uint256 tokenId,
        address clone,
        bytes32[] memory hotkeys,
        uint16[] memory weights,
        uint256[] memory balances,
        uint256 alphaPriceE18
    ) private returns (uint256 total) {
        total = _sumBalances(balances);

        uint256 slotCount = balances.length;
        // One validator holding everything, with nothing rotated out, is already on target.
        if (total == 0 || slotCount == 1) return total;

        uint256 lastIndex = weights.length - 1;
        uint256[] memory targets = new uint256[](slotCount);
        {
            uint256 assigned;
            for (uint256 i; i < lastIndex;) {
                targets[i] = (total * weights[i]) / BPS_BASE;
                assigned += targets[i];
                unchecked {
                    ++i;
                }
            }
            // The last attested slot absorbs the rounding remainder. Every slot past the attested
            // set keeps its zero target, so the whole total is claimed by current validators.
            targets[lastIndex] = total - assigned;
        }

        // Each step settles at least one slot exactly at its target, and surpluses and deficits
        // cancel out, so settling all but one slot settles the last one too.
        uint256 maxRounds = slotCount - 1;
        for (uint256 round; round < maxRounds;) {
            if (!_rebalanceStep(tokenId, clone, hotkeys, balances, targets, alphaPriceE18)) break;
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
        uint256 alphaPriceE18
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
        if (alphaPriceE18 == 0 || _isBelowFloorAtReadPrice(moveAmount, alphaPriceE18)) return false;
        SubnetClone(payable(clone)).moveStake(hotkeys[overIndex], hotkeys[underIndex], _netuid(tokenId), moveAmount);
        emit Rebalanced(tokenId, hotkeys[overIndex], hotkeys[underIndex], moveAmount);
        balances[overIndex] -= moveAmount;
        balances[underIndex] += moveAmount;
        return true;
    }

    // -------------------- View Functions ----------------------------------------

    /// @notice Total alpha backing this token's shares. Returns 0 before the clone exists.
    /// @dev    While subtensor dissolution cleanup runs for the netuid the backing alpha is in
    ///         flux; treat the value as unstable whenever `isSubnetDissolving(netuid)` is true.
    /// @param  tokenId ERC1155 tokenId identifying the (netuid, registrationBlock) position.
    /// @return Alpha staked under the clone for this token.
    function totalStake(uint256 tokenId) public view returns (uint256) {
        address clone = subnetClone[tokenId];
        if (clone == address(0)) return 0;
        (,, uint256 total) = _unionStake(tokenId, _netuid(tokenId), clone);
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
        uint256 supply = totalSupply(tokenId);
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
        return _convertToShares(tokenId, assets);
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
        address clone = subnetClone[tokenId];
        if (clone == address(0)) return (0, 0);
        uint256 supply = totalSupply(tokenId);
        if (supply == 0) return (0, 0);

        uint16 netuid = _netuid(tokenId);
        _requireNotDissolving(netuid);

        if (_isIssuedForDissolvedSubnet(tokenId)) {
            uint256 backing = _unreservedCloneTao(tokenId, clone);
            if (backing == 0) revert SubnetDissolved();
            return (0, (backing * shares) / supply);
        }

        // Reverts NoValidatorFound when the registry has no set for this subnet.
        (bytes32[] memory current,, uint256 version) = _resolveValidators(netuid);

        (,, uint256 totalAlpha) = _unionStake(tokenId, netuid, clone, current, version);
        return (_assetsFor(totalAlpha, supply, shares), 0);
    }

    /// @notice TAO withdrawable by `account` for `tokenId` right now: exactly what `claimTao`
    ///         would pay, including entitlement the storage has not settled yet, quoted at the
    ///         granularity a native transfer can deliver.
    function claimableTaoOf(address account, uint256 tokenId) external view returns (uint256) {
        (uint256 indexIncrease, uint256 liabilityIncrease) = _previewSyncTao(tokenId);
        uint256 index = cumulativeTaoPerShare[tokenId] + indexIncrease;
        uint256 backing = taoLiability[tokenId] + liabilityIncrease;
        uint256 entitlement = claimableTao[tokenId][account] + _pendingAt(account, tokenId, index);
        uint256 amount = entitlement > backing ? backing : entitlement;
        return amount - amount % TAO_NATIVE_QUANTUM;
    }

    /// @notice The subnet's attested validators, 1 to 64 of them, in the order they were attested.
    function getCurrentValidators(uint256 netuid) external view returns (bytes32[] memory) {
        if (netuid > type(uint16).max) revert NetuidOutOfRange();
        // forge-lint: disable-next-line(unsafe-typecast)
        (bytes32[] memory hotkeys,,) = _resolveValidators(uint16(netuid));
        return hotkeys;
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
        bytes32 mailboxColdkey = _coldkeyOf(predicted);
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
        bytes32 mailboxColdkey = _coldkeyOf(predicted);
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

    /// @dev Reverts `NoValidatorFound` if the registry has no configured set for `netuid`.
    function _resolveValidators(uint16 netuid)
        private
        view
        returns (bytes32[] memory hotkeys, uint16[] memory weights, uint256 version)
    {
        (hotkeys, weights, version) = validatorRegistry.getValidators(netuid);
        if (hotkeys.length == 0) revert NoValidatorFound();
    }

    /// @dev Balances for `hotkeys`, positionally aligned with it. One batched precompile call
    ///      replaces one call per hotkey, and the chain omits hotkeys holding nothing from its
    ///      reply, so results are matched back by hotkey through a single forward scan - both
    ///      arrays are in the same order, which makes the scan linear rather than quadratic.
    ///      `hotkeys` must be free of duplicates: the chain rejects a repeated hotkey outright.
    function _fetchBalances(bytes32[] memory hotkeys, bytes32 coldkey, uint16 netuid)
        private
        view
        returns (uint256[] memory balances)
    {
        uint256 count = hotkeys.length;
        balances = new uint256[](count);

        // The attested set alone fits one call, but adding rotated-out validators can push the
        // union past what the chain accepts, so the read is chunked.
        for (uint256 start; start < count; start += MAX_BATCH_HOTKEYS) {
            uint256 remaining = count - start;
            uint256 size = remaining < MAX_BATCH_HOTKEYS ? remaining : MAX_BATCH_HOTKEYS;
            _readBalanceChunk(hotkeys, coldkey, netuid, start, size, balances);
        }
    }

    /// @dev Reads `size` hotkeys of `hotkeys` from `start` and writes each balance into `balances`
    ///      at the same index.
    function _readBalanceChunk(
        bytes32[] memory hotkeys,
        bytes32 coldkey,
        uint16 netuid,
        uint256 start,
        uint256 size,
        uint256[] memory balances
    ) private view {
        bytes32[] memory chunk = new bytes32[](size);
        for (uint256 i; i < size;) {
            chunk[i] = hotkeys[start + i];
            unchecked {
                ++i;
            }
        }

        IStaking.StakeInfo[] memory funded =
            IStaking(STAKING_PRECOMPILE).getStakeInfoForColdkeyAndNetuid(coldkey, netuid, chunk);

        uint256 cursor;
        for (uint256 i; i < funded.length;) {
            // Both arrays share an order, so the scan never rewinds. A reply naming a hotkey that
            // was not asked for runs the cursor off the chunk and reverts, which is the right
            // answer to a malformed read.
            while (chunk[cursor] != funded[i].hotkey) {
                unchecked {
                    ++cursor;
                }
            }
            balances[start + cursor] = funded[i].stake;
            unchecked {
                ++cursor;
                ++i;
            }
        }
    }

    function _sumBalances(uint256[] memory balances) private pure returns (uint256 total) {
        for (uint256 i; i < balances.length;) {
            total += balances[i];
            unchecked {
                ++i;
            }
        }
    }

    function _sharesFor(uint256 stake, uint256 supply, uint256 assets) private pure returns (uint256) {
        return Math.mulDiv(assets, supply + VIRTUAL_SHARES, stake + VIRTUAL_ASSETS);
    }

    function _assetsFor(uint256 stake, uint256 supply, uint256 shares) private pure returns (uint256) {
        return (shares * (stake + VIRTUAL_ASSETS)) / (supply + VIRTUAL_SHARES);
    }

    function _convertToShares(uint256 tokenId, uint256 assets) private view returns (uint256) {
        return _sharesFor(totalStake(tokenId), totalSupply(tokenId), assets);
    }

    function _coldkeyOf(address evmAddress) private view returns (bytes32) {
        return IAddressMapping(ADDRESS_MAPPING_PRECOMPILE).addressMapping(evmAddress);
    }

    function _isRotatedOut(bytes32 hotkey, bytes32[] memory currentSet) private pure returns (bool) {
        return hotkey != bytes32(0) && !_contains(currentSet, hotkey);
    }

    function _contains(bytes32[] memory set, bytes32 hotkey) private pure returns (bool) {
        for (uint256 i; i < set.length;) {
            if (set[i] == hotkey) return true;
            unchecked {
                ++i;
            }
        }
        return false;
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

    /// @dev Every slot the position may hold alpha on: the attested set, then any remembered
    ///      validator that has since been dropped. Rotated-out slots come last so their zero
    ///      targets line up past the end of the weights array.
    ///      A matching set version proves the membership has not moved since the last call, which
    ///      leaves nothing to drain and lets the whole remembered set go unread.
    function _slotsToSettle(uint256 tokenId, bytes32[] memory currentSet, uint256 version)
        private
        view
        returns (bytes32[] memory slots)
    {
        bytes32[] storage remembered = _lastSeenHotkeys[tokenId];
        uint256 rememberedCount = remembered.length;
        if (_lastSeenVersion[tokenId] == version && rememberedCount == currentSet.length) {
            return currentSet;
        }

        uint256 currentCount = currentSet.length;
        bytes32[] memory staged = new bytes32[](currentCount + rememberedCount);
        for (uint256 i; i < currentCount;) {
            staged[i] = currentSet[i];
            unchecked {
                ++i;
            }
        }

        uint256 size = currentCount;
        for (uint256 i; i < rememberedCount;) {
            bytes32 hotkey = remembered[i];
            // A hotkey can sit in the remembered set twice only if it was already dropped once and
            // re-attested, so the containment check covers both re-entry and plain duplication.
            if (_isRotatedOut(hotkey, currentSet) && !_contains(staged, hotkey)) {
                staged[size] = hotkey;
                unchecked {
                    ++size;
                }
            }
            unchecked {
                ++i;
            }
        }

        // Shrink to what was actually staged. Only the length word of an array this function
        // allocated is written, so no memory outside it is touched.
        assembly ("memory-safe") {
            mstore(staged, size)
        }
        return staged;
    }

    /// @dev Records where the position can hold alpha next time. Any dropped validator still
    ///      holding a balance the floor would not let us move stays remembered: forgetting it would
    ///      strand that alpha and drop it out of the backing the views report. The version is only
    ///      adopted once the drain is clean, so a position with leftovers keeps re-reading its
    ///      history until they clear.
    function _rememberSet(
        uint256 tokenId,
        bytes32[] memory currentSet,
        uint256 version,
        bytes32[] memory slots,
        uint256[] memory balances
    ) private {
        uint256 currentCount = currentSet.length;
        bytes32[] storage remembered = _lastSeenHotkeys[tokenId];

        uint256 kept = currentCount;
        for (uint256 i = currentCount; i < slots.length;) {
            if (balances[i] != 0) {
                unchecked {
                    ++kept;
                }
            }
            unchecked {
                ++i;
            }
        }

        while (remembered.length > kept) {
            remembered.pop();
        }
        while (remembered.length < kept) {
            remembered.push();
        }
        for (uint256 i; i < currentCount;) {
            if (remembered[i] != currentSet[i]) remembered[i] = currentSet[i];
            unchecked {
                ++i;
            }
        }
        uint256 next = currentCount;
        for (uint256 i = currentCount; i < slots.length;) {
            if (balances[i] != 0) {
                if (remembered[next] != slots[i]) remembered[next] = slots[i];
                unchecked {
                    ++next;
                }
            }
            unchecked {
                ++i;
            }
        }

        if (kept == currentCount) {
            if (_lastSeenVersion[tokenId] != version) _lastSeenVersion[tokenId] = version;
        }
    }

    function _unionStake(uint256 tokenId, uint16 netuid, address clone)
        private
        view
        returns (bytes32[] memory, uint256[] memory, uint256)
    {
        (bytes32[] memory current,, uint256 version) = validatorRegistry.getValidators(netuid);
        return _unionStake(tokenId, netuid, clone, current, version);
    }

    /// @dev Per-hotkey stake across the remembered and current validator sets, with its total. A
    ///      view has no chance to drain first, so it must count stake wherever it sits: between a
    ///      registry commit and the next vault call the whole position is on validators the set no
    ///      longer names, and reading only the current set would report no backing at all.
    function _unionStake(uint256 tokenId, uint16 netuid, address clone, bytes32[] memory current, uint256 version)
        private
        view
        returns (bytes32[] memory hotkeys, uint256[] memory balances, uint256 total)
    {
        hotkeys = _slotsToSettle(tokenId, current, version);
        balances = _fetchBalances(hotkeys, _coldkeyOf(clone), netuid);
        total = _sumBalances(balances);
    }

    /// @dev Live total across slots `_unionStake` already resolved.
    function _unionStakeTotal(bytes32[] memory hotkeys, bytes32 coldkey, uint16 netuid) private view returns (uint256) {
        return _sumBalances(_fetchBalances(hotkeys, coldkey, netuid));
    }

    /// @notice Every validator this position may still hold alpha under: the set as of its last
    ///         state-mutating call, plus any dropped validator whose balance could not be moved.
    function lastSeenHotkeys(uint256 tokenId) external view returns (bytes32[] memory) {
        return _lastSeenHotkeys[tokenId];
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

    function _netuid(uint256 tokenId) private pure returns (uint16) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(tokenId & 0xFFFF);
    }

    function _registrationBlock(uint256 tokenId) private pure returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(tokenId >> 16);
    }

    function _isIssuedForDissolvedSubnet(uint256 tokenId) private view returns (bool) {
        uint64 currentRegistrationBlock = ISubnet(SUBNET_PRECOMPILE).getNetworkRegistrationBlock(_netuid(tokenId));
        return currentRegistrationBlock == 0 || currentRegistrationBlock != _registrationBlock(tokenId);
    }

    /// @dev Subtensor dissolves a subnet asynchronously over many blocks; alpha balances and
    ///      TAO refunds are in flux for the whole window, so every share-priced path is frozen
    ///      until dissolution completes. The check is per netuid, so an already-dissolved
    ///      position is also frozen while a newer subnet on the same netuid dissolves.
    function _requireNotDissolving(uint16 netuid) private view {
        if (ISubnet(SUBNET_PRECOMPILE).isSubnetDissolving(netuid)) revert SubnetInDissolutionBlackoutPeriod();
    }

    /// @dev Shared guard for views that quote only the currently-registered subnet: the blackout
    ///      check must precede the registration-block comparison so an in-flux registration is
    ///      never classified as dissolved.
    function _requireCurrentRegistration(uint256 tokenId) private view {
        _requireNotDissolving(_netuid(tokenId));
        if (_isIssuedForDissolvedSubnet(tokenId)) revert SubnetDissolved();
    }

    // -------------------- TAO Claim Index ----------------------------------------

    /// @dev Folds TAO the clone received since the last synchronization into the per-share index.
    function _syncTao(uint256 tokenId) private {
        (uint256 indexIncrease, uint256 liabilityIncrease) = _previewSyncTao(tokenId);
        if (indexIncrease == 0) return;
        cumulativeTaoPerShare[tokenId] += indexIncrease;
        taoLiability[tokenId] += liabilityIncrease;
    }

    /// @dev The increases a synchronization would record right now. Zero while the subnet is
    ///      dissolving or dissolved: from then on new clone balance is the dissolution refund,
    ///      which the dissolved unwrap path distributes pro rata instead. Zero at zero supply:
    ///      with no holders there is no one to attribute the arrival to, so it stays unreserved
    ///      until shares exist again.
    function _previewSyncTao(uint256 tokenId) private view returns (uint256 indexIncrease, uint256 liabilityIncrease) {
        address clone = subnetClone[tokenId];
        if (clone == address(0)) return (0, 0);
        uint256 newTao = _unreservedCloneTao(tokenId, clone);
        if (newTao == 0) return (0, 0);
        if (ISubnet(SUBNET_PRECOMPILE).isSubnetDissolving(_netuid(tokenId))) return (0, 0);
        if (_isIssuedForDissolvedSubnet(tokenId)) return (0, 0);
        uint256 supply = totalSupply(tokenId);
        if (supply == 0) return (0, 0);
        indexIncrease = Math.mulDiv(newTao, TAO_INDEX_PRECISION, supply);
        // Rounded up so every index increase moves the liability: a floored-to-zero allocation
        // would leave the same arrival re-countable on every later synchronization. The product
        // never exceeds newTao times the scale, so the ceiling cannot over-reserve.
        liabilityIncrease = Math.mulDiv(indexIncrease, supply, TAO_INDEX_PRECISION, Math.Rounding.Ceil);
    }

    /// @dev The clone balance not yet promised through the claim index: assignable to the index
    ///      while the subnet is live, and the redemption backing once it is dissolved.
    function _unreservedCloneTao(uint256 tokenId, address clone) private view returns (uint256) {
        uint256 balance = clone.balance;
        // The early exit spares the liability read on the common empty-clone path.
        if (balance == 0) return 0;
        uint256 reserved = taoLiability[tokenId];
        return balance > reserved ? balance - reserved : 0;
    }

    /// @dev Banks the account's earned-but-unrecorded TAO and re-anchors its debt at `index`;
    ///      repeating it at an unchanged balance is a no-op.
    function _checkpoint(address account, uint256 tokenId, uint256 index) private {
        uint256 earned = _earnedAt(account, tokenId, index);
        uint256 debt = taoIndexDebt[tokenId][account];
        if (earned > debt) {
            claimableTao[tokenId][account] += earned - debt;
        }
        taoIndexDebt[tokenId][account] = earned;
    }

    /// @dev Earned-but-unrecorded TAO for the account at the given index level.
    function _pendingAt(address account, uint256 tokenId, uint256 index) private view returns (uint256) {
        uint256 earnedToDate = _earnedAt(account, tokenId, index);
        uint256 debt = taoIndexDebt[tokenId][account];
        return earnedToDate > debt ? earnedToDate - debt : 0;
    }

    function _settleIndexDebt(address account, uint256 tokenId, uint256 index) private {
        taoIndexDebt[tokenId][account] = _earnedAt(account, tokenId, index);
    }

    function _earnedAt(address account, uint256 tokenId, uint256 index) private view returns (uint256) {
        return Math.mulDiv(balanceOf(account, tokenId), index, TAO_INDEX_PRECISION);
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
