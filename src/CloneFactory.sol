// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { CloneGuard } from "./CloneGuard.sol";
import { IStaking, STAKING_PRECOMPILE } from "./interfaces/IStaking.sol";
import { VaultReads } from "./libraries/VaultReads.sol";
import { CloneContaminated, CloneProtectionFailed } from "./VaultErrors.sol";

/// @dev Deployed and owned by the vault, which initializes each clone and verifies that it rejects
///      locked alpha before publishing its address.
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

    function predictMailbox(address user, uint256 netuid, bytes32 uid) public view returns (address) {
        return Clones.predictDeterministicAddress(mailboxLogic, _mailboxSalt(user, netuid, uid), address(this));
    }

    function predictSubnetClone(uint256 tokenId, bytes32 uid) public view returns (address) {
        return Clones.predictDeterministicAddress(subnetLogic, _subnetSalt(tokenId, uid), address(this));
    }

    function predictGuard(address clone) public view returns (address) {
        bytes32 initHash =
            keccak256(abi.encodePacked(type(CloneGuard).creationCode, abi.encode(VaultReads.coldkeyOf(clone))));
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), _guardSalt(clone), initHash));
        return address(uint160(uint256(hash)));
    }

    function deployMailbox(address user, uint16 netuid, bytes32 uid) external onlyVault returns (address) {
        return _deploy(mailboxLogic, _mailboxSalt(user, netuid, uid), netuid);
    }

    function deploySubnetClone(uint256 tokenId, uint16 netuid, bytes32 uid) external onlyVault returns (address) {
        return _deploy(subnetLogic, _subnetSalt(tokenId, uid), netuid);
    }

    /// @dev Recovery-only mailboxes are never accepted as deposit addresses.
    function deployRecoveryMailbox(address user, uint256 netuid, bytes32 uid) external onlyVault returns (address) {
        return Clones.cloneDeterministic(mailboxLogic, _mailboxSalt(user, netuid, uid));
    }

    function _deploy(address implementation, bytes32 salt, uint16 netuid) private returns (address clone) {
        clone = Clones.predictDeterministicAddress(implementation, salt, address(this));
        address guard = predictGuard(clone);
        _requireClean(clone, netuid);
        _requireClean(guard, netuid);
        Clones.cloneDeterministic(implementation, salt);
        bytes32 coldkey = VaultReads.coldkeyOf(clone);
        new CloneGuard{ salt: _guardSalt(clone) }(coldkey);
        if (!VaultReads.ownedBy(coldkey, VaultReads.coldkeyOf(guard))) revert CloneProtectionFailed(clone);
    }

    function _requireClean(address candidate, uint16 netuid) private view {
        bytes32 coldkey = VaultReads.coldkeyOf(candidate);
        IStaking staking = IStaking(STAKING_PRECOMPILE);
        (bool owned,) = staking.getHotkeyOwner(coldkey);
        (bool swapped,) = staking.getColdkeyRoot(coldkey);
        // A swap can import ownership roles that create future locks even if today's lock is zero.
        // Plain unlocked alpha and TAO gifts do not give their sender authority over this account.
        if (
            candidate.code.length != 0 || owned || swapped || staking.getOwnedHotkeys(coldkey).length != 0
                || VaultReads.lockedAlphaOf(coldkey, netuid) != 0
        ) revert CloneContaminated(candidate);
    }

    function _mailboxSalt(address user, uint256 netuid, bytes32 uid) private pure returns (bytes32) {
        return keccak256(abi.encode("mailbox-v1", user, netuid, uid));
    }

    function _subnetSalt(uint256 tokenId, bytes32 uid) private pure returns (bytes32) {
        return keccak256(abi.encode("subnet-v1", tokenId, uid));
    }

    function _guardSalt(address clone) private pure returns (bytes32) {
        return keccak256(abi.encode("guard-v1", clone));
    }
}
