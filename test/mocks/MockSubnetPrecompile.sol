// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ISubnet } from "src/interfaces/ISubnet.sol";

contract MockSubnetPrecompile is ISubnet {
    mapping(uint16 => uint64) private _registeredAt;
    mapping(uint16 => bool) private _dissolving;

    function setRegisteredAt(uint16 netuid, uint64 blockNumber) external {
        _registeredAt[netuid] = blockNumber;
    }

    function setDissolving(uint16 netuid, bool value) external {
        _dissolving[netuid] = value;
    }

    function getNetworkRegistrationBlock(uint16 netuid) external view returns (uint64) {
        return _registeredAt[netuid];
    }

    function isSubnetDissolving(uint16 netuid) external view returns (bool) {
        return _dissolving[netuid];
    }
}
