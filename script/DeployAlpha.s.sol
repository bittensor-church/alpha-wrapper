// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { DepositMailbox } from "src/DepositMailbox.sol";
import { SubnetClone } from "src/SubnetClone.sol";
import { AlphaVault } from "src/AlphaVault.sol";

/// @title DeployAlpha
/// @notice Deploys only the alpha-wrapper contracts (DepositMailbox + SubnetClone + AlphaVault).
///         Used standalone; the tao20 repo has its own deploy script that wires these up
///         with the rest of the index protocol.
contract DeployAlpha is Script {
    function run() public {
        vm.startBroadcast();

        DepositMailbox mailboxLogic = new DepositMailbox();
        SubnetClone subnetLogic = new SubnetClone();
        console.log("DepositMailbox:        %s", address(mailboxLogic));
        console.log("SubnetClone:           %s", address(subnetLogic));

        AlphaVault vault =
            new AlphaVault("https://api.tao20.io/metadata/{id}.json", address(mailboxLogic), address(subnetLogic));
        console.log("AlphaVault:            %s", address(vault));

        vm.stopBroadcast();
    }
}
