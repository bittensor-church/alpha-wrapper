// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";

/// @title ValidatorRegistry
/// @notice Per-subnet validator hotkeys + BPS weights, updated by threshold-of-N
///         off-chain attesters via EIP-712 signed payloads.
contract ValidatorRegistry is IValidatorRegistry, EIP712, AccessControl {
    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "WeightAttestation(uint256 netuid,bytes32[] hotkeys,uint256[] weights,uint256 nonce,uint256 deadline)"
    );

    uint16 public constant BPS_BASE = 10_000;
    uint8 public constant MAX_VALIDATORS = 3;

    struct WeightAttestation {
        uint256 netuid;
        bytes32[] hotkeys;
        uint256[] weights;
        uint256 nonce;
        uint256 deadline;
    }

    struct ValidatorSet {
        bytes32[3] hotkeys;
        uint16[3] weights;
    }

    mapping(address => bool) public isSigner;
    address[] public signers;
    uint8 public threshold;

    mapping(uint256 => ValidatorSet) internal _validators;
    mapping(uint256 => uint256) public nonces;

    event SignersUpdated(address[] newSigners, uint8 newThreshold);
    event ValidatorsUpdated(uint256 indexed netuid, uint256 nonce, bytes32[] hotkeys, uint256[] weights);

    error ZeroAddress();
    error ZeroValue();
    error ZeroWeight();
    error DuplicateValue();
    error LengthMismatch();
    error InvalidValidatorCount();
    error NetuidOutOfRange();
    error WeightsMustSum10000();
    error StaleNonce();
    error ExpiredAttestation();
    error NotEnoughSignatures();
    error UnknownSigner(address signer);
    error SignersNotSorted();
    error ThresholdZero();
    error ThresholdExceedsSigners();

    constructor(address admin, address[] memory initialSigners, uint8 initialThreshold)
        EIP712("AlphaVault ValidatorRegistry", "1")
    {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setSigners(initialSigners, initialThreshold);
    }

    /// @param sigs Must be sorted by recovered signer address, ascending.
    function updateValidators(WeightAttestation calldata att, bytes[] calldata sigs) external {
        uint256 len = att.hotkeys.length;
        _validatePayload(att, len);
        _validateFreshness(att);
        _verifySignatures(att, sigs);
        _commit(att, len);
    }

    /// @param sigs Per-attestation signatures; each entry must be sorted ascending by recovered address.
    function updateValidatorsBatch(WeightAttestation[] calldata atts, bytes[][] calldata sigs) external {
        if (atts.length != sigs.length) revert LengthMismatch();
        for (uint256 i = 0; i < atts.length; i++) {
            uint256 len = atts[i].hotkeys.length;
            _validatePayload(atts[i], len);
            _validateFreshness(atts[i]);
            _verifySignatures(atts[i], sigs[i]);
            _commit(atts[i], len);
        }
    }

    /// @inheritdoc IValidatorRegistry
    function getValidators(uint256 netuid)
        external
        view
        override
        returns (bytes32[3] memory hotkeys, uint16[3] memory weights)
    {
        ValidatorSet storage vs = _validators[netuid];
        return (vs.hotkeys, vs.weights);
    }

    function setSigners(address[] calldata newSigners, uint8 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setSigners(newSigners, newThreshold);
    }

    function _setSigners(address[] memory newSigners, uint8 newThreshold) internal {
        uint256 oldLen = signers.length;
        for (uint256 i = 0; i < oldLen; i++) {
            isSigner[signers[i]] = false;
        }
        delete signers;

        uint256 newLen = newSigners.length;
        for (uint256 i = 0; i < newLen; i++) {
            address s = newSigners[i];
            if (s == address(0)) revert ZeroValue();
            if (isSigner[s]) revert DuplicateValue();
            isSigner[s] = true;
            signers.push(s);
        }

        if (newThreshold == 0) revert ThresholdZero();
        if (newThreshold > newLen) revert ThresholdExceedsSigners();
        threshold = newThreshold;

        emit SignersUpdated(newSigners, newThreshold);
    }

    function _validatePayload(WeightAttestation calldata att, uint256 len) internal pure {
        if (att.netuid > type(uint16).max) revert NetuidOutOfRange();
        if (len == 0 || len > MAX_VALIDATORS) revert InvalidValidatorCount();
        if (len != att.weights.length) revert LengthMismatch();

        uint256 sum = 0;
        for (uint256 i = 0; i < len; i++) {
            if (att.hotkeys[i] == bytes32(0)) revert ZeroValue();
            if (att.weights[i] == 0) revert ZeroWeight();
            for (uint256 j = i + 1; j < len; j++) {
                if (att.hotkeys[i] == att.hotkeys[j]) revert DuplicateValue();
            }
            sum += att.weights[i];
        }
        if (sum != BPS_BASE) revert WeightsMustSum10000();
    }

    function _validateFreshness(WeightAttestation calldata att) internal view {
        if (att.nonce != nonces[att.netuid] + 1) revert StaleNonce();
        if (block.timestamp > att.deadline) revert ExpiredAttestation();
    }

    function _verifySignatures(WeightAttestation calldata att, bytes[] calldata sigs) internal view {
        uint256 sigCount = sigs.length;
        if (sigCount < threshold) revert NotEnoughSignatures();

        bytes32 digest = _hashAttestation(att);
        address last = address(0);
        for (uint256 i = 0; i < sigCount; i++) {
            address recovered = ECDSA.recover(digest, sigs[i]);
            if (!isSigner[recovered]) revert UnknownSigner(recovered);
            if (recovered <= last) revert SignersNotSorted();
            last = recovered;
        }
    }

    function _commit(WeightAttestation calldata att, uint256 len) internal {
        nonces[att.netuid] = att.nonce;
        ValidatorSet storage vs = _validators[att.netuid];
        for (uint256 i = 0; i < MAX_VALIDATORS; i++) {
            if (i < len) {
                vs.hotkeys[i] = att.hotkeys[i];
                vs.weights[i] = uint16(att.weights[i]);
            } else {
                vs.hotkeys[i] = bytes32(0);
                vs.weights[i] = 0;
            }
        }
        emit ValidatorsUpdated(att.netuid, att.nonce, att.hotkeys, att.weights);
    }

    function _hashAttestation(WeightAttestation calldata att) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    ATTESTATION_TYPEHASH,
                    att.netuid,
                    keccak256(abi.encodePacked(att.hotkeys)),
                    keccak256(abi.encodePacked(att.weights)),
                    att.nonce,
                    att.deadline
                )
            )
        );
    }
}
