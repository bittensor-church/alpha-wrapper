// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { ERC1155Supply } from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { DepositForwarderLogic } from "./DepositForwarderLogic.sol";
import { IStaking, STAKING_PRECOMPILE } from "./interfaces/IStaking.sol";
import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";

/// @title AlphaVault
/// @notice ERC1155 multi-vault that wraps Bittensor Alpha Stake into fungible share tokens.
///         Each token ID = subnet netuid. Vaults are created automatically on first deposit.
///         Validators MUST be set externally via ValidatorRegistry — reverts if not configured.
///
/// @dev Architecture:
///   - Token ID = netuid. No registration needed — vaults materialize on first deposit.
///   - Each vault tracks its own sharePrice independently: totalStake[netuid] / totalShares(netuid).
///   - EIP-1167 clones serve as deterministic "Mailbox" deposit addresses per (user, netuid).
///   - Validators + weights are read exclusively from ValidatorRegistry (no on-chain fallback).
///   - Rebalances to target weights on every deposit and withdraw.
///   - Value accrues as validator rewards increase totalStake[netuid] without minting new shares.
///
///   Coldkey note:
///     The staking precompile uses substrate account IDs (blake2b("evm:" + h160)) as coldkeys,
///     NOT zero-padded H160 addresses. The vault's own substrate coldkey is set at deploy time.
///     Clone and user substrate coldkeys are passed as parameters by the caller.
contract AlphaVault is ERC1155, ERC1155Supply, Ownable, ReentrancyGuard {
    // ──────────────────── Immutables ────────────────────────────────────────────
    /// @notice The deployed DepositForwarderLogic implementation (singleton).
    address public immutable forwarderLogic;

    // ──────────────────── State ─────────────────────────────────────────────────
    /// @notice Total underlying stake (assets) per netuid.
    mapping(uint256 => uint256) public totalStake;

    /// @notice Tracks which clone addresses have been deployed.
    mapping(address => bool) public cloneDeployed;

    /// @notice The vault contract's substrate account ID (blake2b("evm:" + vault_h160)).
    ///         Set once at deploy time. Used as destination_coldkey in transferStake.
    bytes32 public vaultSubstrateColdkey;

    /// @notice External registry for preferred validators per subnet with target weights.
    ///         If set, validators + weights are read from here for staking and rebalancing.
    IValidatorRegistry public validatorRegistry;

    // ──────────────────── Precision ─────────────────────────────────────────────
    /// @dev Virtual shares/assets to prevent inflation attacks (ERC4626 pattern).
    uint256 private constant VIRTUAL_SHARES = 1e9;
    uint256 private constant VIRTUAL_ASSETS = 1;
    uint16 private constant BPS_BASE = 10_000;

    // ──────────────────── Events ────────────────────────────────────────────────
    event Deposited(address indexed user, uint256 indexed netuid, uint256 assets, uint256 shares, bytes32 hotkey);
    event Withdrawn(address indexed user, uint256 indexed netuid, uint256 shares, uint256 assets, bytes32 hotkey);
    event RewardsInjected(uint256 indexed netuid, uint256 amount);
    event ValidatorRegistryUpdated(address oldRegistry, address newRegistry);
    event Rebalanced(uint256 indexed netuid, uint8 moveCount);

    // ──────────────────── Errors ────────────────────────────────────────────────
    error ZeroAmount();
    error InsufficientShares();
    error ZeroColdkey();
    error NoValidatorFound();
    error UnauthorizedCaller();

    // ──────────────────── Constructor ───────────────────────────────────────────
    constructor(string memory _uri, address _forwarderLogic, bytes32 _vaultSubstrateColdkey)
        ERC1155(_uri)
        Ownable(msg.sender)
    {
        if (_vaultSubstrateColdkey == bytes32(0)) revert ZeroColdkey();
        forwarderLogic = _forwarderLogic;
        vaultSubstrateColdkey = _vaultSubstrateColdkey;
    }

    // ──────────────────── Deposit Flow ──────────────────────────────────────────

    /// @notice Compute the deterministic clone ("Mailbox") address for a (user, netuid) pair.
    function getDepositAddress(address user, uint256 netuid) public view returns (address) {
        bytes32 salt = _cloneSalt(user, netuid);
        return Clones.predictDeterministicAddress(forwarderLogic, salt, address(this));
    }

    /// @notice Process a deposit: deploy clone (lazily), flush its alpha stake, mint shares.
    ///         Only the user themselves or the contract owner can trigger this to prevent
    ///         front-running attacks where an attacker flushes the clone before the user is ready.
    function processDeposit(address user, uint256 netuid, bytes32 cloneSubstrateColdkey) external nonReentrant {
        if (msg.sender != user && msg.sender != owner()) revert UnauthorizedCaller();
        (bytes32[3] memory hotkeys,, uint8 validatorCount) = _resolveValidators(uint16(netuid));

        bytes32 salt = _cloneSalt(user, netuid);
        address cloneAddr = Clones.predictDeterministicAddress(forwarderLogic, salt, address(this));

        // Lazy-deploy (~45k gas first time, free thereafter)
        if (!cloneDeployed[cloneAddr]) {
            address deployed = Clones.cloneDeterministic(forwarderLogic, salt);
            require(deployed == cloneAddr, "Clone address mismatch");
            DepositForwarderLogic(payable(deployed)).initialize(address(this));
            cloneDeployed[cloneAddr] = true;
        }

        // Flush clone stake only from known validators (from registry).
        // No metagraph scan — bounded to max 3 validators, constant gas cost.
        if (validatorCount == 0) revert NoValidatorFound();
        IStaking staking = IStaking(STAKING_PRECOMPILE);
        uint256 totalDeposit = 0;

        for (uint8 i = 0; i < validatorCount; i++) {
            uint256 stakeUnderHk = staking.getStake(hotkeys[i], cloneSubstrateColdkey, netuid);
            if (stakeUnderHk > 0) {
                DepositForwarderLogic(payable(cloneAddr)).flush(vaultSubstrateColdkey, hotkeys[i], netuid, stakeUnderHk);
                totalDeposit += stakeUnderHk;
            }
        }
        if (totalDeposit == 0) revert ZeroAmount();

        // Gas-optimized rebalance: at most 1 moveStake per deposit
        if (validatorCount >= 2) {
            _rebalanceOnce(hotkeys, validatorCount, uint16(netuid));
        }

        // Calculate shares with virtual offset
        uint256 shares = _convertToShares(netuid, totalDeposit);
        if (shares == 0) revert ZeroAmount();

        totalStake[netuid] += totalDeposit;
        _mint(user, netuid, shares, "");

        emit Deposited(user, netuid, totalDeposit, shares, hotkeys[0]);
    }

    // ──────────────────── Withdraw Flow ─────────────────────────────────────────

    /// @notice Burn shares and receive alpha stake back via transferStake.
    function withdraw(uint256 netuid, uint256 shares, bytes32 userSubstrateColdkey) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender, netuid) < shares) revert InsufficientShares();

        uint256 assets = _convertToAssets(netuid, shares);
        if (assets == 0) revert ZeroAmount();

        _burn(msg.sender, netuid, shares);
        totalStake[netuid] -= assets;

        // Withdraw from hotkeys, starting with the one holding the most vault stake.
        (bytes32[3] memory hotkeys,, uint8 validatorCount) = _resolveValidators(uint16(netuid));

        IStaking staking = IStaking(STAKING_PRECOMPILE);
        uint256[3] memory balances;
        uint8[3] memory order;

        for (uint8 i = 0; i < validatorCount; i++) {
            balances[i] = staking.getStake(hotkeys[i], vaultSubstrateColdkey, netuid);
            order[i] = i;
        }

        // Simple selection sort by balance descending (max 3 elements)
        for (uint8 i = 0; i < validatorCount; i++) {
            for (uint8 j = i + 1; j < validatorCount; j++) {
                if (balances[order[j]] > balances[order[i]]) {
                    uint8 tmp = order[i];
                    order[i] = order[j];
                    order[j] = tmp;
                }
            }
        }

        uint256 remaining = assets;
        for (uint8 i = 0; i < validatorCount && remaining > 0; i++) {
            uint8 idx = order[i];
            uint256 take = remaining > balances[idx] ? balances[idx] : remaining;
            if (take > 0) {
                staking.transferStake(userSubstrateColdkey, hotkeys[idx], netuid, netuid, take);
                remaining -= take;
            }
        }

        // Rebalance remaining vault stake to target weights
        if (validatorCount >= 2) {
            _rebalanceOnce(hotkeys, validatorCount, uint16(netuid));
        }

        emit Withdrawn(msg.sender, netuid, shares, assets, hotkeys[0]);
    }

    // ──────────────────── Rebalance ───────────────────────────────────────────

    /// @notice Full rebalance of vault stake for a subnet to match registry target weights.
    ///         Anyone can call this (e.g. after validator registry update).
    ///         Performs up to N-1 moveStake calls to align with target weights.
    /// @param netuid The subnet to rebalance.
    function rebalance(uint256 netuid) external nonReentrant {
        (bytes32[3] memory hotkeys, uint16[3] memory weights, uint8 validatorCount) = _resolveValidators(uint16(netuid));

        if (validatorCount < 2) return;

        IStaking staking = IStaking(STAKING_PRECOMPILE);

        uint256[3] memory balances;
        uint256 total = 0;
        for (uint8 i = 0; i < validatorCount; i++) {
            balances[i] = staking.getStake(hotkeys[i], vaultSubstrateColdkey, netuid);
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
            staking.moveStake(hotkeys[overIdx], hotkeys[underIdx], netuid, netuid, moveAmt);
            balances[overIdx] -= moveAmt;
            balances[underIdx] += moveAmt;
            moveCount++;
        }

        emit Rebalanced(netuid, moveCount);
    }

    // ──────────────────── View Functions ────────────────────────────────────────

    /// @notice Price of 1 share (1e18 precision) for a given subnet vault.
    function sharePrice(uint256 netuid) external view returns (uint256) {
        uint256 supply = totalSupply(netuid);
        if (supply == 0) return 1e18;
        return (totalStake[netuid] * 1e18) / supply;
    }

    /// @notice Preview how many shares a deposit of `assets` into `netuid` would mint.
    function previewDeposit(uint256 netuid, uint256 assets) external view returns (uint256) {
        return _convertToShares(netuid, assets);
    }

    /// @notice Preview how many assets a withdrawal of `shares` from `netuid` would return.
    function previewWithdraw(uint256 netuid, uint256 shares) external view returns (uint256) {
        return _convertToAssets(netuid, shares);
    }

    /// @notice Returns the current best validator hotkey for a subnet.
    function getBestValidator(uint256 netuid) external view returns (bytes32) {
        (bytes32[3] memory hks,,) = _resolveValidators(uint16(netuid));
        return hks[0];
    }

    /// @notice Returns the preferred validators for a subnet (from registry, or top 3 by stake).
    ///         Unused slots are bytes32(0).
    function getBestValidators(uint256 netuid) external view returns (bytes32[3] memory) {
        (bytes32[3] memory hks,,) = _resolveValidators(uint16(netuid));
        return hks;
    }

    // ──────────────────── Admin ─────────────────────────────────────────────────

    /// @notice Inject yield/rewards into a vault (simulates validator earnings).
    function injectRewards(uint256 netuid) external payable onlyOwner {
        totalStake[netuid] += msg.value;
        emit RewardsInjected(netuid, msg.value);
    }

    /// @notice Set the validator registry contract.
    /// @param _registry Address of the ValidatorRegistry (or address(0) to use on-chain fallback).
    function setValidatorRegistry(address _registry) external onlyOwner {
        address old = address(validatorRegistry);
        validatorRegistry = IValidatorRegistry(_registry);
        emit ValidatorRegistryUpdated(old, _registry);
    }

    /// @notice Update the metadata URI.
    function setURI(string calldata newUri) external onlyOwner {
        _setURI(newUri);
    }

    // ──────────────────── Internal Helpers ──────────────────────────────────────

    /// @dev Resolve preferred validators + weights for a subnet from ValidatorRegistry.
    ///      Reverts if no validators are configured for this subnet.
    function _resolveValidators(uint16 netuid)
        internal
        view
        returns (bytes32[3] memory hotkeys, uint16[3] memory weights, uint8 count)
    {
        if (address(validatorRegistry) == address(0)) revert NoValidatorFound();

        (hotkeys, weights, count) = validatorRegistry.getValidators(netuid);
        if (count == 0) revert NoValidatorFound();
    }

    /// @dev Gas-optimized rebalance on deposit: single moveStake using target weights.
    function _rebalanceOnce(bytes32[3] memory hotkeys, uint8 validatorCount, uint16 netuid) internal {
        IStaking staking = IStaking(STAKING_PRECOMPILE);

        uint256[3] memory balances;
        uint256 total = 0;
        for (uint8 i = 0; i < validatorCount; i++) {
            balances[i] = staking.getStake(hotkeys[i], vaultSubstrateColdkey, netuid);
            total += balances[i];
        }
        if (total == 0) return;

        // Get target weights
        (, uint16[3] memory weights,) = _resolveValidators(netuid);

        // Compute targets from weights
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

        // Find most overweight and most underweight
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

        // Single moveStake
        if (maxOver > 0 && maxUnder > 0 && overIdx != underIdx) {
            uint256 moveAmt = maxOver < maxUnder ? maxOver : maxUnder;
            staking.moveStake(hotkeys[overIdx], hotkeys[underIdx], netuid, netuid, moveAmt);
        }
    }

    function _convertToShares(uint256 netuid, uint256 assets) internal view returns (uint256) {
        uint256 supply = totalSupply(netuid) + VIRTUAL_SHARES;
        uint256 totalAssets_ = totalStake[netuid] + VIRTUAL_ASSETS;
        return (assets * supply) / totalAssets_;
    }

    function _convertToAssets(uint256 netuid, uint256 shares) internal view returns (uint256) {
        uint256 supply = totalSupply(netuid) + VIRTUAL_SHARES;
        uint256 totalAssets_ = totalStake[netuid] + VIRTUAL_ASSETS;
        return (shares * totalAssets_) / supply;
    }

    /// @dev Salt = keccak256(user, netuid) — unique per (user, subnet) pair.
    function _cloneSalt(address user, uint256 netuid) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(user, netuid));
    }

    // ──────────────────── Overrides ─────────────────────────────────────────────

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override(ERC1155, ERC1155Supply)
    {
        super._update(from, to, ids, values);
    }

    /// @notice Accept native tokens (for reward injections).
    receive() external payable { }
}
