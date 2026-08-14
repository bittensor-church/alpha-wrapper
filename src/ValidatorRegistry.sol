// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";

/// @dev The vault reads one stake balance per validator on every state-mutating call, and a
///      rotation settles every slot, so per-call work scales with this cap. 64 keeps the widest
///      measured path under a tenth of the block gas limit, so a position stays exitable at any
///      width the registry can commit.
uint256 constant MAX_VALIDATORS = 64;

/// @title ValidatorRegistry
/// @notice Per-subnet validator hotkeys + BPS weights, updated by threshold-of-N
///         off-chain attesters via EIP-712 signed payloads.
contract ValidatorRegistry is IValidatorRegistry, EIP712, AccessControl {
    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "WeightAttestation(uint256 netuid,bytes32[] hotkeys,uint256[] weights,uint256 nonce,uint256 deadline)"
    );

    uint16 private constant BPS_BASE = 10_000;
    /// @dev Bounds `_setSigners` churn so a careless or compromised admin can't install a set
    ///      so large that subsequent rotation exceeds the block gas limit.
    uint8 private constant MAX_SIGNERS = 16;

    struct WeightAttestation {
        uint256 netuid;
        bytes32[] hotkeys;
        uint256[] weights;
        uint256 nonce;
        uint256 deadline;
    }

    struct ValidatorSet {
        bytes32[] hotkeys;
        uint16[] weights;
    }

    mapping(address => bool) public isSigner;
    address[] public signers;
    uint8 public threshold;

    mapping(uint256 => ValidatorSet) private _validators;
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
    error InsufficientSigners();
    error TooManySigners();
    error ThresholdTooLow();
    error ThresholdExceedsSigners();

    constructor(address admin, address[] memory initialSigners, uint8 initialThreshold)
        EIP712("AlphaVault ValidatorRegistry", "1")
    {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setSigners(initialSigners, initialThreshold);
    }

    /// @param signatures Must be sorted by recovered signer address, ascending.
    function updateValidators(WeightAttestation calldata attestation, bytes[] calldata signatures) external {
        uint256 validatorCount = attestation.hotkeys.length;
        _validatePayload(attestation, validatorCount);
        _validateFreshness(attestation);
        _verifySignatures(attestation, signatures);
        _commit(attestation, validatorCount);
    }

    /// @param signatures Per-attestation signatures; each entry must be sorted ascending by recovered address.
    function updateValidatorsBatch(WeightAttestation[] calldata attestations, bytes[][] calldata signatures) external {
        uint256 attestationCount = attestations.length;
        if (attestationCount != signatures.length) revert LengthMismatch();
        for (uint256 i; i < attestationCount;) {
            uint256 validatorCount = attestations[i].hotkeys.length;
            _validatePayload(attestations[i], validatorCount);
            _validateFreshness(attestations[i]);
            _verifySignatures(attestations[i], signatures[i]);
            _commit(attestations[i], validatorCount);
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IValidatorRegistry
    function getValidators(uint256 netuid)
        external
        view
        override
        returns (bytes32[] memory hotkeys, uint16[] memory weights)
    {
        ValidatorSet storage validatorSet = _validators[netuid];
        return (validatorSet.hotkeys, validatorSet.weights);
    }

    function setSigners(address[] calldata newSigners, uint8 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setSigners(newSigners, newThreshold);
    }

    function _setSigners(address[] memory newSigners, uint8 newThreshold) private {
        uint256 newSignerCount = newSigners.length;
        if (newSignerCount < 2) revert InsufficientSigners();
        if (newSignerCount > MAX_SIGNERS) revert TooManySigners();
        if (newThreshold < 2) revert ThresholdTooLow();
        if (newThreshold > newSignerCount) revert ThresholdExceedsSigners();

        address[] memory oldSigners = signers;
        uint256 oldSignerCount = oldSigners.length;
        for (uint256 i; i < oldSignerCount;) {
            isSigner[oldSigners[i]] = false;
            unchecked {
                ++i;
            }
        }
        delete signers;

        for (uint256 i; i < newSignerCount;) {
            address signer = newSigners[i];
            if (signer == address(0)) revert ZeroValue();
            if (isSigner[signer]) revert DuplicateValue();
            isSigner[signer] = true;
            signers.push(signer);
            unchecked {
                ++i;
            }
        }

        threshold = newThreshold;

        emit SignersUpdated(newSigners, newThreshold);
    }

    function _validatePayload(WeightAttestation calldata attestation, uint256 validatorCount) private pure {
        if (attestation.netuid > type(uint16).max) revert NetuidOutOfRange();
        if (validatorCount == 0 || validatorCount > MAX_VALIDATORS) revert InvalidValidatorCount();
        if (validatorCount != attestation.weights.length) revert LengthMismatch();

        uint256 sum;
        for (uint256 i; i < validatorCount;) {
            if (attestation.hotkeys[i] == bytes32(0)) revert ZeroValue();
            if (attestation.weights[i] == 0) revert ZeroWeight();
            for (uint256 j = i + 1; j < validatorCount;) {
                if (attestation.hotkeys[i] == attestation.hotkeys[j]) revert DuplicateValue();
                unchecked {
                    ++j;
                }
            }
            sum += attestation.weights[i];
            unchecked {
                ++i;
            }
        }
        if (sum != BPS_BASE) revert WeightsMustSum10000();
    }

    function _validateFreshness(WeightAttestation calldata attestation) private view {
        if (attestation.nonce != nonces[attestation.netuid] + 1) revert StaleNonce();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > attestation.deadline) revert ExpiredAttestation();
    }

    function _verifySignatures(WeightAttestation calldata attestation, bytes[] calldata signatures) private view {
        uint256 signatureCount = signatures.length;
        if (signatureCount < threshold) revert NotEnoughSignatures();

        bytes32 digest = _hashAttestation(attestation);
        address previousSigner;
        for (uint256 i; i < signatureCount;) {
            address recovered = ECDSA.recover(digest, signatures[i]);
            if (!isSigner[recovered]) revert UnknownSigner(recovered);
            if (recovered <= previousSigner) revert SignersNotSorted();
            previousSigner = recovered;
            unchecked {
                ++i;
            }
        }
    }

    function _commit(WeightAttestation calldata attestation, uint256 validatorCount) private {
        nonces[attestation.netuid] = attestation.nonce;
        ValidatorSet storage validatorSet = _validators[attestation.netuid];
        delete validatorSet.hotkeys;
        delete validatorSet.weights;
        for (uint256 i; i < validatorCount;) {
            validatorSet.hotkeys.push(attestation.hotkeys[i]);
            // The sum == BPS_BASE check bounds every weight well inside uint16.
            validatorSet.weights.push(uint16(attestation.weights[i]));
            unchecked {
                ++i;
            }
        }
        emit ValidatorsUpdated(attestation.netuid, attestation.nonce, attestation.hotkeys, attestation.weights);
    }

    function _hashAttestation(WeightAttestation calldata attestation) private view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    ATTESTATION_TYPEHASH,
                    attestation.netuid,
                    keccak256(abi.encodePacked(attestation.hotkeys)),
                    keccak256(abi.encodePacked(attestation.weights)),
                    attestation.nonce,
                    attestation.deadline
                )
            )
        );
    }
}
