// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { ERC1155Supply } from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { SubnetClone } from "./SubnetClone.sol";
import { DepositMailbox } from "./DepositMailbox.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
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
///   - Each vault tracks its own sharePrice independently: totalStake[netuid] / totalShares(netuid).
///   - EIP-1167 clones serve as deterministic "Mailbox" deposit addresses per (user, netuid).
///   - Validators + weights are read exclusively from ValidatorRegistry (no on-chain fallback).
///   - Deposits and withdraws run a full rebalance (up to N-1 `moveStake`s) toward the
///     attested weights.
///   - Explicit `rebalance(netuid)` is still callable if rebalancing is desired immediately.
///   - State-mutating calls sweep alpha off hotkeys dropped from the registry since the
///     previous call. The per-token last-seen hotkey set is tracked in `_lastSeenHotkeys`.
///   - Value accrues as validator rewards increase totalStake[netuid] without minting new shares.
///   - Per-subnet clones isolate alpha and TAO returned by dissolved subnets.
contract AlphaVault is ERC1155, ERC1155Supply, Ownable, ReentrancyGuard {
    // ──────────────────── Immutables ────────────────────────────────────────────
    address public immutable mailboxLogic;
    address public immutable subnetLogic;

    // ──────────────────── State ─────────────────────────────────────────────────
    mapping(uint256 => uint256) public totalStake;
    mapping(address => bool) public cloneDeployed;
    IValidatorRegistry public validatorRegistry;
    mapping(uint256 => address) public subnetClone;

    /// @dev Hotkeys this token's clone is physically distributed across. Refreshed on every
    ///      state-mutating call after sweeping any hotkey dropped from the registry.
    mapping(uint256 => bytes32[3]) private _lastSeenHotkeys;

    /// @notice Minimum TAO-RAO value (`alpha * alpha_price`) for any single `transferStake` /
    ///         `moveStake` the vault initiates.
    uint256 public minStakeTaoFloor;

    // ──────────────────── Precision ─────────────────────────────────────────────
    /// @dev Virtual shares/assets to prevent inflation attacks (ERC4626 pattern).
    uint256 private constant VIRTUAL_SHARES = 1e9;
    uint256 private constant VIRTUAL_ASSETS = 1;
    uint16 private constant BPS_BASE = 10_000;

    // ──────────────────── Events ────────────────────────────────────────────────
    event Deposited(address indexed user, uint256 indexed tokenId, uint256 assets, uint256 shares);
    event Withdrawn(address indexed user, uint256 indexed tokenId, uint256 shares, uint256 assets);
    event ValidatorRegistryUpdated(address oldRegistry, address newRegistry);
    event MinStakeTaoFloorUpdated(uint256 oldValue, uint256 newValue);
    event Rebalanced(uint256 indexed tokenId, bytes32 indexed fromHotkey, bytes32 indexed toHotkey, uint256 amount);
    event SubnetProxyCreated(uint256 indexed tokenId, address clone);
    event WithdrawnForTao(
        address indexed user, uint256 indexed tokenId, uint256 shares, uint256 assetsBurned, uint256 taoOut
    );
    event MailboxAlphaSoldForTao(
        address indexed user, uint256 indexed netuid, bytes32 indexed hotkey, uint256 alpha, uint256 taoOut
    );

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
    error NothingToWithdraw();
    error NoSharesOutstanding();
    error DepositTooSmall();
    error WithdrawTooSmall();
    error NetuidOutOfRange();
    error ChosenHotkeyNotInSet();
    error SlippageExceeded(uint256 amountOut);

    // ──────────────────── Constructor ───────────────────────────────────────────
    constructor(string memory _uri, address _mailboxLogic, address _subnetLogic) ERC1155(_uri) Ownable(msg.sender) {
        if (_mailboxLogic == address(0) || _subnetLogic == address(0)) revert ZeroAddress();
        mailboxLogic = _mailboxLogic;
        subnetLogic = _subnetLogic;
        minStakeTaoFloor = 2e6;
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
    ///         holding stake under multiple hotkeys requires one `processDeposit` per hotkey.
    ///         `chosenHotkey` must be in the current attested validator set; reverts with
    ///         `ChosenHotkeyNotInSet` otherwise. Use `reclaimAlphaFromMailbox` to recover alpha
    ///         parked under a non-attested hotkey.
    ///         Per-slot rebalance moves whose tao-equivalent (`alpha * alpha_price`) falls below
    ///         `minStakeTaoFloor` are skipped to avoid tripping subtensor's `AmountTooLow` floor
    ///         on `moveStake`. Small deposits may therefore leave the position drifted from target
    ///         weights; the drift persists until a later deposit or withdraw produces a residual
    ///         above the floor. Calling `rebalance()` does not clear sub-floor drift since it
    ///         applies the same floor.
    function processDeposit(address user, uint256 netuid, bytes32 chosenHotkey) external nonReentrant {
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
        _sweepRotatedStake(tokenId, clone, destColdkey, hotkeys);

        uint256 totalDeposit = IStaking(STAKING_PRECOMPILE).getStake(chosenHotkey, _coldkeyOf(userClone), netuid);
        if (totalDeposit == 0) revert ZeroAmount();

        try DepositMailbox(payable(userClone)).flush(destColdkey, chosenHotkey, netuid, totalDeposit) { }
        catch (bytes memory err) {
            _requireSubFloorElseBubble(err, totalDeposit, nid);
            revert DepositTooSmall();
        }

        uint256 totalAlpha = _rebalance(tokenId, clone, hotkeys, weights, count, destColdkey);

        uint256 preStake = totalAlpha > totalDeposit ? totalAlpha - totalDeposit : 0;
        uint256 shares = _sharesFor(preStake, totalSupply(tokenId), totalDeposit);
        if (shares == 0) revert ZeroAmount();

        _mint(user, tokenId, shares, "");

        emit Deposited(user, tokenId, totalDeposit, shares);
    }

    // ──────────────────── Withdraw Flow ─────────────────────────────────────────

    /// @notice Burn shares and redeem the underlying position.
    /// @dev    Dispatches on subnet state:
    ///           - permanently dissolved (tokenId's regBlock no longer current): pays pro-rata
    ///             native TAO from the clone's refund balance. Reverts
    ///             `SubnetInDissolutionBlackoutPeriod` if subtensor cleanup is still in progress.
    ///           - live: transfers alpha to `userSubstrateColdkey` via the subnet clone, rebalances.
    ///             The live path does not pre-check the dissolved-networks queue; during pass-1
    ///             of a dissolving current registration the staking precompile itself rejects
    ///             `transferStake` with `SubnetNotExists`.
    /// @param  tokenId              ERC1155 tokenId identifying the (netuid, regBlock) position.
    /// @param  shares               Shares to burn.
    /// @param  userSubstrateColdkey Destination coldkey for alpha on the live path (unused on dissolved path).
    /// @param  minAlphaOut          Live-path slippage floor: reverts `SlippageExceeded` when a sub-floor
    ///                              remainder leaves delivery below it. Ignored on the dissolved path,
    ///                              which pays exact pro-rata TAO.
    function withdraw(uint256 tokenId, uint256 shares, bytes32 userSubstrateColdkey, uint256 minAlphaOut)
        external
        nonReentrant
    {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender, tokenId) < shares) revert InsufficientShares();
        address clone = subnetClone[tokenId];

        uint16 netuid = _netuid(tokenId);
        if (_isIssuedForDissolvedSubnet(tokenId)) {
            _redeemDissolvedPosition(tokenId, shares, clone, netuid);
        } else {
            _redeemLivePosition(tokenId, shares, userSubstrateColdkey, clone, netuid, minAlphaOut);
        }
    }

    /// @notice Burn vault shares pro-rata and pay the caller native TAO from swapping the backing alpha.
    /// @dev    Subtensor rejects a partial unstake worth less than the min-stake floor (full drains
    ///         are exempt). When the split across validators ends in such a tail, the tail is grown
    ///         to the nearest legal size and the growth shaved off an earlier full slice, keeping
    ///         the total sold exactly the burned assets. Reverts `WithdrawTooSmall` when no slice
    ///         can absorb the shave.
    /// @param  tokenId    Vault token id.
    /// @param  shares     Shares to burn.
    /// @param  minTaoOut  Slippage floor; revert if realized TAO is less.
    function withdrawForTao(uint256 tokenId, uint256 shares, uint256 minTaoOut) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender, tokenId) < shares) revert InsufficientShares();
        address clone = subnetClone[tokenId];
        if (clone == address(0)) revert NothingToWithdraw();
        uint16 netuid = _netuid(tokenId);

        (bytes32[6] memory hotkeys, uint256[6] memory balances, uint256 total) = _drainCandidates(tokenId, netuid);
        // Dissolution permanently zeroes the alpha balance, so a non-zero total already implies
        // a live subnet and a zero total cannot be exited via this rail regardless of cause.
        if (total == 0) revert NothingToWithdraw();

        totalStake[tokenId] = total;
        uint256 assets = _convertToAssets(tokenId, shares);
        if (assets == 0) revert ZeroAmount();

        _burn(msg.sender, tokenId, shares);
        totalStake[tokenId] -= assets;

        uint256 balanceBefore = clone.balance;
        (uint256[6] memory takes, uint256 tailIdx) = _planDrainSlices(balances, assets);

        // Only the tail slice can be a partial unstake, the only kind subtensor floor-checks.
        // Sell it first so the floor check runs before our own full drains move the pool price.
        uint256 tailTake = takes[tailIdx];
        if (tailTake < balances[tailIdx]) {
            try SubnetClone(payable(clone)).sellAlphaForTao(hotkeys[tailIdx], netuid, tailTake) { }
            catch (bytes memory err) {
                _requireSubFloorElseBubble(err, tailTake, netuid);
                _sellSubFloorTail(clone, hotkeys, balances, takes, tailIdx, netuid);
            }
            takes[tailIdx] = 0;
        }

        for (uint256 i; i < 6;) {
            if (takes[i] != 0) {
                SubnetClone(payable(clone)).sellAlphaForTao(hotkeys[i], netuid, takes[i]);
            }
            unchecked {
                ++i;
            }
        }

        uint256 taoOut = clone.balance - balanceBefore;
        if (taoOut < minTaoOut) revert SlippageExceeded(taoOut);

        SubnetClone(payable(clone)).withdrawTao(payable(msg.sender), taoOut);
        emit WithdrawnForTao(msg.sender, tokenId, shares, assets, taoOut);
    }

    /// @dev Split `assets` greedily across drain candidates in preference order. Every slice
    ///      except the last one touched (`tailIdx`) is a full drain; the tail is partial whenever
    ///      the split does not land exactly on a candidate's balance.
    function _planDrainSlices(uint256[6] memory balances, uint256 assets)
        private
        pure
        returns (uint256[6] memory takes, uint256 tailIdx)
    {
        uint256 remaining = assets;
        for (uint256 i; i < 6;) {
            if (remaining == 0) break;
            uint256 bal = balances[i];
            if (bal != 0) {
                takes[i] = bal < remaining ? bal : remaining;
                tailIdx = i;
                remaining -= takes[i];
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Recovery for a tail slice rejected by subtensor's partial-unstake floor: grow the
    ///      tail to the nearest legal size (its full balance, or a partial safely above the
    ///      floor) and shave the growth off an earlier full slice, so the total sold stays
    ///      exactly the burned assets. The shaved slice must itself stay above the floor; when
    ///      no slice can absorb the shave the position cannot be exited and the withdrawal
    ///      reverts.
    function _sellSubFloorTail(
        address clone,
        bytes32[6] memory hotkeys,
        uint256[6] memory balances,
        uint256[6] memory takes,
        uint256 tailIdx,
        uint16 netuid
    ) private {
        uint256 minLegalPartial = _minLegalPartialAlpha(netuid);
        uint256 tailBalance = balances[tailIdx];
        uint256 target = tailBalance < minLegalPartial ? tailBalance : minLegalPartial;
        uint256 shortfall = target - takes[tailIdx];

        for (uint256 j = tailIdx; j > 0;) {
            unchecked {
                --j;
            }
            if (takes[j] != 0 && balances[j] >= minLegalPartial + shortfall) {
                SubnetClone(payable(clone)).sellAlphaForTao(hotkeys[tailIdx], netuid, target);
                // The shaved slice turns partial; sell it before the remaining full drains so
                // its floor margin holds at the price just observed.
                SubnetClone(payable(clone)).sellAlphaForTao(hotkeys[j], netuid, takes[j] - shortfall);
                takes[j] = 0;
                return;
            }
        }
        revert WithdrawTooSmall();
    }

    function _redeemLivePosition(
        uint256 tokenId,
        uint256 shares,
        bytes32 userSubstrateColdkey,
        address clone,
        uint16 netuid,
        uint256 minAlphaOut
    ) private {
        (bytes32[3] memory hotkeys, uint16[3] memory weights, uint256 validatorCount) = _resolveValidators(netuid);
        bytes32 coldkey = _coldkeyOf(clone);
        _sweepRotatedStake(tokenId, clone, coldkey, hotkeys);

        uint256[3] memory balances = _fetchBalances(hotkeys, validatorCount, coldkey, netuid);
        uint256 totalAlpha = _sumBalances(balances);
        if (totalAlpha == 0) revert NothingToWithdraw();

        uint256 assets = _assetsFor(totalAlpha, totalSupply(tokenId), shares);
        if (assets == 0) revert ZeroAmount();
        _burn(msg.sender, tokenId, shares);

        uint256 delivered = _drainAssets(hotkeys, balances, validatorCount, clone, netuid, userSubstrateColdkey, assets);
        // Burning shares for a zero-delivery transfer would forfeit the whole position; the
        // request is non-transferable on the alpha rail, so revert and leave withdrawForTao.
        if (delivered == 0) revert WithdrawTooSmall();
        if (delivered < minAlphaOut) revert SlippageExceeded(delivered);
        _alignToWeights(tokenId, clone, hotkeys, weights, balances);

        emit Withdrawn(msg.sender, tokenId, shares, delivered);
    }

    /// @dev Drain `assets` alpha to `userColdkey` across the active validator set.
    function _drainAssets(
        bytes32[3] memory hotkeys,
        uint256[3] memory balances,
        uint256 validatorCount,
        address clone,
        uint16 netuid,
        bytes32 userColdkey,
        uint256 assets
    ) private returns (uint256 delivered) {
        uint256 remaining = assets;
        for (uint256 i; i < validatorCount && remaining > 0;) {
            if (hotkeys[i] == bytes32(0)) break;
            uint256 takeAmount = remaining > balances[i] ? balances[i] : remaining;
            if (takeAmount > 0) {
                try SubnetClone(payable(clone)).flush(userColdkey, hotkeys[i], netuid, takeAmount) {
                    balances[i] -= takeAmount;
                    remaining -= takeAmount;
                } catch (bytes memory err) {
                    _requireSubFloorElseBubble(err, takeAmount, netuid);
                }
            }
            unchecked {
                ++i;
            }
        }
        delivered = assets - remaining;
    }

    function _redeemDissolvedPosition(uint256 tokenId, uint256 shares, address clone, uint16 netuid) private {
        if (StorageQueryReader.isNetuidInDissolvedQueue(netuid)) revert SubnetInDissolutionBlackoutPeriod();
        uint256 cloneBalance = clone.balance;
        if (cloneBalance == 0) revert NothingToWithdraw();

        uint256 supplyBefore = totalSupply(tokenId);
        uint256 userTao = (cloneBalance * shares) / supplyBefore;
        _burn(msg.sender, tokenId, shares);
        if (userTao > 0) SubnetClone(payable(clone)).withdrawTao(payable(msg.sender), userTao);
        if (supplyBefore == shares) totalStake[tokenId] = 0;
        emit Withdrawn(msg.sender, tokenId, shares, userTao);
    }

    // ──────────────────── Rebalance ───────────────────────────────────────────

    /// @notice Full rebalance of vault stake for a subnet to match registry target weights.
    ///         Anyone can call this (e.g. after validator registry update).
    /// @param netuid The subnet to rebalance.
    function rebalance(uint256 netuid) external nonReentrant {
        uint256 tokenId = currentTokenId(netuid);
        address clone = subnetClone[tokenId];
        if (clone == address(0)) return;

        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 nid = uint16(netuid);
        (bytes32[3] memory hotkeys, uint16[3] memory weights, uint256 validatorCount) = _resolveValidators(nid);
        bytes32 coldkey = _coldkeyOf(clone);
        _sweepRotatedStake(tokenId, clone, coldkey, hotkeys);
        _rebalance(tokenId, clone, hotkeys, weights, validatorCount, coldkey);
    }

    function _rebalance(
        uint256 tokenId,
        address clone,
        bytes32[3] memory hotkeys,
        uint16[3] memory weights,
        uint256 validatorCount,
        bytes32 coldkey
    ) private returns (uint256) {
        uint256[3] memory balances = _fetchBalances(hotkeys, validatorCount, coldkey, _netuid(tokenId));
        return _alignToWeights(tokenId, clone, hotkeys, weights, balances);
    }

    function _alignToWeights(
        uint256 tokenId,
        address clone,
        bytes32[3] memory hotkeys,
        uint16[3] memory weights,
        uint256[3] memory balances
    ) private returns (uint256 total) {
        total = _sumBalances(balances);
        totalStake[tokenId] = total;

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
            if (!_rebalanceStep(tokenId, clone, hotkeys, balances, targets)) break;
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
        uint256[3] memory targets
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
        uint16 netuid = _netuid(tokenId);
        // moveAmt is the largest single move; if it is sub-floor every other pairing is too.
        try SubnetClone(payable(clone)).moveStake(hotkeys[overIdx], hotkeys[underIdx], netuid, moveAmt) {
            emit Rebalanced(tokenId, hotkeys[overIdx], hotkeys[underIdx], moveAmt);
            balances[overIdx] -= moveAmt;
            balances[underIdx] += moveAmt;
            return true;
        } catch (bytes memory err) {
            _requireSubFloorElseBubble(err, moveAmt, netuid);
            return false;
        }
    }

    // ──────────────────── View Functions ────────────────────────────────────────

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
        return (totalStake[tokenId] * 1e18) / supply;
    }

    /// @notice Preview how many shares would be minted for a deposit of `assets` alpha.
    /// @dev    Reverts `SubnetInDissolutionBlackoutPeriod` during the blackout and
    ///         `SubnetDissolved` for a tokenId whose subnet has been dissolved — deposits
    ///         route through `currentTokenId(netuid)` and cannot land on a stale tokenId.
    /// @param  tokenId ERC1155 tokenId identifying the (netuid, regBlock) position.
    /// @param  assets  Amount of alpha being deposited.
    /// @return Number of shares that would be minted.
    function previewDeposit(uint256 tokenId, uint256 assets) external view returns (uint256) {
        if (StorageQueryReader.isNetuidInDissolvedQueue(_netuid(tokenId))) {
            revert SubnetInDissolutionBlackoutPeriod();
        }
        if (_isIssuedForDissolvedSubnet(tokenId)) revert SubnetDissolved();
        return _convertToShares(tokenId, assets);
    }

    /// @notice Preview the redemption of `shares` for a position.
    /// @param  tokenId ERC1155 tokenId identifying the (netuid, regBlock) position.
    /// @param  shares  Shares being previewed.
    /// @return alpha   Alpha redeemable on the live path.
    /// @return tao     Native TAO redeemable on the dissolved path.
    function previewWithdraw(uint256 tokenId, uint256 shares) external view returns (uint256 alpha, uint256 tao) {
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

        (bytes32[3] memory hotkeys,, uint256 validatorCount) = _resolveValidators(netuid);
        bytes32 subnetColdkey = _coldkeyOf(clone);
        uint256 totalAlpha = _sumBalances(_fetchBalances(hotkeys, validatorCount, subnetColdkey, netuid));

        bytes32[3] memory lastSeen = _lastSeenHotkeys[tokenId];
        IStaking staking = IStaking(STAKING_PRECOMPILE);
        for (uint256 i; i < 3;) {
            bytes32 hk = lastSeen[i];
            if (_isRotatedOut(hk, hotkeys)) {
                uint256 bal = staking.getStake(hk, subnetColdkey, netuid);
                if (!_isBelowMinStake(bal, netuid)) totalAlpha += bal;
            }
            unchecked {
                ++i;
            }
        }

        return (_assetsFor(totalAlpha, supply, shares), 0);
    }

    function getBestValidator(uint256 netuid) external view returns (bytes32) {
        if (netuid > type(uint16).max) revert NetuidOutOfRange();
        // forge-lint: disable-next-line(unsafe-typecast)
        (bytes32[3] memory hks,,) = _resolveValidators(uint16(netuid));
        return hks[0];
    }

    /// @notice Unused slots are bytes32(0).
    function getBestValidators(uint256 netuid) external view returns (bytes32[3] memory) {
        if (netuid > type(uint16).max) revert NetuidOutOfRange();
        // forge-lint: disable-next-line(unsafe-typecast)
        (bytes32[3] memory hks,,) = _resolveValidators(uint16(netuid));
        return hks;
    }

    // ──────────────────── Admin ─────────────────────────────────────────────────

    function setValidatorRegistry(address _registry) external onlyOwner {
        if (_registry == address(0)) revert ZeroAddress();
        address old = address(validatorRegistry);
        validatorRegistry = IValidatorRegistry(_registry);
        emit ValidatorRegistryUpdated(old, _registry);
    }

    function setURI(string calldata newUri) external onlyOwner {
        _setURI(newUri);
    }

    function setMinStakeTaoFloor(uint256 newValue) external onlyOwner {
        uint256 old = minStakeTaoFloor;
        minStakeTaoFloor = newValue;
        emit MinStakeTaoFloorUpdated(old, newValue);
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
        DepositMailbox(payable(predicted)).withdrawTao(payable(msg.sender), amount);
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
        DepositMailbox(payable(predicted)).withdrawTao(payable(msg.sender), taoOut);
        emit MailboxAlphaSoldForTao(msg.sender, netuid, hotkey, amount, taoOut);
    }

    // ──────────────────── Internal Helpers ──────────────────────────────────────

    /// @dev Reverts `NoValidatorFound` if the registry has no configured set for `netuid`.
    function _resolveValidators(uint16 netuid)
        private
        view
        returns (bytes32[3] memory hotkeys, uint16[3] memory weights, uint256 count)
    {
        if (address(validatorRegistry) == address(0)) revert NoValidatorFound();
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
        return _sharesFor(totalStake[tokenId], totalSupply(tokenId), assets);
    }

    function _convertToAssets(uint256 tokenId, uint256 shares) private view returns (uint256) {
        return _assetsFor(totalStake[tokenId], totalSupply(tokenId), shares);
    }

    function _coldkeyOf(address evmAddr) private view returns (bytes32) {
        return IAddressMapping(ADDRESS_MAPPING_PRECOMPILE).addressMapping(evmAddr);
    }

    function _isRotatedOut(bytes32 hk, bytes32[3] memory currentSet) private pure returns (bool) {
        return hk != bytes32(0) && hk != currentSet[0] && hk != currentSet[1] && hk != currentSet[2];
    }

    // Truncated precompile price <= subtensor's full-precision price, so a real sub-floor move is
    // never misclassified as some other failure.
    function _isBelowMinStake(uint256 alpha, uint16 netuid) private view returns (bool) {
        uint256 priceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);
        return Math.mulDiv(alpha, priceE18, 1e18) < minStakeTaoFloor;
    }

    // Sized at 2x the floor so swap fees and the truncated precompile price cannot drag the
    // realized TAO output below subtensor's floor validation.
    function _minLegalPartialAlpha(uint16 netuid) private view returns (uint256) {
        uint256 priceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);
        return Math.mulDiv(2 * minStakeTaoFloor, 1e18, priceE18, Math.Rounding.Ceil);
    }

    function _requireSubFloorElseBubble(bytes memory err, uint256 alpha, uint16 netuid) private view {
        if (_isBelowMinStake(alpha, netuid)) return;
        assembly {
            revert(add(err, 0x20), mload(err))
        }
    }

    /// @dev Move stake off rotated-out hotkeys onto `currentSet[0]` and refresh the snapshot.
    function _sweepRotatedStake(uint256 tokenId, address clone, bytes32 coldkey, bytes32[3] memory currentSet) private {
        bytes32[3] storage seen = _lastSeenHotkeys[tokenId];
        if (clone != address(0)) {
            uint16 netuid = _netuid(tokenId);
            IStaking staking = IStaking(STAKING_PRECOMPILE);
            for (uint256 i; i < 3;) {
                bytes32 hk = seen[i];
                if (_isRotatedOut(hk, currentSet)) {
                    uint256 bal = staking.getStake(hk, coldkey, netuid);
                    if (bal > 0) {
                        // Sub-floor dust on a rotated-out hotkey is unrecoverable
                        try SubnetClone(payable(clone)).moveStake(hk, currentSet[0], netuid, bal) {
                            emit Rebalanced(tokenId, hk, currentSet[0], bal);
                        } catch (bytes memory err) {
                            _requireSubFloorElseBubble(err, bal, netuid);
                        }
                    }
                }
                unchecked {
                    ++i;
                }
            }
        }
        if (seen[0] != currentSet[0]) seen[0] = currentSet[0];
        if (seen[1] != currentSet[1]) seen[1] = currentSet[1];
        if (seen[2] != currentSet[2]) seen[2] = currentSet[2];
    }

    function _drainCandidates(uint256 tokenId, uint16 netuid)
        private
        view
        returns (bytes32[6] memory hotkeys, uint256[6] memory balances, uint256 totalStakeOut)
    {
        address clone = subnetClone[tokenId];
        if (clone == address(0)) return (hotkeys, balances, 0);
        if (address(validatorRegistry) == address(0)) revert NoValidatorFound();

        (bytes32[3] memory current,) = validatorRegistry.getValidators(netuid);
        bytes32[3] memory historical = _lastSeenHotkeys[tokenId];
        bytes32 coldkey = _coldkeyOf(clone);
        IStaking staking = IStaking(STAKING_PRECOMPILE);

        uint256 n;
        for (uint256 i; i < 3;) {
            bytes32 hk = historical[i];
            if (hk != bytes32(0)) {
                hotkeys[n] = hk;
                uint256 bal = staking.getStake(hk, coldkey, netuid);
                balances[n] = bal;
                totalStakeOut += bal;
                unchecked {
                    ++n;
                }
            }
            unchecked {
                ++i;
            }
        }
        // Validator registry guarantees no duplicates within the current validator set, so the dedup only
        // needs to scan against the historical slots already collected above.
        // Historical validator list was previously obtained from the validator registry contract, so it does
        // contain duplicates.
        for (uint256 i; i < 3;) {
            bytes32 hk = current[i];
            if (hk != bytes32(0) && hk != historical[0] && hk != historical[1] && hk != historical[2]) {
                hotkeys[n] = hk;
                uint256 bal = staking.getStake(hk, coldkey, netuid);
                balances[n] = bal;
                totalStakeOut += bal;
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
