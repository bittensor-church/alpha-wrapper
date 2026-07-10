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

    uint16 private constant BPS_BASE = 10_000;
    /// @dev Bounds `_setSigners` churn so a careless or compromised admin can't install a set
    ///      so large that subsequent rotation exceeds the block gas limit.
    uint8 private constant MAX_SIGNERS = 16;
    /// @notice Hard ceiling on `maxValidators` so a careless or compromised admin can't lift
    ///         the cap into set sizes whose iteration exceeds block gas limits in consumers;
    ///         64 matches Bittensor's standard per-subnet validator-permit slot count.
    uint8 public constant MAX_VALIDATORS_LIMIT = 64;

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

    /// @notice Admin-tunable bound on attested set size, keeping consumers that iterate the
    ///         set within block gas limits; the worst case is a vault exit after a full
    ///         rotation, which walks the merged current + last-seen sets: up to 2N stake
    ///         reads plus up to ~3N stake-moving precompile calls across sweep, drain, and
    ///         re-align. Lowering the cap does not shrink already-committed sets.
    uint8 public maxValidators = 20;

    mapping(uint256 => ValidatorSet) private _validators;
    mapping(uint256 => uint256) public nonces;

    event SignersUpdated(address[] newSigners, uint8 newThreshold);
    event MaxValidatorsUpdated(uint8 oldMaxValidators, uint8 newMaxValidators);
    event ValidatorsUpdated(uint256 indexed netuid, uint256 nonce, bytes32[] hotkeys, uint256[] weights);

    error ZeroAddress();
    error ZeroValue();
    error MaxValidatorsAboveLimit();
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
        uint256 n = atts.length;
        if (n != sigs.length) revert LengthMismatch();
        for (uint256 i; i < n;) {
            uint256 len = atts[i].hotkeys.length;
            _validatePayload(atts[i], len);
            _validateFreshness(atts[i]);
            _verifySignatures(atts[i], sigs[i]);
            _commit(atts[i], len);
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
        ValidatorSet storage vs = _validators[netuid];
        return (vs.hotkeys, vs.weights);
    }

    function setSigners(address[] calldata newSigners, uint8 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setSigners(newSigners, newThreshold);
    }

    function setMaxValidators(uint8 newMaxValidators) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMaxValidators == 0) revert ZeroValue();
        if (newMaxValidators > MAX_VALIDATORS_LIMIT) revert MaxValidatorsAboveLimit();
        uint8 oldMaxValidators = maxValidators;
        maxValidators = newMaxValidators;
        emit MaxValidatorsUpdated(oldMaxValidators, newMaxValidators);
    }

    function _setSigners(address[] memory newSigners, uint8 newThreshold) private {
        uint256 newLen = newSigners.length;
        if (newLen < 2) revert InsufficientSigners();
        if (newLen > MAX_SIGNERS) revert TooManySigners();
        if (newThreshold < 2) revert ThresholdTooLow();
        if (newThreshold > newLen) revert ThresholdExceedsSigners();

        address[] memory cached = signers;
        uint256 oldLen = cached.length;
        for (uint256 i; i < oldLen;) {
            isSigner[cached[i]] = false;
            unchecked {
                ++i;
            }
        }
        delete signers;

        for (uint256 i; i < newLen;) {
            address s = newSigners[i];
            if (s == address(0)) revert ZeroValue();
            if (isSigner[s]) revert DuplicateValue();
            isSigner[s] = true;
            signers.push(s);
            unchecked {
                ++i;
            }
        }

        threshold = newThreshold;

        emit SignersUpdated(newSigners, newThreshold);
    }

    function _validatePayload(WeightAttestation calldata att, uint256 len) private view {
        if (att.netuid > type(uint16).max) revert NetuidOutOfRange();
        if (len == 0 || len > maxValidators) revert InvalidValidatorCount();
        if (len != att.weights.length) revert LengthMismatch();

        uint256 sum;
        for (uint256 i; i < len;) {
            if (att.hotkeys[i] == bytes32(0)) revert ZeroValue();
            if (att.weights[i] == 0) revert ZeroWeight();
            for (uint256 j = i + 1; j < len;) {
                if (att.hotkeys[i] == att.hotkeys[j]) revert DuplicateValue();
                unchecked {
                    ++j;
                }
            }
            sum += att.weights[i];
            unchecked {
                ++i;
            }
        }
        if (sum != BPS_BASE) revert WeightsMustSum10000();
    }

    function _validateFreshness(WeightAttestation calldata att) private view {
        if (att.nonce != nonces[att.netuid] + 1) revert StaleNonce();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > att.deadline) revert ExpiredAttestation();
    }

    function _verifySignatures(WeightAttestation calldata att, bytes[] calldata sigs) private view {
        uint256 sigCount = sigs.length;
        if (sigCount < threshold) revert NotEnoughSignatures();

        bytes32 digest = _hashAttestation(att);
        address last;
        for (uint256 i; i < sigCount;) {
            address recovered = ECDSA.recover(digest, sigs[i]);
            if (!isSigner[recovered]) revert UnknownSigner(recovered);
            if (recovered <= last) revert SignersNotSorted();
            last = recovered;
            unchecked {
                ++i;
            }
        }
    }

    function _commit(WeightAttestation calldata att, uint256 len) private {
        nonces[att.netuid] = att.nonce;
        ValidatorSet storage vs = _validators[att.netuid];
        delete vs.hotkeys;
        delete vs.weights;
        for (uint256 i; i < len;) {
            vs.hotkeys.push(att.hotkeys[i]);
            // Weights sum to BPS_BASE, so each fits uint16.
            vs.weights.push(uint16(att.weights[i]));
            unchecked {
                ++i;
            }
        }
        emit ValidatorsUpdated(att.netuid, att.nonce, att.hotkeys, att.weights);
    }

    function _hashAttestation(WeightAttestation calldata att) private view returns (bytes32) {
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
