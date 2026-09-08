// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev The caller's coldkey becomes the owner. A hotkey that already has an owner is left unchanged
///      and the call still succeeds; read the owner back to confirm the claim.
interface INeuron {
    function tryAssociateHotkey(bytes32 hotkey) external;
}

address constant NEURON_PRECOMPILE = 0x0000000000000000000000000000000000000804;
