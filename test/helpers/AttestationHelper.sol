// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { ValidatorRegistry } from "src/ValidatorRegistry.sol";

abstract contract AttestationHelper is Test {
    function _generateHotkeys(uint256 count) internal pure returns (bytes32[] memory) {
        return _generateHotkeys(count, "generated-hotkey");
    }

    function _generateHotkeys(uint256 count, string memory tag) internal pure returns (bytes32[] memory hotkeys) {
        hotkeys = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            hotkeys[i] = keccak256(abi.encode(tag, i));
        }
    }

    /// @dev Distinct per-index weights summing to 10000 BPS: a descending ramp with the
    ///      rounding remainder on slot 0, so a weight-to-index misalignment cannot round-trip.
    function _rampWeights(uint256 count) internal pure returns (uint256[] memory weights) {
        weights = new uint256[](count);
        uint256 baseWeight = (10_000 - count * (count + 1) / 2) / count;
        uint256 assigned;
        for (uint256 i; i < count; ++i) {
            weights[i] = baseWeight + (count - i);
            assigned += weights[i];
        }
        weights[0] += 10_000 - assigned;
    }

    function _domainSeparator(ValidatorRegistry registry) internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            registry.eip712Domain();
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
    }

    function _attestationDigest(ValidatorRegistry registry, ValidatorRegistry.WeightAttestation memory att)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                registry.ATTESTATION_TYPEHASH(),
                att.netuid,
                keccak256(abi.encodePacked(att.hotkeys)),
                keccak256(abi.encodePacked(att.weights)),
                att.nonce,
                att.deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(registry), structHash));
    }

    /// @dev `pks` must be ordered such that the recovered addresses ascend (the contract
    ///      enforces this in `_verifySignatures`).
    function _sign(bytes32 digest, uint256[] memory pks) internal pure returns (bytes[] memory sigs) {
        sigs = new bytes[](pks.length);
        for (uint256 i = 0; i < pks.length; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(pks[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }
    }

    function _submitAttestation(
        ValidatorRegistry registry,
        uint256 netuid,
        bytes32[] memory hotkeys,
        uint256[] memory weights,
        uint256[] memory signerPks
    ) internal {
        ValidatorRegistry.WeightAttestation memory att = ValidatorRegistry.WeightAttestation({
            netuid: netuid,
            hotkeys: hotkeys,
            weights: weights,
            nonce: registry.nonces(netuid) + 1,
            deadline: block.timestamp + 3600
        });
        bytes32 digest = _attestationDigest(registry, att);
        bytes[] memory sigs = _sign(digest, signerPks);
        registry.updateValidators(att, sigs);
    }
}
