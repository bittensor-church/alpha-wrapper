// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { MockStaking } from "./MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// @dev Association from an EVM caller lands on that caller's mapped coldkey, as on chain.
contract MockNeuron {
    function tryAssociateHotkey(bytes32 hotkey) external {
        MockStaking(STAKING_PRECOMPILE).associate(hotkey, keccak256(abi.encodePacked("evm:", msg.sender)));
    }
}
