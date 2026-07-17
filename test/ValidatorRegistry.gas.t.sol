// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ValidatorRegistry } from "src/ValidatorRegistry.sol";
import { AttestationHelper } from "./helpers/AttestationHelper.sol";

/// forge-config: default.isolate = true
contract ValidatorRegistryGasTest is AttestationHelper {
    uint256 private constant PK1 = 0xA11CE;
    uint256 private constant PK2 = 0xB0B;
    uint256 private constant NETUID = 1;

    ValidatorRegistry private registry;
    uint256[] private signerPks;

    function setUp() public {
        // vm.addr(PK2) < vm.addr(PK1); the registry requires sigs sorted ascending by recovered
        // address, so attestations sign in this order.
        signerPks.push(PK2);
        signerPks.push(PK1);
        address[] memory signers = new address[](2);
        signers[0] = vm.addr(PK2);
        signers[1] = vm.addr(PK1);
        registry = new ValidatorRegistry(address(this), signers, 2);
    }

    /// @dev Salting the hotkeys by nonce makes every consecutive update a full set rotation.
    function _update(uint256 count, uint256 nonce) private {
        _submitAttestation(registry, NETUID, _generatedHotkeys(count, nonce), _splitWeights(count), signerPks);
    }

    function test_gas_updateValidators_threeValidatorsFirstWrite() public {
        _update(3, 1);
        vm.snapshotGasLastCall("ValidatorRegistry", "updateValidators: 3 validators, first write");
    }

    function test_gas_updateValidators_threeValidatorsRotation() public {
        _update(3, 1);
        _update(3, 2);
        vm.snapshotGasLastCall("ValidatorRegistry", "updateValidators: 3 validators, rotation");
    }

    function test_gas_updateValidators_maxValidatorsFirstWrite() public {
        _update(registry.MAX_VALIDATORS(), 1);
        vm.snapshotGasLastCall("ValidatorRegistry", "updateValidators: max validators, first write");
    }

    function test_gas_updateValidators_maxValidatorsRotation() public {
        _update(registry.MAX_VALIDATORS(), 1);
        _update(registry.MAX_VALIDATORS(), 2);
        vm.snapshotGasLastCall("ValidatorRegistry", "updateValidators: max validators, rotation");
    }
}
