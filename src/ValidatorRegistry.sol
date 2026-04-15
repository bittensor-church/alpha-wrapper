// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";

/// @title ValidatorRegistry
/// @notice Push-based registry for preferred validators per subnet with target weights.
///         Off-chain bot selects best validators (e.g. by APY) and pushes hotkeys + weights.
///         AlphaVault reads from this registry to decide stake distribution and rebalancing.
///
/// @dev Weights are in basis points (BPS). Sum of weights for a subnet MUST equal 10000 (100%).
///      Example: 2 validators at 60/40 → weights = [6000, 4000].
contract ValidatorRegistry is IValidatorRegistry, AccessControl {
    bytes32 public constant UPDATER_ROLE = keccak256("UPDATER_ROLE");

    uint16 public constant BPS_BASE = 10_000;

    struct ValidatorSet {
        bytes32[3] hotkeys;
        uint16[3] weights; // BPS, must sum to 10000
        uint8 count;
        uint256 updatedAt;
    }

    mapping(uint256 => ValidatorSet) internal _validators;

    event ValidatorsUpdated(uint256 indexed netuid, uint8 count, uint256 timestamp);
    event ValidatorsBatchUpdated(uint256 subnetCount, uint256 timestamp);

    error EmptyValidators();
    error TooManyValidators();
    error ZeroHotkey();
    error WeightsMustSum10000();
    error LengthMismatch();

    constructor(address _admin, address _updater) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(UPDATER_ROLE, _updater);
    }

    /// @notice Set preferred validators + weights for a single subnet.
    /// @param netuid The subnet ID.
    /// @param hotkeys Array of validator hotkeys (1–3).
    /// @param weights Target allocation in BPS per validator. Must sum to 10000.
    function setValidators(uint256 netuid, bytes32[] calldata hotkeys, uint16[] calldata weights)
        external
        onlyRole(UPDATER_ROLE)
    {
        _setValidators(netuid, hotkeys, weights);
        emit ValidatorsUpdated(netuid, uint8(hotkeys.length), block.timestamp);
    }

    /// @notice Batch-set preferred validators + weights for multiple subnets in one tx.
    function setValidatorsBatch(
        uint256[] calldata netuids,
        bytes32[][] calldata hotkeySets,
        uint16[][] calldata weightSets
    ) external onlyRole(UPDATER_ROLE) {
        if (netuids.length != hotkeySets.length || netuids.length != weightSets.length) {
            revert LengthMismatch();
        }

        for (uint256 i = 0; i < netuids.length; i++) {
            _setValidators(netuids[i], hotkeySets[i], weightSets[i]);
        }

        emit ValidatorsBatchUpdated(netuids.length, block.timestamp);
    }

    // ──────────────────── IValidatorRegistry ─────────────────────────────────

    function getValidators(uint256 netuid)
        external
        view
        override
        returns (bytes32[3] memory hotkeys, uint16[3] memory weights, uint8 count)
    {
        ValidatorSet storage vs = _validators[netuid];
        return (vs.hotkeys, vs.weights, vs.count);
    }

    function hasValidators(uint256 netuid) external view override returns (bool) {
        return _validators[netuid].count > 0;
    }

    // ──────────────────── Internal ───────────────────────────────────────────

    function _setValidators(uint256 netuid, bytes32[] calldata hotkeys, uint16[] calldata weights) internal {
        if (hotkeys.length == 0) revert EmptyValidators();
        if (hotkeys.length > 3) revert TooManyValidators();
        if (hotkeys.length != weights.length) revert LengthMismatch();

        uint16 totalWeight = 0;
        for (uint8 i = 0; i < hotkeys.length; i++) {
            if (hotkeys[i] == bytes32(0)) revert ZeroHotkey();
            totalWeight += weights[i];
        }
        if (totalWeight != BPS_BASE) revert WeightsMustSum10000();

        ValidatorSet storage vs = _validators[netuid];
        // Clear
        vs.hotkeys[0] = bytes32(0);
        vs.hotkeys[1] = bytes32(0);
        vs.hotkeys[2] = bytes32(0);
        vs.weights[0] = 0;
        vs.weights[1] = 0;
        vs.weights[2] = 0;

        for (uint8 i = 0; i < hotkeys.length; i++) {
            vs.hotkeys[i] = hotkeys[i];
            vs.weights[i] = weights[i];
        }
        vs.count = uint8(hotkeys.length);
        vs.updatedAt = block.timestamp;
    }
}
