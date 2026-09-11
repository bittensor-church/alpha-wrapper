// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVault } from "src/AlphaVault.sol";

contract RevertingReceiver {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    receive() external payable {
        revert("nope");
    }
}

contract RefundRejectingReceiver {
    bool private rejecting;

    function rejectMints() external {
        rejecting = true;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external view returns (bytes4) {
        require(!rejecting, "no mints");
        return this.onERC1155Received.selector;
    }

    receive() external payable { }
}

/// @dev Capture the re-entry error so tests can distinguish the guard from incidental failures.
contract UnwrapForTaoReentrantReceiver {
    AlphaVault target;
    uint256 tokenId;
    uint256 shares;
    bytes public reentryError;
    bool public reentrySucceeded;
    bool private entered;

    function arm(AlphaVault t, uint256 tid, uint256 s) external {
        target = t;
        tokenId = tid;
        shares = s;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    receive() external payable {
        if (entered) return;
        entered = true;
        try target.unwrapForTao(tokenId, shares, 0) {
            reentrySucceeded = true;
        } catch (bytes memory err) {
            reentryError = err;
        }
    }
}

/// @dev Capture the re-entry error without reverting the outer payout.
contract ReclaimMailboxReentrantReceiver {
    AlphaVault target;
    uint256 netuid;
    bytes32 hotkey;
    bytes public reentryError;
    bool public reentrySucceeded;
    bool private entered;

    function arm(AlphaVault t, uint256 n, bytes32 h) external {
        target = t;
        netuid = n;
        hotkey = h;
    }

    receive() external payable {
        if (entered) return;
        entered = true;
        try target.reclaimMailboxAlphaAsTao(netuid, hotkey, 0) {
            reentrySucceeded = true;
        } catch (bytes memory err) {
            reentryError = err;
        }
    }
}

contract ClaimDuringTransferReceiver {
    AlphaVault public immutable vault;
    bool public claimSucceeded;

    constructor(AlphaVault _vault) {
        vault = _vault;
    }

    function onERC1155Received(address, address, uint256 id, uint256, bytes calldata) external returns (bytes4) {
        try vault.claimTao(id, payable(address(this))) {
            claimSucceeded = true;
        } catch { }
        return this.onERC1155Received.selector;
    }

    receive() external payable { }
}

contract ClaimReentrantReceiver {
    AlphaVault private immutable vault;
    uint256 private immutable tokenId;
    bytes public reentryError;
    bool public reentrySucceeded;

    constructor(AlphaVault target, uint256 id) {
        vault = target;
        tokenId = id;
    }

    receive() external payable {
        try vault.claimTao(tokenId, payable(address(this))) {
            reentrySucceeded = true;
        } catch (bytes memory reason) {
            reentryError = reason;
        }
    }
}
