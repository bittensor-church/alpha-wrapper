// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IStaking, STAKING_PRECOMPILE } from "./interfaces/IStaking.sol";
import { VaultReads } from "./libraries/VaultReads.sol";
import { CloneContaminated } from "./VaultErrors.sol";

/// @dev Deployed and owned by the vault, which initializes each clone as its own hotkey owner and
///      verifies that protection before publishing its address.
contract CloneFactory {
    /// @dev Bounds the checks one creation spends on candidates poisoned within the same block.
    uint256 private constant MAX_CANDIDATES = 4;

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

    function deployMailbox(address user, uint16 netuid) external onlyVault returns (address) {
        return _deploy(mailboxLogic, keccak256(abi.encode("mailbox-v1", user, netuid)), netuid);
    }

    function deploySubnetClone(uint256 tokenId, uint16 netuid) external onlyVault returns (address) {
        return _deploy(subnetLogic, keccak256(abi.encode("subnet-v1", tokenId)), netuid);
    }

    /// @dev Candidates derive from the previous block hash, so nobody can target one before the
    ///      creating transaction is visible; a candidate poisoned meanwhile is skipped.
    function _deploy(address implementation, bytes32 family, uint16 netuid) private returns (address candidate) {
        bytes32 freshness = blockhash(block.number - 1);
        for (uint256 index; index < MAX_CANDIDATES; ++index) {
            bytes32 salt = keccak256(abi.encode(family, freshness, index));
            candidate = Clones.predictDeterministicAddress(implementation, salt, address(this));
            if (_isClean(candidate, netuid)) return Clones.cloneDeterministic(implementation, salt);
        }
        revert CloneContaminated(candidate);
    }

    function _isClean(address candidate, uint16 netuid) private view returns (bool) {
        bytes32 coldkey = VaultReads.coldkeyOf(candidate);
        IStaking staking = IStaking(STAKING_PRECOMPILE);
        (bool owned,) = staking.getHotkeyOwner(coldkey);
        (bool swapped,) = staking.getColdkeyRoot(coldkey);
        // A swap can import ownership roles that create future locks even if today's lock is zero.
        // Plain unlocked alpha and TAO gifts do not give their sender authority over this account.
        return candidate.code.length == 0 && !owned && !swapped && staking.getOwnedHotkeys(coldkey).length == 0
            && VaultReads.lockedAlphaOf(coldkey, netuid) == 0;
    }
}
