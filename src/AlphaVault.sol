// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { ERC1155Supply } from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { SubnetClone } from "./SubnetClone.sol";
import { DepositMailbox } from "./DepositMailbox.sol";
import { IStaking, STAKING_PRECOMPILE } from "./interfaces/IStaking.sol";
import { IAlpha, ALPHA_PRECOMPILE } from "./interfaces/IAlpha.sol";
import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";
import { IAddressMapping, ADDRESS_MAPPING_PRECOMPILE } from "./interfaces/IAddressMapping.sol";
import { StorageQueryReader } from "./libraries/StorageQueryReader.sol";

/// @title AlphaVault
/// @notice ERC1155 multi-vault that wraps Bittensor Alpha Stake into fungible share tokens.
///         Each subnet has its own EIP-1167 clone holding alpha under an isolated coldkey.
///
/// @dev Architecture:
///   - Token ID = (netuid | subnetregistrationBlock << 16). No registration needed — vaults materialize on first deposit.
///   - Each vault tracks its own sharePrice independently: totalStake(netuid) / totalShares(netuid).
///   - EIP-1167 clones serve as deterministic "Mailbox" deposit addresses per (user, netuid).
///   - Validators + weights are read exclusively from ValidatorRegistry (no on-chain fallback).
///   - Deposits and unwraps rebalance toward the attested weights (up to N-1 pre-checked
///     `moveStake`s; sub-floor and zero-price moves are skipped).
///   - Explicit `rebalance(netuid)` is still callable if rebalancing is desired immediately.
///   - State-mutating calls consolidate alpha off hotkeys dropped from the registry by rolling the
///     whole position through them; any consolidation failure reverts the call, so stake is never
///     stranded. The last-seen validator set is tracked per token in `_lastSeenHotkeys`.
///   - Per-subnet clones isolate alpha and TAO returned by dissolved subnets.
contract AlphaVault is ERC1155, ERC1155Supply, Ownable2Step, ReentrancyGuard {
    // ──────────────────── Immutables ────────────────────────────────────────────
    address public immutable mailboxLogic;
    address public immutable subnetLogic;
    IValidatorRegistry public immutable validatorRegistry;

    // ──────────────────── State ─────────────────────────────────────────────────
    mapping(address => bool) public cloneDeployed;
    mapping(uint256 => address) public subnetClone;

    /// @dev Validators the clone's stake was distributed across at the last state-mutating call;
    ///      refreshed only after a clean consolidation.
    mapping(uint256 => bytes32[3]) private _lastSeenHotkeys;

    /// @notice Fallback Tao floor for the min-stake pre-check, used only when the chain's live
    ///         `getStakeOperationThreshold()` view is unavailable (older runtimes) or reads zero.
    ///         Owner-tunable up to STAKE_FLOOR_CAP; keep it at or above the chain's floor so the
    ///         vault never attempts doomed moves while on a runtime without the precompile.
    uint256 public minStakeTaoFloor;

    // ──────────────────── Precision ─────────────────────────────────────────────
    /// @dev Virtual shares/assets to prevent inflation attacks (ERC4626 pattern).
    uint256 private constant VIRTUAL_SHARES = 1e9;
    uint256 private constant VIRTUAL_ASSETS = 1;
    uint16 private constant BPS_BASE = 10_000;
    /// @dev Ceiling for `minStakeTaoFloor`: high enough to follow chain increases, low enough that a
    ///      misconfigured floor cannot lock real balances out of the alpha rail.
    uint256 private constant STAKE_FLOOR_CAP = 100e6;
    /// @dev The vault's floor at deployment, matching the chain's minimum at that time.
    uint256 private constant INITIAL_STAKE_FLOOR = 2e6;
    /// @dev `getAlphaPrice` rounds down to a multiple of this (e18 scale), so the true price is
    ///      always below the read plus one step. `_provablyBelowFloor` uses that as a safe bound.
    uint256 private constant ALPHA_PRICE_QUANTUM_E18 = 1e9;

    // ──────────────────── Events ────────────────────────────────────────────────
    event Deposited(address indexed user, uint256 indexed tokenId, uint256 assets, uint256 shares);
    event Unwrapped(address indexed user, uint256 indexed tokenId, uint256 shares, uint256 amountOut);
    event Rebalanced(uint256 indexed tokenId, bytes32 indexed fromHotkey, bytes32 indexed toHotkey, uint256 amount);
    event SubnetProxyCreated(uint256 indexed tokenId, address clone);
    event UnwrappedForTao(
        address indexed user, uint256 indexed tokenId, uint256 shares, uint256 assetsBurned, uint256 taoOut
    );
    event MailboxAlphaSoldForTao(
        address indexed user, uint256 indexed netuid, bytes32 indexed hotkey, uint256 alpha, uint256 taoOut
    );
    event MinStakeTaoFloorUpdated(uint256 oldValue, uint256 newValue);

    // ──────────────────── Errors ────────────────────────────────────────────────
    error ZeroAmount();
    error ZeroAddress();
    error ZeroHotkey();
    error ZeroColdkey();
    error InsufficientShares();
    error NoValidatorFound();
    error UnauthorizedCaller();
    error SubnetNotRegistered();
    error SubnetInDissolutionBlackoutPeriod();
    error SubnetDissolved();
    error NothingToUnwrap();
    error NoSharesOutstanding();
    error DepositTooSmall();
    error WithdrawTooSmall();
    error NetuidOutOfRange();
    error ChosenHotkeyNotInSet();
    error SlippageExceeded(uint256 amountOut);
    error MinStakeTaoFloorTooHigh();
    error ConsolidationBelowFloor();

    // ──────────────────── Constructor ───────────────────────────────────────────
    constructor(string memory _uri, address _mailboxLogic, address _subnetLogic, address _validatorRegistry)
        ERC1155(_uri)
        Ownable(msg.sender)
    {
        if (_mailboxLogic == address(0) || _subnetLogic == address(0) || _validatorRegistry == address(0)) {
            revert ZeroAddress();
        }
        mailboxLogic = _mailboxLogic;
        subnetLogic = _subnetLogic;
        validatorRegistry = IValidatorRegistry(_validatorRegistry);
        minStakeTaoFloor = INITIAL_STAKE_FLOOR;
    }

    // ──────────────────── Token ID & Subnet Proxy ────────────────────────────────

    /// @notice Compute the current ERC1155 tokenId for a netuid.
    /// @dev    Low 16 bits = netuid, upper bits = subnet registration block.
    ///         Reverts with `SubnetNotRegistered` if no subnet is currently registered at `netuid`.
    /// @param  netuid Subnet id.
    /// @return tokenId Packed (regBlock << 16) | netuid identifier.
    function currentTokenId(uint256 netuid) public view returns (uint256) {
        if (netuid > type(uint16).max) revert NetuidOutOfRange();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 nid = uint16(netuid);
        uint64 regBlock = StorageQueryReader.readNetworkRegisteredAt(nid);
        if (regBlock == 0) revert SubnetNotRegistered();
        return uint256(nid) | (uint256(regBlock) << 16);
    }

    /// @notice Deploy the per-subnet clone that will hold this subnet's alpha under an isolated coldkey.
    /// @dev    Idempotent: returns silently if a clone already exists for the current tokenId.
    function createSubnetProxy(uint256 netuid) external {
        uint256 tokenId = currentTokenId(netuid);
        if (subnetClone[tokenId] != address(0)) return;
        _deploySubnetClone(tokenId);
    }

    // ──────────────────── Deposit Flow ──────────────────────────────────────────

    /// @notice Predict the mailbox clone address for a user on a subnet.
    function getDepositAddress(address user, uint256 netuid) public view returns (address) {
        if (netuid > type(uint16).max) revert NetuidOutOfRange();
        bytes32 salt = _cloneSalt(user, netuid);
        return Clones.predictDeterministicAddress(mailboxLogic, salt, address(this));
    }

    /// @notice Flush the user's mailbox stake under `chosenHotkey` to the subnet clone and
    ///         rebalance the position to the attested BPS weights.
    /// @dev    Caller-restriction prevents an attacker flushing the clone before the user is ready.
    ///         The call flushes only the mailbox balance recorded under `chosenHotkey`; a mailbox
    ///         holding stake under multiple hotkeys requires one `wrap` per hotkey.
    ///         `chosenHotkey` must be in the current attested validator set; reverts with
    ///         `ChosenHotkeyNotInSet` otherwise. Use `reclaimAlphaFromMailbox` to recover alpha
    ///         parked under a non-attested hotkey.
    ///         Reverts `DepositTooSmall` when the deposit's tao value is below the chain's stake
    ///         floor at a readable price; at a zero price read the flush falls through to the chain.
    ///         The fresh deposit lands before the consolidation sweep so it seeds the roll, letting
    ///         a rotated-out dust orphan be consolidated even when it is the only other balance.
    ///         Rebalance moves below the stake floor are skipped pre-call, so small deposits may
    ///         leave the position drifted from target weights until a later deposit or unwrap
    ///         produces a movable residual.
    function wrap(address user, uint256 netuid, bytes32 chosenHotkey) external nonReentrant {
        if (msg.sender != user && msg.sender != owner()) revert UnauthorizedCaller();
        if (chosenHotkey == bytes32(0)) revert ZeroHotkey();

        uint256 tokenId = currentTokenId(netuid);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 nid = uint16(netuid);
        (bytes32[3] memory hotkeys, uint16[3] memory weights, uint256 count) = _resolveValidators(nid);

        bool inSet;
        for (uint256 i; i < count;) {
            if (hotkeys[i] == chosenHotkey) {
                inSet = true;
                break;
            }
            unchecked {
                ++i;
            }
        }
        if (!inSet) revert ChosenHotkeyNotInSet();

        address clone = subnetClone[tokenId];
        if (clone == address(0)) clone = _deploySubnetClone(tokenId);

        address userClone = _ensureMailboxClone(user, netuid);
        bytes32 destColdkey = _coldkeyOf(clone);

        uint256 totalDeposit = IStaking(STAKING_PRECOMPILE).getStake(chosenHotkey, _coldkeyOf(userClone), netuid);
        if (totalDeposit == 0) revert ZeroAmount();

        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(nid);
        if (alphaPriceE18 != 0 && _isBelowMinStakeTaoFloor(totalDeposit, alphaPriceE18)) revert DepositTooSmall();

        // Flush before the sweep: the fresh deposit seeds the roll.
        DepositMailbox(payable(userClone)).flush(destColdkey, chosenHotkey, netuid, totalDeposit);
        _sweepRotatedStake(tokenId, clone, destColdkey, hotkeys, alphaPriceE18);

        uint256 totalAlpha = _rebalance(tokenId, clone, hotkeys, weights, count, destColdkey, alphaPriceE18);

        uint256 preStake = totalAlpha > totalDeposit ? totalAlpha - totalDeposit : 0;
        uint256 shares = _sharesFor(preStake, totalSupply(tokenId), totalDeposit);
        if (shares == 0) revert ZeroAmount();

        _mint(user, tokenId, shares, "");

        emit Deposited(user, tokenId, totalDeposit, shares);
    }

    // ──────────────────── Unwrap Flow ─────────────────────────────────────────

    /// @notice Burn shares and redeem the underlying position.
    /// @dev    Dispatches on subnet state:
    ///           - permanently dissolved (tokenId's regBlock no longer current): pays pro-rata
    ///             native TAO from the clone's refund balance. Reverts
    ///             `SubnetInDissolutionBlackoutPeriod` if subtensor cleanup is still in progress.
    ///           - live: consolidates the position onto one hotkey and delivers the full pro-rata
    ///             alpha to `userSubstrateColdkey` in a single transfer (exact or reverting, never
    ///             partial), then re-splits the remainder toward the attested weights. The live path
    ///             does not pre-check the dissolved-networks queue; during pass-1 of a dissolving
    ///             current registration the staking precompile itself rejects with `SubnetNotExists`.
    ///             At a readable price, reverts `WithdrawTooSmall` when the request or the gather
    ///             seed is below the chain's floor and `ConsolidationBelowFloor` when a pending
    ///             orphan consolidation cannot clear it; such positions exit via `unwrapForTao`.
    /// @param  tokenId              ERC1155 tokenId identifying the (netuid, regBlock) position.
    /// @param  shares               Shares to burn.
    /// @param  userSubstrateColdkey Destination coldkey for alpha on the live path (unused on dissolved path).
    function unwrap(uint256 tokenId, uint256 shares, bytes32 userSubstrateColdkey) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender, tokenId) < shares) revert InsufficientShares();
        address clone = subnetClone[tokenId];

        uint16 netuid = _netuid(tokenId);
        if (_isIssuedForDissolvedSubnet(tokenId)) {
            _redeemFromDissolvedSubnet(tokenId, shares, clone, netuid);
        } else {
            _redeem(tokenId, shares, userSubstrateColdkey, clone, netuid);
        }
    }

    /// @notice Burn vault shares pro-rata and pay the caller native TAO from selling the backing alpha.
    /// @dev    Sells run bare and any sell failure bubbles; only a sub-floor partial remainder is
    ///         left unsold, so realized TAO may fall short of the burned assets by bounded dust.
    ///         `minTaoOut` guards the caller; reverts `WithdrawTooSmall` if nothing sells.
    ///         Full-balance sells read no price oracle and are exempt from the chain's amount
    ///         floor, though the chain can still refuse them when the pool cannot absorb the
    ///         sell; the vault adds no gate of its own on that path.
    /// @param  tokenId    Vault token id.
    /// @param  shares     Shares to burn.
    /// @param  minTaoOut  Slippage floor; revert if realized TAO is less.
    function unwrapForTao(uint256 tokenId, uint256 shares, uint256 minTaoOut) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender, tokenId) < shares) revert InsufficientShares();
        address clone = subnetClone[tokenId];
        if (clone == address(0)) revert NothingToUnwrap();
        uint16 netuid = _netuid(tokenId);

        (bytes32[6] memory hotkeys, uint256[6] memory balances, uint256 total) = _totalStake(tokenId, netuid);
        // Dissolution permanently zeroes the alpha balance, so a non-zero total already implies
        // a live subnet and a zero total cannot be exited via this rail regardless of cause.
        if (total == 0) revert NothingToUnwrap();

        uint256 assets = _assetsFor(total, totalSupply(tokenId), shares);
        if (assets == 0) revert ZeroAmount();

        _burn(msg.sender, tokenId, shares);

        uint256 balanceBefore = clone.balance;
        uint256 remaining = assets;
        // Full-balance sells are exempt from the chain floor and run bare. A partial remainder sells
        // only if its spot value clears the floor; a sub-floor one is skipped (minTaoOut guards the
        // shortfall). The spot check is not exact for sells - the chain floors a partial on post-fee
        // output - so a remainder just above the floor can still revert the whole exit
        // (test_RevertWhen_PartialSellBelowSimFloor). Price is re-read per slot as sells move it.
        for (uint256 i; i < 6 && remaining != 0;) {
            uint256 balance = balances[i];
            if (balance != 0) {
                if (balance <= remaining) {
                    SubnetClone(payable(clone)).sellAlphaForTao(hotkeys[i], netuid, balance);
                    remaining -= balance;
                } else {
                    uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);
                    if (alphaPriceE18 != 0 && !_isBelowMinStakeTaoFloor(remaining, alphaPriceE18)) {
                        SubnetClone(payable(clone)).sellAlphaForTao(hotkeys[i], netuid, remaining);
                        remaining = 0;
                    }
                }
            }
            unchecked {
                ++i;
            }
        }

        uint256 taoOut = clone.balance - balanceBefore;
        if (taoOut == 0) revert WithdrawTooSmall();
        if (taoOut < minTaoOut) revert SlippageExceeded(taoOut);

        SubnetClone(payable(clone)).unwrapTao(payable(msg.sender), taoOut);
        emit UnwrappedForTao(msg.sender, tokenId, shares, assets, taoOut);
    }

    function _redeem(uint256 tokenId, uint256 shares, bytes32 userSubstrateColdkey, address clone, uint16 netuid)
        private
    {
        (bytes32[3] memory hotkeys, uint16[3] memory weights, uint256 validatorCount) = _resolveValidators(netuid);
        bytes32 coldkey = _coldkeyOf(clone);
        // Nothing on this path trades against the pool, so one price read holds for the whole call.
        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);
        _sweepRotatedStake(tokenId, clone, coldkey, hotkeys, alphaPriceE18);

        // Post-sweep the whole backing sits on the current set, so its balances are the full union.
        uint256[3] memory balances = _fetchBalances(hotkeys, validatorCount, coldkey, netuid);
        uint256 totalAlpha = _sumBalances(balances);
        if (totalAlpha == 0) revert NothingToUnwrap();

        uint256 assets = _assetsFor(totalAlpha, totalSupply(tokenId), shares);
        if (assets == 0) revert ZeroAmount();

        // A sub-floor request is undeliverable on the alpha rail (the chain rejects the transfer);
        // reverting keeps delivery exact and points dust positions at unwrapForTao. A zero read
        // falls through to the chain on the delivery below.
        if (alphaPriceE18 != 0 && _isBelowMinStakeTaoFloor(assets, alphaPriceE18)) revert WithdrawTooSmall();

        _burn(msg.sender, tokenId, shares);
        _deliverAndAlign(
            tokenId, clone, hotkeys, weights, balances, validatorCount, userSubstrateColdkey, assets, alphaPriceE18
        );

        emit Unwrapped(msg.sender, tokenId, shares, assets);
    }

    /// @dev Deliver exactly `assets` to `userColdkey`, then re-split the remainder toward `weights`.
    ///      When one hotkey already covers the request it is transferred directly; otherwise the
    ///      current-set pile is gathered onto a single hotkey first and delivered in one transfer.
    ///      All moves and the transfer are bare: any rejection reverts the redemption. A gather
    ///      whose seed (the largest slot) provably cannot clear the chain's floor on its first hop
    ///      is rejected up front as `WithdrawTooSmall`.
    function _deliverAndAlign(
        uint256 tokenId,
        address clone,
        bytes32[3] memory hotkeys,
        uint16[3] memory weights,
        uint256[3] memory balances,
        uint256 validatorCount,
        bytes32 userColdkey,
        uint256 assets,
        uint256 alphaPriceE18
    ) private {
        uint16 netuid = _netuid(tokenId);
        uint256 gatherIndex;
        for (uint256 i = 1; i < validatorCount;) {
            if (balances[i] > balances[gatherIndex]) gatherIndex = i;
            unchecked {
                ++i;
            }
        }
        if (balances[gatherIndex] < assets) {
            // Hops are pile-sized and non-decreasing, so the seed (largest slot) is the binding
            // floor check: if it is provably sub-floor, reject up front instead of rolling into a
            // chain rejection that would burn the forwarded gas.
            if (_provablyBelowFloor(balances[gatherIndex], alphaPriceE18)) revert WithdrawTooSmall();
            // Rolling from the largest slot keeps every hop's amount maximal.
            for (uint256 i; i < validatorCount && balances[gatherIndex] < assets;) {
                if (i != gatherIndex && balances[i] != 0) {
                    _rollStep(tokenId, clone, netuid, hotkeys[gatherIndex], hotkeys[i], balances[gatherIndex]);
                    balances[i] += balances[gatherIndex];
                    balances[gatherIndex] = 0;
                    gatherIndex = i;
                }
                unchecked {
                    ++i;
                }
            }
        }
        SubnetClone(payable(clone)).flush(userColdkey, hotkeys[gatherIndex], netuid, assets);
        balances[gatherIndex] -= assets;
        _alignToWeights(tokenId, clone, hotkeys, weights, balances, alphaPriceE18);
    }

    function _redeemFromDissolvedSubnet(uint256 tokenId, uint256 shares, address clone, uint16 netuid) private {
        if (StorageQueryReader.isNetuidInDissolvedQueue(netuid)) revert SubnetInDissolutionBlackoutPeriod();
        uint256 cloneBalance = clone.balance;
        if (cloneBalance == 0) revert NothingToUnwrap();

        uint256 supplyBefore = totalSupply(tokenId);
        uint256 userTao = (cloneBalance * shares) / supplyBefore;
        _burn(msg.sender, tokenId, shares);
        if (userTao > 0) SubnetClone(payable(clone)).unwrapTao(payable(msg.sender), userTao);
        emit Unwrapped(msg.sender, tokenId, shares, userTao);
    }

    // ──────────────────── Rebalance ───────────────────────────────────────────

    /// @notice Rebalance vault stake for a subnet toward registry target weights.
    ///         Anyone can call this (e.g. after validator registry update).
    /// @dev    Sub-floor and zero-price moves are skipped. Reverts `ConsolidationBelowFloor` when a
    ///         pending orphan consolidation cannot clear the chain's floor; any other rejected move
    ///         bubbles the chain's error.
    /// @param netuid The subnet to rebalance.
    function rebalance(uint256 netuid) external nonReentrant {
        uint256 tokenId = currentTokenId(netuid);
        address clone = subnetClone[tokenId];
        if (clone == address(0)) return;

        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 nid = uint16(netuid);
        (bytes32[3] memory hotkeys, uint16[3] memory weights, uint256 validatorCount) = _resolveValidators(nid);
        bytes32 coldkey = _coldkeyOf(clone);
        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(nid);
        _sweepRotatedStake(tokenId, clone, coldkey, hotkeys, alphaPriceE18);
        _rebalance(tokenId, clone, hotkeys, weights, validatorCount, coldkey, alphaPriceE18);
    }

    function _rebalance(
        uint256 tokenId,
        address clone,
        bytes32[3] memory hotkeys,
        uint16[3] memory weights,
        uint256 validatorCount,
        bytes32 coldkey,
        uint256 alphaPriceE18
    ) private returns (uint256) {
        uint256[3] memory balances = _fetchBalances(hotkeys, validatorCount, coldkey, _netuid(tokenId));
        return _alignToWeights(tokenId, clone, hotkeys, weights, balances, alphaPriceE18);
    }

    function _alignToWeights(
        uint256 tokenId,
        address clone,
        bytes32[3] memory hotkeys,
        uint16[3] memory weights,
        uint256[3] memory balances,
        uint256 alphaPriceE18
    ) private returns (uint256 total) {
        total = _sumBalances(balances);

        // weights[0] != 0 is guaranteed by _resolveValidators, so weights[1] == 0 implies a
        // single-validator set: nothing to rebalance against.
        if (weights[1] == 0 || total == 0) return total;

        uint256 last = weights[2] != 0 ? 2 : 1;
        uint256[3] memory targets;
        {
            uint256 assigned;
            for (uint256 i; i < last;) {
                targets[i] = (total * weights[i]) / BPS_BASE;
                assigned += targets[i];
                unchecked {
                    ++i;
                }
            }
            targets[last] = total - assigned;
        }

        // move from overweight to underweight. Max N-1 iterations for N validators.
        for (uint256 round; round < last;) {
            if (!_rebalanceStep(tokenId, clone, hotkeys, balances, targets, alphaPriceE18)) break;
            unchecked {
                ++round;
            }
        }
    }

    function _rebalanceStep(
        uint256 tokenId,
        address clone,
        bytes32[3] memory hotkeys,
        uint256[3] memory balances,
        uint256[3] memory targets,
        uint256 alphaPriceE18
    ) private returns (bool) {
        uint256 overIdx;
        uint256 maxOver;
        uint256 underIdx;
        uint256 maxUnder;
        for (uint256 i; i < 3;) {
            if (balances[i] > targets[i]) {
                uint256 over = balances[i] - targets[i];
                if (over > maxOver) {
                    maxOver = over;
                    overIdx = i;
                }
            } else if (balances[i] < targets[i]) {
                uint256 under = targets[i] - balances[i];
                if (under > maxUnder) {
                    maxUnder = under;
                    underIdx = i;
                }
            }
            unchecked {
                ++i;
            }
        }

        if (maxOver == 0 || maxUnder == 0) return false;

        uint256 moveAmt = maxOver < maxUnder ? maxOver : maxUnder;
        // A rejected precompile call consumes all gas forwarded to it, so a doomed move must never
        // be attempted (swallowing the failure instead would burn nearly all of the tx gas). The
        // skip decision is exact, not best-effort: nothing on this path trades against the pool, so
        // the entry price holds for the whole call, and the oracle only rounds down - a move that
        // passes this check cannot be rejected as too small. Skipping (including every move at a
        // zero price read) leaves the split drifted until a later call retries it; harmless, since
        // share value depends on the total stake, not its split.
        if (alphaPriceE18 == 0 || _isBelowMinStakeTaoFloor(moveAmt, alphaPriceE18)) return false;
        SubnetClone(payable(clone)).moveStake(hotkeys[overIdx], hotkeys[underIdx], _netuid(tokenId), moveAmt);
        emit Rebalanced(tokenId, hotkeys[overIdx], hotkeys[underIdx], moveAmt);
        balances[overIdx] -= moveAmt;
        balances[underIdx] += moveAmt;
        return true;
    }

    // ──────────────────── View Functions ────────────────────────────────────────

    /// @notice Total alpha backing this token's shares. Returns 0 before the clone exists.
    /// @param  tokenId ERC1155 tokenId identifying the (netuid, regBlock) position.
    /// @return Alpha staked under the clone for this token.
    function totalStake(uint256 tokenId) public view returns (uint256) {
        if (subnetClone[tokenId] == address(0)) return 0;
        (,, uint256 total) = _totalStake(tokenId, _netuid(tokenId));
        return total;
    }

    /// @notice Price of one share in 1e18 precision, expressed in alpha.
    /// @dev    Reverts `SubnetInDissolutionBlackoutPeriod` while the netuid sits in the
    ///         dissolved-networks queue, `SubnetDissolved` once cleanup has completed or
    ///         the tokenId does not correspond to the currently-registered subnet, and
    ///         `NoSharesOutstanding` when no shares have been minted against this tokenId
    ///         (a share price with zero supply has no meaningful value).
    /// @param  tokenId ERC1155 tokenId identifying the (netuid, regBlock) position.
    /// @return Price of one share scaled by 1e18.
    function sharePrice(uint256 tokenId) external view returns (uint256) {
        if (StorageQueryReader.isNetuidInDissolvedQueue(_netuid(tokenId))) {
            revert SubnetInDissolutionBlackoutPeriod();
        }
        if (_isIssuedForDissolvedSubnet(tokenId)) revert SubnetDissolved();
        uint256 supply = totalSupply(tokenId);
        if (supply == 0) revert NoSharesOutstanding();
        return (totalStake(tokenId) * 1e18) / supply;
    }

    /// @notice Preview how many shares would be minted for a deposit of `assets` alpha.
    /// @dev    Reverts `SubnetInDissolutionBlackoutPeriod` during the blackout and
    ///         `SubnetDissolved` for a tokenId whose subnet has been dissolved — deposits
    ///         route through `currentTokenId(netuid)` and cannot land on a stale tokenId.
    /// @param  tokenId ERC1155 tokenId identifying the (netuid, regBlock) position.
    /// @param  assets  Amount of alpha being deposited.
    /// @return Number of shares that would be minted.
    function previewWrap(uint256 tokenId, uint256 assets) external view returns (uint256) {
        if (StorageQueryReader.isNetuidInDissolvedQueue(_netuid(tokenId))) {
            revert SubnetInDissolutionBlackoutPeriod();
        }
        if (_isIssuedForDissolvedSubnet(tokenId)) revert SubnetDissolved();
        return _convertToShares(tokenId, assets);
    }

    /// @notice Preview the redemption of `shares` for a position.
    /// @dev    Live-path delivery is exact: unwrap either delivers this amount in full or reverts,
    ///         so a sub-floor total is not deliverable here and must be exited via unwrapForTao.
    /// @param  tokenId ERC1155 tokenId identifying the (netuid, regBlock) position.
    /// @param  shares  Shares being previewed.
    /// @return alpha   Alpha redeemable on the live path.
    /// @return tao     Native TAO redeemable on the dissolved path.
    function previewUnwrap(uint256 tokenId, uint256 shares) external view returns (uint256 alpha, uint256 tao) {
        if (shares == 0) return (0, 0);
        address clone = subnetClone[tokenId];
        if (clone == address(0)) return (0, 0);
        uint256 supply = totalSupply(tokenId);
        if (supply == 0) return (0, 0);

        uint16 netuid = _netuid(tokenId);
        if (StorageQueryReader.isNetuidInDissolvedQueue(netuid)) revert SubnetInDissolutionBlackoutPeriod();

        if (_isIssuedForDissolvedSubnet(tokenId)) {
            uint256 cloneBalance = clone.balance;
            if (cloneBalance == 0) revert SubnetDissolved();
            return (0, (cloneBalance * shares) / supply);
        }

        // Reverts NoValidatorFound when the registry has no set for this subnet.
        (bytes32[3] memory current,,) = _resolveValidators(netuid);

        (,, uint256 totalAlpha) = _totalStake(tokenId, netuid, current);
        return (_assetsFor(totalAlpha, supply, shares), 0);
    }

    /// @notice Unused slots are bytes32(0).
    function getBestValidators(uint256 netuid) external view returns (bytes32[3] memory) {
        if (netuid > type(uint16).max) revert NetuidOutOfRange();
        // forge-lint: disable-next-line(unsafe-typecast)
        (bytes32[3] memory hks,,) = _resolveValidators(uint16(netuid));
        return hks;
    }

    // ──────────────────── Admin ─────────────────────────────────────────────────

    function setMinStakeTaoFloor(uint256 newValue) external onlyOwner {
        if (newValue > STAKE_FLOOR_CAP) revert MinStakeTaoFloorTooHigh();
        uint256 old = minStakeTaoFloor;
        minStakeTaoFloor = newValue;
        emit MinStakeTaoFloorUpdated(old, newValue);
    }

    function setURI(string calldata newUri) external onlyOwner {
        _setURI(newUri);
    }

    /// @notice Reclaim native TAO stuck in the caller's mailbox clone after subnet deregistration.
    /// @dev    Deploys the mailbox clone lazily if it was never materialized, so the TAO refund
    ///         credited directly to the deterministic address can still be swept.
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

    // ──────────────────── Internal Helpers ──────────────────────────────────────

    /// @dev Reverts `NoValidatorFound` if the registry has no configured set for `netuid`.
    function _resolveValidators(uint16 netuid)
        private
        view
        returns (bytes32[3] memory hotkeys, uint16[3] memory weights, uint256 count)
    {
        (hotkeys, weights) = validatorRegistry.getValidators(netuid);
        if (weights[0] == 0) revert NoValidatorFound();
        while (count < weights.length && weights[count] != 0) {
            count++;
        }
    }

    /// @dev Read live alpha balances per (subnet, coldkey) pair.
    function _fetchBalances(bytes32[3] memory hotkeys, uint256 count, bytes32 coldkey, uint16 netuid)
        private
        view
        returns (uint256[3] memory balances)
    {
        IStaking staking = IStaking(STAKING_PRECOMPILE);
        for (uint256 i; i < count;) {
            if (hotkeys[i] == bytes32(0)) break;
            balances[i] = staking.getStake(hotkeys[i], coldkey, netuid);
            unchecked {
                ++i;
            }
        }
    }

    function _sumBalances(uint256[3] memory balances) private pure returns (uint256) {
        return balances[0] + balances[1] + balances[2];
    }

    function _sharesFor(uint256 stake, uint256 supply, uint256 assets) private pure returns (uint256) {
        return (assets * (supply + VIRTUAL_SHARES)) / (stake + VIRTUAL_ASSETS);
    }

    function _assetsFor(uint256 stake, uint256 supply, uint256 shares) private pure returns (uint256) {
        return (shares * (stake + VIRTUAL_ASSETS)) / (supply + VIRTUAL_SHARES);
    }

    function _convertToShares(uint256 tokenId, uint256 assets) private view returns (uint256) {
        return _sharesFor(totalStake(tokenId), totalSupply(tokenId), assets);
    }

    function _coldkeyOf(address evmAddr) private view returns (bytes32) {
        return IAddressMapping(ADDRESS_MAPPING_PRECOMPILE).addressMapping(evmAddr);
    }

    function _isRotatedOut(bytes32 hk, bytes32[3] memory currentSet) private pure returns (bool) {
        return hk != bytes32(0) && hk != currentSet[0] && hk != currentSet[1] && hk != currentSet[2];
    }

    /// @notice The min-stake floor the vault currently enforces, in RAO: the chain's live
    ///         `getStakeOperationThreshold()` when the staking precompile exposes it, else the
    ///         owner-set `minStakeTaoFloor` fallback.
    function effectiveStakeFloor() external view returns (uint256) {
        return _stakeFloor();
    }

    /// @dev Chain's live min-stake threshold when readable and non-zero, else `minStakeTaoFloor`.
    ///      `getStakeOperationThreshold()` is unreleased on older runtimes; there the staticcall
    ///      reverts (ok == false) and the fallback holds, so the vault adopts the chain's own value
    ///      automatically once the precompile ships - no redeploy or owner action.
    function _stakeFloor() private view returns (uint256) {
        (bool ok, bytes memory data) =
            STAKING_PRECOMPILE.staticcall(abi.encodeWithSelector(IStaking.getStakeOperationThreshold.selector));
        if (ok && data.length == 32) {
            uint256 chainFloor = abi.decode(data, (uint256));
            if (chainFloor != 0) return chainFloor;
        }
        return minStakeTaoFloor;
    }

    /// @dev Applies to transfers, moves, and partial unstakes. Full-balance unstakes are exempt on
    ///      the chain and must never be gated by this check - they are the only exit for sub-floor positions.
    ///      The oracle quantizes at the EVM boundary, so this label can under-read within one price
    ///      quantum - up to half the true value on the lowest-priced subnets, though always under
    ///      0.004 TAO absolute; the chain itself remains the enforcer at full precision.
    ///      A zero oracle read is not a label: callers skip this check and choose their own fall-through.
    function _isBelowMinStakeTaoFloor(uint256 alphaAmount, uint256 alphaPriceE18) private view returns (bool) {
        return (alphaAmount * alphaPriceE18) / 1e18 < _stakeFloor();
    }

    /// @dev True only when `alphaAmount` cannot clear the floor even at the highest price the
    ///      rounded-down oracle read could be hiding - i.e. the chain is certain to reject it.
    ///      Amounts in the one-step uncertainty band fall through to the chain's own check. A zero
    ///      read carries no bound, so it never rejects here.
    function _provablyBelowFloor(uint256 alphaAmount, uint256 alphaPriceE18) private view returns (bool) {
        return alphaPriceE18 != 0 && _isBelowMinStakeTaoFloor(alphaAmount, alphaPriceE18 + ALPHA_PRICE_QUANTUM_E18);
    }

    /// @dev Consolidate all stake off rotated-out hotkeys, then refresh the snapshot. Any failure
    ///      reverts the call - atomicity, not tracking, is what makes the refresh safe. A pending
    ///      roll whose seed (the union's largest position) provably cannot clear the chain's floor
    ///      is rejected up front as `ConsolidationBelowFloor`; a fresh above-floor deposit re-seeds
    ///      the roll and clears it. At a zero price read the roll falls through bare, so on a
    ///      dead-priced subnet a chain-rejected roll consumes the forwarded gas.
    function _sweepRotatedStake(
        uint256 tokenId,
        address clone,
        bytes32 coldkey,
        bytes32[3] memory currentSet,
        uint256 alphaPriceE18
    ) private {
        bytes32[3] storage lastSeen = _lastSeenHotkeys[tokenId];
        if (clone != address(0) && _anyRotatedOut(lastSeen, currentSet)) {
            uint16 netuid = _netuid(tokenId);
            (bytes32 rollerHotkey, uint256 rollerBalance, uint256[3] memory lastSeenBalances) =
                _richestUnionHotkey(lastSeen, currentSet, coldkey, netuid);
            // If any rotated-out slot holds a balance, a roll will run; the seed is the largest of
            // them and every hop moves the whole pile, so clearing the floor at the seed clears it
            // for every hop.
            bool rollPending = lastSeenBalances[0] > 0 || lastSeenBalances[1] > 0 || lastSeenBalances[2] > 0;
            if (rollPending && _provablyBelowFloor(rollerBalance, alphaPriceE18)) {
                revert ConsolidationBelowFloor();
            }
            // The seed's balance is already in the pile; its cached slot is stale once the pile
            // departs, so the roll must never revisit it.
            bytes32 seedHotkey = rollerHotkey;
            for (uint256 i; i < 3;) {
                bytes32 rotatedOut = lastSeen[i];
                if (
                    rotatedOut != rollerHotkey && rotatedOut != seedHotkey && _isRotatedOut(rotatedOut, currentSet)
                        && lastSeenBalances[i] > 0
                ) {
                    _rollStep(tokenId, clone, netuid, rollerHotkey, rotatedOut, rollerBalance);
                    rollerHotkey = rotatedOut;
                    rollerBalance += lastSeenBalances[i];
                }
                unchecked {
                    ++i;
                }
            }
            if (_isRotatedOut(rollerHotkey, currentSet)) {
                _rollStep(tokenId, clone, netuid, rollerHotkey, currentSet[0], rollerBalance);
            }
        }
        if (lastSeen[0] != currentSet[0]) lastSeen[0] = currentSet[0];
        if (lastSeen[1] != currentSet[1]) lastSeen[1] = currentSet[1];
        if (lastSeen[2] != currentSet[2]) lastSeen[2] = currentSet[2];
    }

    function _anyRotatedOut(bytes32[3] storage lastSeen, bytes32[3] memory currentSet) private view returns (bool) {
        return _isRotatedOut(lastSeen[0], currentSet) || _isRotatedOut(lastSeen[1], currentSet)
            || _isRotatedOut(lastSeen[2], currentSet);
    }

    /// @dev Also returns the rotated-out slots' balances so the roll loop reuses this scan's reads.
    function _richestUnionHotkey(
        bytes32[3] storage lastSeen,
        bytes32[3] memory currentSet,
        bytes32 coldkey,
        uint16 netuid
    ) private view returns (bytes32 richest, uint256 richestBalance, uint256[3] memory lastSeenBalances) {
        richest = currentSet[0];
        for (uint256 i; i < 6;) {
            bytes32 candidateHotkey = i < 3 ? currentSet[i] : lastSeen[i - 3];
            bool eligible = i < 3 ? candidateHotkey != bytes32(0) : _isRotatedOut(candidateHotkey, currentSet);
            if (eligible) {
                uint256 candidateBalance = IStaking(STAKING_PRECOMPILE).getStake(candidateHotkey, coldkey, netuid);
                if (i >= 3) lastSeenBalances[i - 3] = candidateBalance;
                if (candidateBalance > richestBalance) {
                    richest = candidateHotkey;
                    richestBalance = candidateBalance;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Move the running pile from `from` to `to` and log it. Hops are pile-sized and
    ///      non-decreasing, so the seed is the binding floor check: callers verify the seed clears
    ///      the floor up front, or accept the chain's rejection when the price reads 0.
    function _rollStep(uint256 tokenId, address clone, uint16 netuid, bytes32 from, bytes32 to, uint256 amount)
        private
    {
        SubnetClone(payable(clone)).moveStake(from, to, netuid, amount);
        emit Rebalanced(tokenId, from, to, amount);
    }

    function _totalStake(uint256 tokenId, uint16 netuid)
        private
        view
        returns (bytes32[6] memory, uint256[6] memory, uint256)
    {
        (bytes32[3] memory current,) = validatorRegistry.getValidators(netuid);
        return _totalStake(tokenId, netuid, current);
    }

    function _totalStake(uint256 tokenId, uint16 netuid, bytes32[3] memory current)
        private
        view
        returns (bytes32[6] memory hotkeys, uint256[6] memory balances, uint256 total)
    {
        address clone = subnetClone[tokenId];
        bytes32[3] memory lastSeen = _lastSeenHotkeys[tokenId];
        bytes32 coldkey = _coldkeyOf(clone);
        IStaking staking = IStaking(STAKING_PRECOMPILE);

        uint256 n;
        for (uint256 i; i < 3;) {
            bytes32 hk = lastSeen[i];
            if (hk != bytes32(0)) {
                hotkeys[n] = hk;
                uint256 bal = staking.getStake(hk, coldkey, netuid);
                balances[n] = bal;
                total += bal;
                unchecked {
                    ++n;
                }
            }
            unchecked {
                ++i;
            }
        }
        // Both lists are individually duplicate-free: the registry rejects duplicate hotkeys within a
        // validator set, and the last-seen snapshot is a past copy of such a set. So only the
        // current-vs-last-seen overlap needs removing, which the guard below does.
        for (uint256 i; i < 3;) {
            bytes32 hk = current[i];
            if (hk != bytes32(0) && hk != lastSeen[0] && hk != lastSeen[1] && hk != lastSeen[2]) {
                hotkeys[n] = hk;
                uint256 bal = staking.getStake(hk, coldkey, netuid);
                balances[n] = bal;
                total += bal;
                unchecked {
                    ++n;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function lastSeenHotkeys(uint256 tokenId) external view returns (bytes32[3] memory) {
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

    /// @dev Salt = keccak256(user, netuid) — unique per (user, subnet) pair.
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

    function _regBlock(uint256 tokenId) private pure returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(tokenId >> 16);
    }

    function _isIssuedForDissolvedSubnet(uint256 tokenId) private view returns (bool) {
        uint64 currentRegBlock = StorageQueryReader.readNetworkRegisteredAt(_netuid(tokenId));
        return currentRegBlock == 0 || currentRegBlock != _regBlock(tokenId);
    }

    // ──────────────────── Overrides ─────────────────────────────────────────────

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override(ERC1155, ERC1155Supply)
    {
        super._update(from, to, ids, values);
    }
}
