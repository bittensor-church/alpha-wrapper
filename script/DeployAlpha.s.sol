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
///         `RECOVERY_WINDOW` overrides how long (in seconds) a recorded backing loss stays
///         recoverable before it may be written off; it too is immutable once deployed.
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

        // It holds no state, so redeploying it against the same vault is always safe.
        AlphaVaultLens lens = new AlphaVaultLens(vault);
        console.log("AlphaVaultLens:        %s", address(lens));

        vm.stopBroadcast();
    }
}
