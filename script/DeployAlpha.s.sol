// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { DepositMailbox } from "src/DepositMailbox.sol";
import { SubnetClone } from "src/SubnetClone.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { ValidatorRegistry } from "src/ValidatorRegistry.sol";

/// @title DeployAlpha
/// @notice Deploys the alpha-wrapper contracts and wires ValidatorRegistry into AlphaVault.
///         Reads VR_ADMIN, VR_SIGNERS (comma-separated, ascending), and VR_THRESHOLD from env.
contract DeployAlpha is Script {
    function run() public {
        address admin = vm.envAddress("VR_ADMIN");
        address[] memory signers = vm.envAddress("VR_SIGNERS", ",");
        uint8 threshold = uint8(vm.envUint("VR_THRESHOLD"));

        vm.startBroadcast();

        DepositMailbox mailboxLogic = new DepositMailbox();
        SubnetClone subnetLogic = new SubnetClone();
        AlphaVault vault =
            new AlphaVault("https://api.tao20.io/metadata/{id}.json", address(mailboxLogic), address(subnetLogic));
        ValidatorRegistry registry = new ValidatorRegistry(admin, signers, threshold);
        vault.setValidatorRegistry(address(registry));

        vm.stopBroadcast();

        console.log("DepositMailbox:    %s", address(mailboxLogic));
        console.log("SubnetClone:       %s", address(subnetLogic));
        console.log("AlphaVault:        %s", address(vault));
        console.log("ValidatorRegistry: %s", address(registry));
    }
}
