// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";
import { IStaking, STAKING_PRECOMPILE } from "./interfaces/IStaking.sol";
import { VaultMath } from "./libraries/VaultMath.sol";
import { NetuidOutOfRange, ZeroHotkey } from "./VaultErrors.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice One validator per subnet, updated immediately by an owner with two-step transfers.
/// @dev Records ownership at submission, just like ValidatorRegistry. The vault performs staking.
contract BasicValidatorRegistry is IValidatorRegistry, Ownable2Step {
    struct Validator {
        bytes32 hotkey;
        bytes32 owner;
    }

    mapping(uint256 => Validator) private _validators;
    mapping(uint256 => uint256) public override nonces;

    event ValidatorUpdated(uint256 indexed netuid, uint256 nonce, bytes32 hotkey, bytes32 owner);

    error OwnerlessHotkey(bytes32 hotkey);
    error RenunciationDisabled();

    constructor(address initialOwner) Ownable(initialOwner) { }

    /// @notice Keep an owner available to update validators and release recovered parking.
    function renounceOwnership() public view override onlyOwner {
        revert RenunciationDisabled();
    }

    /// @notice Set the subnet's sole validator at 100% weight; there is no delay.
    /// @dev Resubmitting the same hotkey refreshes its owner and advances the nonce, allowing
    ///      the vault to leave parking after a fresh owner decision. Sets cannot be cleared.
    function setValidator(uint256 netuid, bytes32 hotkey) external onlyOwner {
        if (netuid > type(uint16).max) revert NetuidOutOfRange();
        if (hotkey == bytes32(0)) revert ZeroHotkey();
        (bool exists, bytes32 hotkeyOwner) = IStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkey);
        if (!exists) revert OwnerlessHotkey(hotkey);

        _validators[netuid] = Validator(hotkey, hotkeyOwner);
        uint256 nonce = ++nonces[netuid];
        emit ValidatorUpdated(netuid, nonce, hotkey, hotkeyOwner);
    }

    /// @inheritdoc IValidatorRegistry
    function getValidators(uint256 netuid)
        external
        view
        override
        returns (bytes32[] memory hotkeys, uint16[] memory weights, bytes32[] memory owners)
    {
        Validator memory validator = _validators[netuid];
        if (validator.hotkey == bytes32(0)) return (hotkeys, weights, owners);

        hotkeys = new bytes32[](1);
        weights = new uint16[](1);
        owners = new bytes32[](1);
        hotkeys[0] = validator.hotkey;
        weights[0] = VaultMath.BPS_BASE;
        owners[0] = validator.owner;
    }
}
