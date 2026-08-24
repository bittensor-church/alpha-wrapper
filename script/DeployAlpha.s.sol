// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { DepositMailbox } from "src/DepositMailbox.sol";
import { SubnetClone } from "src/SubnetClone.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { AlphaVaultLens } from "src/AlphaVaultLens.sol";

/// @title DeployAlpha
/// @notice Deploys only the alpha-wrapper contracts (DepositMailbox + SubnetClone + AlphaVault
///         + AlphaVaultLens).
///         Used standalone; the tao20 repo has its own deploy script that wires these up
///         with the rest of the index protocol.
/// @dev    The validator registry is an immutable constructor dependency, supplied via the
///         `VALIDATOR_REGISTRY` env var (deploy/configure `ValidatorRegistry` separately first).
///         `VAULT_URI` overrides the metadata URI; the vault cannot change it after deployment.
contract DeployAlpha is Script {
    function run() public {
        address validatorRegistry = vm.envAddress("VALIDATOR_REGISTRY");
        string memory vaultUri = vm.envOr("VAULT_URI", string("https://api.tao20.io/metadata/{id}.json"));

        vm.startBroadcast();

        DepositMailbox mailboxLogic = new DepositMailbox();
        SubnetClone subnetLogic = new SubnetClone();
        console.log("DepositMailbox:        %s", address(mailboxLogic));
        console.log("SubnetClone:           %s", address(subnetLogic));

        AlphaVault vault = new AlphaVault(vaultUri, address(mailboxLogic), address(subnetLogic), validatorRegistry);
        console.log("AlphaVault:            %s", address(vault));

        // Every quote the vault used to answer lives here. It holds no state, so redeploying it
        // against the same vault is always safe.
        AlphaVaultLens lens = new AlphaVaultLens(vault);
        console.log("AlphaVaultLens:        %s", address(lens));

        vm.stopBroadcast();
    }
}
