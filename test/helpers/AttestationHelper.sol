// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { ValidatorRegistry } from "src/ValidatorRegistry.sol";
import { MockStaking } from "../mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

abstract contract AttestationHelper is Test {
    function _etchStakingMock() internal {
        vm.etch(STAKING_PRECOMPILE, address(new MockStaking()).code);
    }

    function _recordHotkeyOwner(bytes32 hotkey) internal {
        MockStaking(STAKING_PRECOMPILE).setHotkeyOwned(hotkey, true);
    }

    function _recordHotkeyOwners(bytes32[] memory hotkeys) internal {
        for (uint256 i; i < hotkeys.length; ++i) {
            _recordHotkeyOwner(hotkeys[i]);
        }
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
                att.nonce
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(registry), structHash));
    }

    /// @dev Order private keys by recovered address, not numeric value.
    function _sign(bytes32 digest, uint256[] memory pks) internal pure returns (bytes[] memory sigs) {
        sigs = new bytes[](pks.length);
        for (uint256 i = 0; i < pks.length; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(pks[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }
    }

    /// @dev Different salts give disjoint sets for full-rotation fixtures.
    function _hotkeysFrom(string memory salt, uint256 count) internal pure returns (bytes32[] memory hotkeys) {
        hotkeys = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            hotkeys[i] = keccak256(abi.encodePacked(salt, i));
        }
    }

    function _evenWeights(uint256 count) internal pure returns (uint16[] memory weights) {
        weights = new uint16[](count);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 slots = uint16(count);
        uint16 share = 10_000 / slots;
        for (uint16 i; i + 1 < slots; ++i) {
            weights[i] = share;
        }
        weights[slots - 1] = 10_000 - share * (slots - 1);
    }

    function _buildAttestation(uint256 netuid, bytes32[] memory hotkeys, uint16[] memory weights, uint256 nonce)
        internal
        pure
        returns (ValidatorRegistry.WeightAttestation memory att)
    {
        uint256[] memory wts = new uint256[](weights.length);
        for (uint256 i = 0; i < weights.length; i++) {
            wts[i] = weights[i];
        }
        att = ValidatorRegistry.WeightAttestation({ netuid: netuid, hotkeys: hotkeys, weights: wts, nonce: nonce });
    }

    /// @dev Seed owner records without resurrecting keys explicitly deleted by the test.
    function _submitAttestation(
        ValidatorRegistry registry,
        uint256 netuid,
        bytes32[] memory hotkeys,
        uint16[] memory weights,
        uint256[] memory signerPks
    ) internal {
        _recordHotkeyOwners(hotkeys);
        ValidatorRegistry.WeightAttestation memory att =
            _buildAttestation(netuid, hotkeys, weights, registry.nonces(netuid) + 1);
        bytes32 digest = _attestationDigest(registry, att);
        bytes[] memory sigs = _sign(digest, signerPks);
        registry.updateValidators(att, sigs);
    }
}
