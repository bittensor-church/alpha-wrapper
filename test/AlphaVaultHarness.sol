// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVault } from "src/AlphaVault.sol";

/// @dev Test-only subclass exposing internal tracked-accounting hooks. `resyncTracked` lets a suite
///      that seeds a position by writing chain stake directly bring the vault's recorded high-water
///      back in line - the same effect a real vault-signed op has when it refreshes tracked at its
///      end - so the backing-integrity check sees a consistent state. `ratchetTracked` drives the
///      emission high-water in isolation. No production code is made test-only for either.
contract AlphaVaultHarness is AlphaVault {
    constructor(string memory uri, address mailboxLogic_, address subnetLogic_, address validatorRegistry_)
        AlphaVault(uri, mailboxLogic_, subnetLogic_, validatorRegistry_)
    { }

    function ratchetTracked(uint256 tokenId, uint256 slotIdx, uint256 observed) external {
        _ratchetTracked(tokenId, slotIdx, observed);
    }

    function resyncTracked(uint256 tokenId, bytes32 coldkey) external {
        Slot[3] memory tokenSlots = slots(tokenId);
        bytes32[3] memory hotkeys;
        hotkeys[0] = tokenSlots[0].hotkey;
        hotkeys[1] = tokenSlots[1].hotkey;
        hotkeys[2] = tokenSlots[2].hotkey;
        // forge-lint: disable-next-line(unsafe-typecast)
        _refreshTracked(tokenId, hotkeys, coldkey, uint16(tokenId & 0xFFFF));
    }
}
