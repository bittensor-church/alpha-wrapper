// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IStaking, STAKING_PRECOMPILE } from "./interfaces/IStaking.sol";
import { VaultReads } from "./libraries/VaultReads.sol";
import { IAlphaVaultAbi } from "./interfaces/IAlphaVaultAbi.sol";

/// @dev Deployed and owned by the vault, which initializes each clone as its own hotkey owner and
///      verifies that protection before publishing its address.
contract CloneFactory {
    address public immutable vault;
    address public immutable mailboxLogic;
    address public immutable subnetLogic;

    error NotVault();

    constructor(address _mailboxLogic, address _subnetLogic) {
        vault = msg.sender;
        mailboxLogic = _mailboxLogic;
        subnetLogic = _subnetLogic;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    /// @dev The caller's UID picks the candidate address, so a poisoned one is retried with a fresh UID.
    function deployMailbox(address user, uint16 netuid, bytes32 uid) external onlyVault returns (address) {
        return _deploy(mailboxLogic, keccak256(abi.encode("mailbox-v1", user, netuid, uid)), netuid);
    }

    function deploySubnetClone(uint256 tokenId, uint16 netuid, bytes32 uid) external onlyVault returns (address) {
        return _deploy(subnetLogic, keccak256(abi.encode("subnet-v1", tokenId, uid)), netuid);
    }

    function _deploy(address implementation, bytes32 salt, uint16 netuid) private returns (address candidate) {
        candidate = Clones.predictDeterministicAddress(implementation, salt, address(this));
        bytes32 coldkey = VaultReads.coldkeyOf(candidate);
        IStaking staking = IStaking(STAKING_PRECOMPILE);
        (bool owned,) = staking.getHotkeyOwner(coldkey);
        (bool swapped,) = staking.getColdkeyRoot(coldkey);
        // A swap can import ownership roles that create future locks even if today's lock is zero.
        // Plain unlocked alpha and TAO gifts do not give their sender authority over this account.
        if (
            candidate.code.length != 0 || owned || swapped || staking.getOwnedHotkeys(coldkey).length != 0
                || VaultReads.lockedAlphaOf(coldkey, netuid) != 0
        ) revert IAlphaVaultAbi.CloneContaminated(candidate);
        Clones.cloneDeterministic(implementation, salt);
    }
}
