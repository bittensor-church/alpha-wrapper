// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { DepositForwarderLogic } from "src/DepositForwarderLogic.sol";
import { AlphaVault } from "src/AlphaVault.sol";

/// @title DeployAlpha
/// @notice Deploys only the alpha-wrapper contracts (DepositForwarderLogic + AlphaVault).
///         Used standalone; the tao20 repo has its own deploy script that wires these up
///         with the rest of the index protocol.
contract DeployAlpha is Script {
    function run() public {
        vm.startBroadcast();

        DepositForwarderLogic forwarderLogic = new DepositForwarderLogic();
        console.log("DepositForwarderLogic: %s", address(forwarderLogic));

        bytes32 vaultSubstrateColdkey = keccak256("vault_substrate_coldkey_placeholder");
        AlphaVault vault =
            new AlphaVault("https://api.tao20.io/metadata/{id}.json", address(forwarderLogic), vaultSubstrateColdkey);
        console.log("AlphaVault:            %s", address(vault));

        vm.stopBroadcast();
    }
}
