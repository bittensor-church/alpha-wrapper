// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVault } from "src/AlphaVault.sol";

/// @dev Test-only subclass. `resyncTracked` settles the recorded expectations to a directly
///      arranged chain state, standing in for the operations that would have produced it.
contract AlphaVaultHarness is AlphaVault {
    constructor(string memory _uri, address _mailboxLogic, address _subnetLogic, address _validatorRegistry)
        AlphaVault(_uri, _mailboxLogic, _subnetLogic, _validatorRegistry)
    { }

    function resyncTracked(uint256 tokenId, bytes32 coldkey) external {
        if (subnetClone[tokenId] == address(0)) return;
        bytes32[] memory hotkeys = _slotHotkeys(tokenId);
        _refreshTracked(tokenId, _fetchBalances(hotkeys, coldkey, _netuid(tokenId)));
    }
}
