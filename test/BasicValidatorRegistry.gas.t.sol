// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { BasicValidatorRegistry } from "src/BasicValidatorRegistry.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// forge-config: default.isolate = true
contract BasicValidatorRegistryGasTest is Test {
    BasicValidatorRegistry private registry;
    bytes32 private constant HOTKEY = keccak256("hotkey");
    bytes32 private constant NEXT_HOTKEY = keccak256("next hotkey");

    function setUp() public {
        vm.etch(STAKING_PRECOMPILE, address(new MockStaking()).code);
        MockStaking(STAKING_PRECOMPILE).setHotkeyOwned(HOTKEY, true);
        MockStaking(STAKING_PRECOMPILE).setHotkeyOwned(NEXT_HOTKEY, true);
        registry = new BasicValidatorRegistry(address(this));
    }

    function test_gas_setValidator_firstCommit() public {
        registry.setValidator(1, HOTKEY);
        vm.snapshotGasLastCall("BasicValidatorRegistry", "setValidator: first commit");
    }

    function test_gas_setValidator_rotation() public {
        registry.setValidator(1, HOTKEY);
        registry.setValidator(1, NEXT_HOTKEY);
        vm.snapshotGasLastCall("BasicValidatorRegistry", "setValidator: rotation");
    }

    function test_gas_setValidator_refresh() public {
        registry.setValidator(1, HOTKEY);
        registry.setValidator(1, HOTKEY);
        vm.snapshotGasLastCall("BasicValidatorRegistry", "setValidator: refresh");
    }

    function test_gas_getValidators() public {
        registry.setValidator(1, HOTKEY);
        registry.getValidators(1);
        vm.snapshotGasLastCall("BasicValidatorRegistry", "getValidators");
    }

    function test_gas_getValidators_unconfigured() public {
        registry.getValidators(1);
        vm.snapshotGasLastCall("BasicValidatorRegistry", "getValidators: unconfigured");
    }

    function test_gas_transferOwnership() public {
        registry.transferOwnership(makeAddr("successor"));
        vm.snapshotGasLastCall("BasicValidatorRegistry", "transferOwnership");
    }

    function test_gas_acceptOwnership() public {
        address successor = makeAddr("successor");
        registry.transferOwnership(successor);
        vm.prank(successor);
        registry.acceptOwnership();
        vm.snapshotGasLastCall("BasicValidatorRegistry", "acceptOwnership");
    }
}
