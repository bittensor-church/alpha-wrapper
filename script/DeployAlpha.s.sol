// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { DepositMailbox } from "src/DepositMailbox.sol";
import { SubnetClone } from "src/SubnetClone.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { AlphaVaultLens } from "src/AlphaVaultLens.sol";

/// @dev Configure the registry first; the vault's registry address, URI and recovery window are immutable.
contract DeployAlpha is Script {
    function run() public {
        address validatorRegistry = vm.envAddress("VALIDATOR_REGISTRY");
        string memory vaultUri = vm.envOr("VAULT_URI", string("https://api.tao20.io/metadata/{id}.json"));
        uint256 recoveryWindow = vm.envOr("RECOVERY_WINDOW", uint256(6 hours));
        console.log("Recovery window (s):   %s", recoveryWindow);

        vm.startBroadcast();

        DepositMailbox mailboxLogic = new DepositMailbox();
        SubnetClone subnetLogic = new SubnetClone();
        console.log("DepositMailbox:        %s", address(mailboxLogic));
        console.log("SubnetClone:           %s", address(subnetLogic));

        AlphaVault vault =
            new AlphaVault(vaultUri, address(mailboxLogic), address(subnetLogic), validatorRegistry, recoveryWindow);
        console.log("AlphaVault:            %s", address(vault));

        AlphaVaultLens lens = new AlphaVaultLens(vault);
        console.log("AlphaVaultLens:        %s", address(lens));

        vm.stopBroadcast();
    }
}
