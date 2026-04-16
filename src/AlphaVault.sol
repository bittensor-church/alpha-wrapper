// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { ERC1155Supply } from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { SubnetClone } from "./SubnetClone.sol";
import { DepositMailbox } from "./DepositMailbox.sol";
import { IStaking, STAKING_PRECOMPILE } from "./interfaces/IStaking.sol";
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
///   - Rebalances to target weights on every deposit and withdraw.
///   - Value accrues as validator rewards increase totalStake[netuid] without minting new shares.
///   - Per-subnet clones isolate alpha and TAO.
///   - Dissolved subnets pay TAO on withdraw.
///
///   Coldkey note:
///     The staking precompile uses substrate account IDs (blake2b("evm:" + h160)) as coldkeys,
///     NOT zero-padded H160 addresses. The vault's own substrate coldkey is set at deploy time.
///     Clone and user substrate coldkeys are passed as parameters by the caller.
contract AlphaVault is ERC1155, ERC1155Supply, Ownable, ReentrancyGuard {
    // ──────────────────── Immutables ────────────────────────────────────────────
    address public immutable mailboxLogic;
    address public immutable subnetLogic;

    // ──────────────────── State ─────────────────────────────────────────────────
    mapping(uint256 => uint256) public totalStake;
    mapping(address => bool) public cloneDeployed;
    IValidatorRegistry public validatorRegistry;
    mapping(uint256 => address) public subnetClone;

    // ──────────────────── Precision ─────────────────────────────────────────────
    /// @dev Virtual shares/assets to prevent inflation attacks (ERC4626 pattern).
    uint256 private constant VIRTUAL_SHARES = 1e9;
    uint256 private constant VIRTUAL_ASSETS = 1;
    uint16 private constant BPS_BASE = 10_000;

    // ──────────────────── Events ────────────────────────────────────────────────
    event Deposited(address indexed user, uint256 indexed tokenId, uint256 assets, uint256 shares, bytes32 hotkey);
    event Withdrawn(address indexed user, uint256 indexed tokenId, uint256 shares, uint256 assets, bytes32 hotkey);
    event ValidatorRegistryUpdated(address oldRegistry, address newRegistry);
    event Rebalanced(uint256 indexed tokenId, uint8 moveCount);
    event SubnetProxyCreated(uint256 indexed tokenId, address clone);

    // ──────────────────── Errors ────────────────────────────────────────────────
    error ZeroAmount();
    error ZeroAddress();
    error InsufficientShares();
    error NoValidatorFound();
    error UnauthorizedCaller();
    error SubnetNotRegistered();
    error SubnetInDissolutionBlackoutPeriod();
    error SubnetDissolved();
    error NothingToWithdraw();
    error NoSharesOutstanding();

    // ──────────────────── Constructor ───────────────────────────────────────────
    constructor(string memory _uri, address _mailboxLogic, address _subnetLogic) ERC1155(_uri) Ownable(msg.sender) {
        if (_mailboxLogic == address(0) || _subnetLogic == address(0)) revert ZeroAddress();
        mailboxLogic = _mailboxLogic;
        subnetLogic = _subnetLogic;
    }

    // ──────────────────── Token ID & Subnet Proxy ────────────────────────────────

    /// @notice Compute the current ERC1155 tokenId for a netuid.
    /// @dev    Low 16 bits = netuid, upper bits = subnet registration block.
    ///         Reverts with `SubnetNotRegistered` if no subnet is currently registered at `netuid`.
    /// @param  netuid Subnet id.
    /// @return tokenId Packed (regBlock << 16) | netuid identifier.
    function currentTokenId(uint256 netuid) public view returns (uint256) {
        uint64 regBlock = StorageQueryReader.readNetworkRegisteredAt(uint16(netuid));
        if (regBlock == 0) revert SubnetNotRegistered();
        return uint256(uint16(netuid)) | (uint256(regBlock) << 16);
    }

    /// @notice Deploy the per-subnet clone that will hold this subnet's alpha under an isolated coldkey.
    /// @dev    Idempotent: returns silently if a clone already exists for the current tokenId.
    ///         Reverts with `SubnetNotRegistered` if no subnet is currently registered at `netuid`.
    /// @param  netuid Subnet id to create the clone for.
    function createSubnetProxy(uint256 netuid) external nonReentrant {
        uint256 tokenId = currentTokenId(netuid);
        if (subnetClone[tokenId] != address(0)) return;
        _deploySubnetClone(tokenId);
    }

    // ──────────────────── Deposit Flow ──────────────────────────────────────────

    /// @notice Predict the mailbox clone address for a user on a subnet.
    function getDepositAddress(address user, uint256 netuid) public view returns (address) {
        bytes32 salt = _cloneSalt(user, netuid);
        return Clones.predictDeterministicAddress(mailboxLogic, salt, address(this));
    }

    /// @notice Process a deposit: deploy clone (lazily), flush its alpha stake, mint shares.
    ///         Only the user themselves or the contract owner can trigger this to prevent
    ///         front-running attacks where an attacker flushes the clone before the user is ready.
    function processDeposit(address user, uint256 netuid, bytes32 cloneSubstrateColdkey) external nonReentrant {
        if (msg.sender != user && msg.sender != owner()) revert UnauthorizedCaller();

        uint256 tokenId = currentTokenId(netuid);
        if (subnetClone[tokenId] == address(0)) _deploySubnetClone(tokenId);

        (bytes32[3] memory hotkeys,, uint8 count) = _resolveValidators(uint16(netuid));
        address userClone = _ensureMailboxClone(user, netuid);

        IStaking staking = IStaking(STAKING_PRECOMPILE);
        bytes32 destColdkey = _subnetColdkey(tokenId);
        uint256 totalDeposit = 0;

        for (uint8 i = 0; i < count; i++) {
            uint256 stakeUnderHk = staking.getStake(hotkeys[i], cloneSubstrateColdkey, netuid);
            if (stakeUnderHk > 0) {
                DepositMailbox(payable(userClone)).flush(destColdkey, hotkeys[i], netuid, stakeUnderHk);
                totalDeposit += stakeUnderHk;
            }
        }
        if (totalDeposit == 0) revert ZeroAmount();

        (, uint256 totalAlpha) = _fetchBalances(hotkeys, count, destColdkey, uint16(netuid));
        if (count >= 2 && totalAlpha > 0) {
            _rebalanceOnce(hotkeys, count, tokenId);
        }

        // Guard against rebalance rounding: moveStake on the real chain can lose 1 RAO,
        // so totalAlpha may be < totalDeposit when preStake is 0.
        uint256 preStake = totalAlpha > totalDeposit ? totalAlpha - totalDeposit : 0;
        uint256 shares = _sharesFor(preStake, totalSupply(tokenId), totalDeposit);
        if (shares == 0) revert ZeroAmount();

        totalStake[tokenId] = totalAlpha;
        _mint(user, tokenId, shares, "");

        emit Deposited(user, tokenId, totalDeposit, shares, hotkeys[0]);
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
    function withdraw(uint256 tokenId, uint256 shares, bytes32 userSubstrateColdkey) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender, tokenId) < shares) revert InsufficientShares();
        address clone = subnetClone[tokenId];

        uint16 netuid = _netuid(tokenId);
        if (_isIssuedForDissolvedSubnet(tokenId)) {
            _redeemDissolvedPosition(tokenId, shares, clone, netuid);
        } else {
            _redeemLivePosition(tokenId, shares, userSubstrateColdkey, clone, netuid);
        }
    }

    function _redeemLivePosition(
        uint256 tokenId,
        uint256 shares,
        bytes32 userSubstrateColdkey,
        address clone,
        uint16 netuid
    ) private {
        (bytes32[3] memory hotkeys,, uint8 validatorCount) = _resolveValidators(netuid);
        bytes32 subnetColdkey = _subnetColdkey(tokenId);
        (uint256[3] memory balances, uint256 totalAlpha) =
            _fetchBalances(hotkeys, validatorCount, subnetColdkey, netuid);
        if (totalAlpha == 0) revert NothingToWithdraw();

        uint256 assets = _convertToAssets(tokenId, shares);
        if (assets == 0) revert ZeroAmount();

        _burn(msg.sender, tokenId, shares);
        totalStake[tokenId] -= assets;

        uint8[3] memory drainOrder = _sortHotkeysByBalanceDesc(balances, validatorCount);
        uint256 remaining = assets;
        for (uint8 i = 0; i < validatorCount && remaining > 0; i++) {
            uint8 idx = drainOrder[i];
            uint256 takeAmount = remaining > balances[idx] ? balances[idx] : remaining;
            if (takeAmount > 0) {
                SubnetClone(payable(clone)).flush(userSubstrateColdkey, hotkeys[idx], netuid, takeAmount);
                remaining -= takeAmount;
            }
        }

        if (validatorCount >= 2) {
            _rebalanceOnce(hotkeys, validatorCount, tokenId);
        }

        emit Withdrawn(msg.sender, tokenId, shares, assets, hotkeys[0]);
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
        emit Withdrawn(msg.sender, tokenId, shares, userTao, bytes32(0));
    }

    function _sortHotkeysByBalanceDesc(uint256[3] memory balances, uint8 count)
        private
        pure
        returns (uint8[3] memory order)
    {
        for (uint8 i = 0; i < count; i++) {
            order[i] = i;
        }
        for (uint8 i = 0; i < count; i++) {
            for (uint8 j = i + 1; j < count; j++) {
                if (balances[order[j]] > balances[order[i]]) {
                    uint8 tmp = order[i];
                    order[i] = order[j];
                    order[j] = tmp;
                }
            }
        }
    }

    // ──────────────────── Rebalance ───────────────────────────────────────────

    /// @notice Full rebalance of vault stake for a subnet to match registry target weights.
    ///         Anyone can call this (e.g. after validator registry update).
    ///         Performs up to N-1 moveStake calls to align with target weights.
    /// @param netuid The subnet to rebalance.
    function rebalance(uint256 netuid) external nonReentrant {
        uint256 tokenId = currentTokenId(netuid);
        address clone = subnetClone[tokenId];
        if (clone == address(0)) return;

        (bytes32[3] memory hotkeys, uint16[3] memory weights, uint8 validatorCount) = _resolveValidators(uint16(netuid));

        if (validatorCount < 2) return;

        IStaking staking = IStaking(STAKING_PRECOMPILE);
        bytes32 coldkey = _subnetColdkey(tokenId);

        uint256[3] memory balances;
        uint256 total = 0;
        for (uint8 i = 0; i < validatorCount; i++) {
            balances[i] = staking.getStake(hotkeys[i], coldkey, netuid);
            total += balances[i];
        }
        if (total == 0) return;

        // Compute target amounts from weights
        uint256[3] memory targets;
        uint256 assigned = 0;
        for (uint8 i = 0; i < validatorCount; i++) {
            if (i == validatorCount - 1) {
                targets[i] = total - assigned; // remainder to last to avoid rounding dust
            } else {
                targets[i] = (total * weights[i]) / BPS_BASE;
                assigned += targets[i];
            }
        }

        // Iterative rebalance: move from overweight to underweight
        // Max N-1 iterations for N validators
        uint8 moveCount = 0;
        for (uint8 round = 0; round < validatorCount - 1; round++) {
            // Find most overweight
            uint8 overIdx = 0;
            uint256 maxOver = 0;
            for (uint8 i = 0; i < validatorCount; i++) {
                if (balances[i] > targets[i] && balances[i] - targets[i] > maxOver) {
                    maxOver = balances[i] - targets[i];
                    overIdx = i;
                }
            }

            // Find most underweight
            uint8 underIdx = 0;
            uint256 maxUnder = 0;
            for (uint8 i = 0; i < validatorCount; i++) {
                if (balances[i] < targets[i] && targets[i] - balances[i] > maxUnder) {
                    maxUnder = targets[i] - balances[i];
                    underIdx = i;
                }
            }

            if (maxOver == 0 || maxUnder == 0 || overIdx == underIdx) break;

            uint256 moveAmt = maxOver < maxUnder ? maxOver : maxUnder;
            SubnetClone(payable(clone)).moveStake(hotkeys[overIdx], hotkeys[underIdx], netuid, moveAmt);
            balances[overIdx] -= moveAmt;
            balances[underIdx] += moveAmt;
            moveCount++;
        }

        emit Rebalanced(tokenId, moveCount);
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
    /// @dev    Returns input-edge sentinels `(0, 0)` for zero shares, unknown tokenId, or
    ///         zero supply. Mirrors `withdraw` otherwise — reverts
    ///         `SubnetInDissolutionBlackoutPeriod` during blackout and `NothingToWithdraw`
    ///         on paths that would have nothing to pay out.
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
            if (cloneBalance == 0) revert NothingToWithdraw();
            return (0, (cloneBalance * shares) / supply);
        }

        (bytes32[3] memory hotkeys,, uint8 validatorCount) = _resolveValidators(netuid);
        bytes32 subnetColdkey = _subnetColdkey(tokenId);
        (, uint256 totalAlpha) = _fetchBalances(hotkeys, validatorCount, subnetColdkey, netuid);
        if (totalAlpha == 0) revert NothingToWithdraw();
        return (_convertToAssets(tokenId, shares), 0);
    }

    function getBestValidator(uint256 netuid) external view returns (bytes32) {
        (bytes32[3] memory hks,,) = _resolveValidators(uint16(netuid));
        return hks[0];
    }

    /// @notice Unused slots are bytes32(0).
    function getBestValidators(uint256 netuid) external view returns (bytes32[3] memory) {
        (bytes32[3] memory hks,,) = _resolveValidators(uint16(netuid));
        return hks;
    }

    // ──────────────────── Admin ─────────────────────────────────────────────────

    function setValidatorRegistry(address _registry) external onlyOwner {
        address old = address(validatorRegistry);
        validatorRegistry = IValidatorRegistry(_registry);
        emit ValidatorRegistryUpdated(old, _registry);
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
        DepositMailbox(payable(predicted)).withdrawTao(payable(msg.sender), amount);
    }

    // ──────────────────── Internal Helpers ──────────────────────────────────────

    /// @dev Resolve validators and weights from the registry. Reverts if none configured.
    function _resolveValidators(uint16 netuid)
        internal
        view
        returns (bytes32[3] memory hotkeys, uint16[3] memory weights, uint8 count)
    {
        if (address(validatorRegistry) == address(0)) revert NoValidatorFound();
        (hotkeys, weights, count) = validatorRegistry.getValidators(netuid);
        if (count == 0) revert NoValidatorFound();
    }

    /// @dev Read live alpha balances per (subnet, coldkey) pair.
    function _fetchBalances(bytes32[3] memory hotkeys, uint8 count, bytes32 coldkey, uint16 netuid)
        private
        view
        returns (uint256[3] memory balances, uint256 total)
    {
        IStaking staking = IStaking(STAKING_PRECOMPILE);
        for (uint8 i = 0; i < count; i++) {
            balances[i] = staking.getStake(hotkeys[i], coldkey, netuid);
            total += balances[i];
        }
    }

    /// @dev At-most-one moveStake to pull the subnet clone's balances toward target
    ///      weights. Self-contained: re-reads balances and weights from chain.
    ///      Callers must guarantee `validatorCount >= 2` and a deployed subnet clone.
    function _rebalanceOnce(bytes32[3] memory hotkeys, uint8 validatorCount, uint256 tokenId) internal {
        address clone = subnetClone[tokenId];
        uint16 netuid = _netuid(tokenId);
        bytes32 coldkey = _subnetColdkey(tokenId);

        IStaking staking = IStaking(STAKING_PRECOMPILE);
        uint256[3] memory balances;
        uint256 total = 0;
        for (uint8 i = 0; i < validatorCount; i++) {
            balances[i] = staking.getStake(hotkeys[i], coldkey, netuid);
            total += balances[i];
        }
        if (total == 0) return;

        (, uint16[3] memory weights,) = _resolveValidators(netuid);

        // Distribute `total` across validators proportionally to `weights`;
        // remainder to last slot so sum(targets) == total exactly.
        uint256[3] memory targets;
        uint256 assigned = 0;
        for (uint8 i = 0; i < validatorCount; i++) {
            if (i == validatorCount - 1) {
                targets[i] = total - assigned;
            } else {
                targets[i] = (total * weights[i]) / BPS_BASE;
                assigned += targets[i];
            }
        }

        // Pick the biggest over/under pair and move min(over, under) between them.
        uint8 overIdx = 0;
        uint8 underIdx = 0;
        uint256 maxOver = 0;
        uint256 maxUnder = 0;
        for (uint8 i = 0; i < validatorCount; i++) {
            if (balances[i] > targets[i] && balances[i] - targets[i] > maxOver) {
                maxOver = balances[i] - targets[i];
                overIdx = i;
            }
            if (balances[i] < targets[i] && targets[i] - balances[i] > maxUnder) {
                maxUnder = targets[i] - balances[i];
                underIdx = i;
            }
        }
        if (maxOver == 0 || maxUnder == 0 || overIdx == underIdx) return;

        uint256 moveAmt = maxOver < maxUnder ? maxOver : maxUnder;
        SubnetClone(payable(clone)).moveStake(hotkeys[overIdx], hotkeys[underIdx], netuid, moveAmt);
    }

    function _sharesFor(uint256 stake, uint256 supply, uint256 assets) private pure returns (uint256) {
        return (assets * (supply + VIRTUAL_SHARES)) / (stake + VIRTUAL_ASSETS);
    }

    function _assetsFor(uint256 stake, uint256 supply, uint256 shares) private pure returns (uint256) {
        return (shares * (stake + VIRTUAL_ASSETS)) / (supply + VIRTUAL_SHARES);
    }

    function _convertToShares(uint256 tokenId, uint256 assets) internal view returns (uint256) {
        return _sharesFor(totalStake[tokenId], totalSupply(tokenId), assets);
    }

    function _convertToAssets(uint256 tokenId, uint256 shares) internal view returns (uint256) {
        return _assetsFor(totalStake[tokenId], totalSupply(tokenId), shares);
    }

    function _subnetColdkey(uint256 tokenId) private view returns (bytes32) {
        return IAddressMapping(ADDRESS_MAPPING_PRECOMPILE).addressMapping(subnetClone[tokenId]);
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
    function _cloneSalt(address user, uint256 netuid) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(user, netuid));
    }

    function _deploySubnetClone(uint256 tokenId) private returns (address clone) {
        clone = Clones.clone(subnetLogic);
        SubnetClone(payable(clone)).initialize(address(this));
        subnetClone[tokenId] = clone;
        emit SubnetProxyCreated(tokenId, clone);
    }

    function _netuid(uint256 tokenId) private pure returns (uint16) {
        return uint16(tokenId & 0xFFFF);
    }

    function _regBlock(uint256 tokenId) private pure returns (uint64) {
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
