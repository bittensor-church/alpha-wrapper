// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { ValidatorRegistry } from "src/ValidatorRegistry.sol";

abstract contract AttestationHelper is Test {
    uint16 public constant BPS_BASE = 10_000;

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

    function _generatedHotkeys(uint256 count) internal pure returns (bytes32[] memory) {
        return _generatedHotkeys(count, 0);
    }

    /// @dev Distinct deterministic hotkeys; vary `salt` to generate disjoint sets.
    function _generatedHotkeys(uint256 count, uint256 salt) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            arr[i] = keccak256(abi.encode("generated-hotkey", salt, i));
        }
    }

    /// @dev Equal split with the rounding remainder folded into the last entry, so the BPS sum is
    ///      exact and every value is bounded by BPS_BASE - the narrowing casts are lossless.
    function _splitWeights(uint256 count) internal pure returns (uint16[] memory arr) {
        arr = new uint16[](count);
        uint256 baseWeight = BPS_BASE / count;
        for (uint256 i = 0; i < count; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            arr[i] = uint16(baseWeight);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        arr[count - 1] = uint16(BPS_BASE - baseWeight * (count - 1));
    }

    /// @dev Valid attestation of arbitrary size; hotkeys are salted by nonce, so consecutive
    ///      attestations rotate the whole set.
    function _generatedAttestation(uint256 netuid, uint256 count, uint256 nonce)
        internal
        view
        returns (ValidatorRegistry.WeightAttestation memory att)
    {
        att.netuid = netuid;
        att.nonce = nonce;
        att.deadline = block.timestamp + 60;
        att.hotkeys = _generatedHotkeys(count, nonce);
        uint16[] memory weights = _splitWeights(count);
        att.weights = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            att.weights[i] = weights[i];
        }
    }

    function _submitAttestation(
        ValidatorRegistry registry,
        uint256 netuid,
        bytes32[] memory hotkeys,
        uint16[] memory weights,
        uint256[] memory signerPks
    ) internal {
        uint256[] memory wts = new uint256[](weights.length);
        for (uint256 i = 0; i < weights.length; i++) {
            wts[i] = weights[i];
        }
        ValidatorRegistry.WeightAttestation memory att = ValidatorRegistry.WeightAttestation({
            netuid: netuid,
            hotkeys: hotkeys,
            weights: wts,
            nonce: registry.nonces(netuid) + 1,
            deadline: block.timestamp + 3600
        });
        bytes32 digest = _attestationDigest(registry, att);
        bytes[] memory sigs = _sign(digest, signerPks);
        registry.updateValidators(att, sigs);
    }
}
