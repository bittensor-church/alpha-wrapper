// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ValidatorRegistry, MAX_VALIDATORS } from "src/ValidatorRegistry.sol";
import { AttestationHelper } from "./helpers/AttestationHelper.sol";

/// forge-config: default.isolate = true
contract ValidatorRegistryGasTest is AttestationHelper {
    uint256 private constant NETUID1 = 1;
    uint256 private constant NETUID2 = 2;
    uint256 private constant NETUID3 = 3;

    /// @dev Three validators is the expected size; every entry is priced there and again at the
    ///      64-validator ceiling, so a change that only shows up at full width cannot land unnoticed.
    uint256 private constant TYPICAL_VALIDATORS = 3;

    /// @dev The recovered addresses ascend in this order, which is the order the registry demands.
    uint256 private constant PK_LOW = 0xB0B;
    uint256 private constant PK_HIGH = 0xA11CE;

    ValidatorRegistry private registry;

    function setUp() public {
        _etchStakingMock();

        address[] memory initialSigners = new address[](2);
        initialSigners[0] = vm.addr(PK_LOW);
        initialSigners[1] = vm.addr(PK_HIGH);

        registry = new ValidatorRegistry(address(this), initialSigners, 2);
    }

    function _thresholdPks() private pure returns (uint256[] memory pks) {
        pks = new uint256[](2);
        pks[0] = PK_LOW;
        pks[1] = PK_HIGH;
    }

    function _submit(uint256 netuid, string memory salt, uint256 validatorCount) private {
        _submitAttestation(
            registry, netuid, _hotkeysFrom(salt, validatorCount), _evenWeights(validatorCount), _thresholdPks()
        );
    }

    /// @dev One batch covering `netuids`, each carrying `validatorCount` freshly derived hotkeys.
    function _submitBatch(uint256[] memory netuids, uint256 validatorCount) private {
        ValidatorRegistry.WeightAttestation[] memory attestations =
            new ValidatorRegistry.WeightAttestation[](netuids.length);
        bytes[][] memory signatures = new bytes[][](netuids.length);

        for (uint256 i; i < netuids.length; ++i) {
            bytes32[] memory hotkeys = _hotkeysFrom(string.concat("batch", vm.toString(netuids[i])), validatorCount);
            _recordHotkeyOwners(hotkeys);
            attestations[i] =
                _buildAttestation(netuids[i], hotkeys, _evenWeights(validatorCount), registry.nonces(netuids[i]) + 1);
            signatures[i] = _sign(_attestationDigest(registry, attestations[i]), _thresholdPks());
        }

        registry.updateValidatorsBatch(attestations, signatures);
    }

    function _threeSubnets() private pure returns (uint256[] memory netuids) {
        netuids = new uint256[](3);
        netuids[0] = NETUID1;
        netuids[1] = NETUID2;
        netuids[2] = NETUID3;
    }

    function test_gas_updateValidators_firstCommit() public {
        _submit(NETUID1, "validator", TYPICAL_VALIDATORS);
        vm.snapshotGasLastCall("ValidatorRegistry", "updateValidators: first commit");
    }

    // The steady-state cost: the subnet already has a set and every slot is overwritten.
    function test_gas_updateValidators_fullRotation() public {
        _submit(NETUID1, "validator", TYPICAL_VALIDATORS);

        _submit(NETUID1, "rotated", TYPICAL_VALIDATORS);
        vm.snapshotGasLastCall("ValidatorRegistry", "updateValidators: full rotation");
    }

    function test_gas_updateValidatorsBatch_threeSubnets() public {
        _submitBatch(_threeSubnets(), TYPICAL_VALIDATORS);
        vm.snapshotGasLastCall("ValidatorRegistry", "updateValidatorsBatch: three subnets");
    }

    // The vault reads the set on every state-mutating call, so this price is paid protocol-wide.
    function test_gas_getValidators() public {
        _submit(NETUID1, "validator", TYPICAL_VALIDATORS);

        registry.getValidators(NETUID1);
        vm.snapshotGasLastCall("ValidatorRegistry", "getValidators");
    }

    function test_gas_updateValidators_firstCommit_64Validators() public {
        _submit(NETUID1, "validator", MAX_VALIDATORS);
        vm.snapshotGasLastCall("ValidatorRegistry", "updateValidators: first commit (64 validators)");
    }

    function test_gas_updateValidators_fullRotation_64Validators() public {
        _submit(NETUID1, "validator", MAX_VALIDATORS);

        _submit(NETUID1, "rotated", MAX_VALIDATORS);
        vm.snapshotGasLastCall("ValidatorRegistry", "updateValidators: full rotation (64 validators)");
    }

    function test_gas_updateValidatorsBatch_threeSubnets_64Validators() public {
        _submitBatch(_threeSubnets(), MAX_VALIDATORS);
        vm.snapshotGasLastCall("ValidatorRegistry", "updateValidatorsBatch: three subnets (64 validators)");
    }

    function test_gas_getValidators_64Validators() public {
        _submit(NETUID1, "validator", MAX_VALIDATORS);

        registry.getValidators(NETUID1);
        vm.snapshotGasLastCall("ValidatorRegistry", "getValidators (64 validators)");
    }
}
