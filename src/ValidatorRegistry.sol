// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";
import { IStaking, STAKING_PRECOMPILE } from "./interfaces/IStaking.sol";

/// @dev Bounds per-validator reads and storage writes on vault operations.
uint256 constant MAX_VALIDATORS = 64;

/// @notice Quorum-signed EIP-712 validator weights; hotkey ownership is checked at submission only.
contract ValidatorRegistry is IValidatorRegistry, EIP712, AccessControl {
    bytes32 public constant ATTESTATION_TYPEHASH =
        keccak256("WeightAttestation(uint256 netuid,bytes32[] hotkeys,uint256[] weights,uint256 nonce)");

    uint16 private constant BPS_BASE = 10_000;
    /// @dev Bounds signer-rotation work even if the admin is compromised.
    uint8 private constant MAX_SIGNERS = 16;

    struct WeightAttestation {
        uint256 netuid;
        bytes32[] hotkeys;
        uint256[] weights;
        uint256 nonce;
    }

    struct ValidatorSet {
        bytes32[] hotkeys;
        uint16[] weights;
        bytes32[] owners;
    }

    mapping(address => bool) public isSigner;
    address[] public signers;
    uint8 public threshold;

    mapping(uint256 => ValidatorSet) private _validators;
    mapping(uint256 => uint256) public override nonces;

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
    error NotEnoughSignatures();
    error UnknownSigner(address signer);
    error OwnerlessHotkey(bytes32 hotkey);
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

    /// @param signatures Sorted by recovered signer address, ascending.
    function updateValidators(WeightAttestation calldata attestation, bytes[] calldata signatures) external {
        bytes32[] memory owners = _validatePayload(attestation);
        _validateNonce(attestation);
        _verifySignatures(attestation, signatures);
        _commit(attestation, owners);
    }

    /// @param signatures Each attestation's signatures sorted by recovered signer address, ascending.
    function updateValidatorsBatch(WeightAttestation[] calldata attestations, bytes[][] calldata signatures) external {
        uint256 attestationCount = attestations.length;
        if (attestationCount != signatures.length) revert LengthMismatch();
        for (uint256 i; i < attestationCount;) {
            bytes32[] memory owners = _validatePayload(attestations[i]);
            _validateNonce(attestations[i]);
            _verifySignatures(attestations[i], signatures[i]);
            _commit(attestations[i], owners);
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

    /// @inheritdoc IValidatorRegistry
    function attestedOwners(uint256 netuid) external view override returns (bytes32[] memory) {
        return _validators[netuid].owners;
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

    /// @dev Reject ownerless targets before installing a set; the owners are recorded so the vault can
    ///      tell the attested validator from whoever claims a vacated name later.
    function _validatePayload(WeightAttestation calldata attestation) private view returns (bytes32[] memory owners) {
        uint256 validatorCount = attestation.hotkeys.length;
        if (attestation.netuid > type(uint16).max) revert NetuidOutOfRange();
        if (validatorCount == 0 || validatorCount > MAX_VALIDATORS) revert InvalidValidatorCount();
        if (validatorCount != attestation.weights.length) revert LengthMismatch();

        owners = new bytes32[](validatorCount);
        uint256 sum;
        for (uint256 i; i < validatorCount;) {
            bytes32 hotkey = attestation.hotkeys[i];
            if (hotkey == bytes32(0)) revert ZeroValue();
            if (attestation.weights[i] == 0) revert ZeroWeight();
            for (uint256 j = i + 1; j < validatorCount;) {
                if (hotkey == attestation.hotkeys[j]) revert DuplicateValue();
                unchecked {
                    ++j;
                }
            }
            (bool exists, bytes32 owner) = IStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkey);
            if (!exists) revert OwnerlessHotkey(hotkey);
            owners[i] = owner;
            sum += attestation.weights[i];
            unchecked {
                ++i;
            }
        }
        if (sum != BPS_BASE) revert WeightsMustSum10000();
    }

    /// @dev Signatures have no expiry; landing any update invalidates competing payloads at its nonce.
    function _validateNonce(WeightAttestation calldata attestation) private view {
        if (attestation.nonce != nonces[attestation.netuid] + 1) revert StaleNonce();
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

    function _commit(WeightAttestation calldata attestation, bytes32[] memory owners) private {
        nonces[attestation.netuid] = attestation.nonce;
        ValidatorSet storage validatorSet = _validators[attestation.netuid];
        delete validatorSet.hotkeys;
        delete validatorSet.weights;
        delete validatorSet.owners;
        for (uint256 i; i < owners.length;) {
            validatorSet.hotkeys.push(attestation.hotkeys[i]);
            // The weight sum bounds this cast to 10000.
            validatorSet.weights.push(uint16(attestation.weights[i]));
            validatorSet.owners.push(owners[i]);
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
                    attestation.nonce
                )
            )
        );
    }
}
