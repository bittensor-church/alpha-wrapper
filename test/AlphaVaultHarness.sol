// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVault } from "src/AlphaVault.sol";
import { IStaking, STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// @dev Test-only subclass. Tests arrange chain states directly instead of replaying the real
///      operations that would produce them; `resyncTracked` settles the recorded expectations to
///      the arranged state, standing in for that skipped history.
contract AlphaVaultHarness is AlphaVault {
    constructor(string memory _uri, address _mailboxLogic, address _subnetLogic, address _validatorRegistry)
        AlphaVault(_uri, _mailboxLogic, _subnetLogic, _validatorRegistry)
    { }

    function resyncTracked(uint256 tokenId, bytes32 coldkey) external {
        if (subnetClone[tokenId] == address(0)) return;
        bytes32[] memory hotkeys = this.lastSeenHotkeys(tokenId);
        uint256[] memory balances = new uint256[](hotkeys.length);
        // Token ids place the netuid in the low 16 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 netuid = uint16(tokenId);
        for (uint256 i; i < hotkeys.length; ++i) {
            balances[i] = IStaking(STAKING_PRECOMPILE).getStake(hotkeys[i], coldkey, netuid);
        }
        _settleSlots(tokenId, coldkey, hotkeys, balances, balances, hotkeys.length);
    }
}
