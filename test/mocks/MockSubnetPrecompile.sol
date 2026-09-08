// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ISubnet } from "src/interfaces/ISubnet.sol";

contract MockSubnetPrecompile is ISubnet {
    mapping(uint16 => uint64) private _registeredAt;
    mapping(uint16 => uint64) private _registrations;
    mapping(uint16 => bool) private _dissolving;
    mapping(uint16 => bool) private _transfersDisabled;

    function setRegisteredAt(uint16 netuid, uint64 blockNumber) external {
        _registeredAt[netuid] = blockNumber;
    }

    function setRegisteredSubnetCounter(uint16 netuid, uint64 registrations) external {
        _registrations[netuid] = registrations;
    }

    function setDissolving(uint16 netuid, bool value) external {
        _dissolving[netuid] = value;
    }

    function setTransfersEnabled(uint16 netuid, bool value) external {
        _transfersDisabled[netuid] = !value;
    }

    function getNetworkRegistrationBlock(uint16 netuid) external view returns (uint64) {
        return _registeredAt[netuid];
    }

    function getRegisteredSubnetCounter(uint16 netuid) external view returns (uint64) {
        return _registrations[netuid];
    }

    function isSubnetDissolving(uint16 netuid) external view returns (bool) {
        return _dissolving[netuid];
    }

    function getSubnetCapacityConfig(uint16 netuid)
        external
        view
        returns (uint16, uint16, uint16, uint16, uint16, uint16, uint16, uint16, bool, bool, uint16, uint8)
    {
        return (0, 0, 0, 0, 0, 0, 0, 0, false, !_transfersDisabled[netuid], 0, 0);
    }
}
