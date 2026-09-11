// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { INeuron, NEURON_PRECOMPILE } from "./interfaces/INeuron.sol";

/// @dev Owns one clone's mapped account as a hotkey, because the chain refuses coldkey swaps into
///      existing hotkeys. Having no functions, it can never rename the hotkey or hand it over.
///      One guard per clone keeps the chain's per-owner hotkey list short.
contract CloneGuard {
    constructor(bytes32 cloneColdkey) {
        INeuron(NEURON_PRECOMPILE).tryAssociateHotkey(cloneColdkey);
    }
}
