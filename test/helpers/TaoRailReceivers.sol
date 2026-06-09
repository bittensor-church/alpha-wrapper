// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVault } from "src/AlphaVault.sol";

/// @dev Accepts ERC1155 mints (required because the vault path mints shares to the caller)
///      and rejects any native TAO payment.
contract RevertingReceiver {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    receive() external payable {
        revert("nope");
    }
}

/// @dev On receiving TAO, re-enters `unwrapForTao` to exercise the reentrancy guard on the
///      vault path. Holds ERC1155 shares so it needs the acceptance hook.
contract UnwrapForTaoReentrantReceiver {
    AlphaVault target;
    uint256 tokenId;
    uint256 shares;

    function arm(AlphaVault t, uint256 tid, uint256 s) external {
        target = t;
        tokenId = tid;
        shares = s;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    receive() external payable {
        target.unwrapForTao(tokenId, shares, 0);
    }
}

/// @dev On receiving TAO, re-enters `reclaimMailboxAlphaAsTao` to exercise the reentrancy guard
///      on the mailbox path. No ERC1155 mints occur on this path, so no acceptance hook needed.
contract ReclaimMailboxReentrantReceiver {
    AlphaVault target;
    uint256 netuid;
    bytes32 hotkey;

    function arm(AlphaVault t, uint256 n, bytes32 h) external {
        target = t;
        netuid = n;
        hotkey = h;
    }

    receive() external payable {
        target.reclaimMailboxAlphaAsTao(netuid, hotkey, 0);
    }
}
