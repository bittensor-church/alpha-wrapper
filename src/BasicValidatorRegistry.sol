// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";
import { IStaking, STAKING_PRECOMPILE } from "./interfaces/IStaking.sol";
import { VaultMath } from "./libraries/VaultMath.sol";

/// @notice One validator per subnet, updated immediately by a permanent admin.
/// @dev Records ownership at submission, just like ValidatorRegistry. The vault performs staking.
contract BasicValidatorRegistry is IValidatorRegistry {
    struct Validator {
        bytes32 hotkey;
        bytes32 owner;
    }

    address public immutable admin;
    mapping(uint256 => Validator) private _validators;
    mapping(uint256 => uint256) public override nonces;

    event ValidatorUpdated(uint256 indexed netuid, uint256 nonce, bytes32 hotkey, bytes32 owner);

    error ZeroAddress();
    error Unauthorized();
    error NetuidOutOfRange();
    error ZeroHotkey();
    error OwnerlessHotkey(bytes32 hotkey);

    constructor(address admin_) {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
    }

    /// @notice Set the subnet's sole validator at 100% weight; there is no delay.
    /// @dev Resubmitting the same hotkey refreshes its owner and advances the nonce, allowing
    ///      the vault to leave parking after a fresh administrative decision. Sets cannot be cleared.
    function setValidator(uint256 netuid, bytes32 hotkey) external {
        if (msg.sender != admin) revert Unauthorized();
        if (netuid > type(uint16).max) revert NetuidOutOfRange();
        if (hotkey == bytes32(0)) revert ZeroHotkey();
        (bool exists, bytes32 owner) = IStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkey);
        if (!exists) revert OwnerlessHotkey(hotkey);

        _validators[netuid] = Validator(hotkey, owner);
        uint256 nonce = ++nonces[netuid];
        emit ValidatorUpdated(netuid, nonce, hotkey, owner);
    }

    /// @inheritdoc IValidatorRegistry
    function getValidators(uint256 netuid)
        external
        view
        override
        returns (bytes32[] memory hotkeys, uint16[] memory weights, bytes32[] memory owners)
    {
        Validator memory validator = _validators[netuid];
        uint256 count = validator.hotkey == bytes32(0) ? 0 : 1;
        hotkeys = new bytes32[](count);
        weights = new uint16[](count);
        owners = new bytes32[](count);
        if (count != 0) {
            hotkeys[0] = validator.hotkey;
            weights[0] = VaultMath.BPS_BASE;
            owners[0] = validator.owner;
        }
    }
}
