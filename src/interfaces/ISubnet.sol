// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Registration block is zero when unregistered, including late dissolution cleanup.
///      A dissolving netuid cannot be re-registered until asynchronous cleanup completes.
///      The counter steps on every registration of the netuid and survives dissolution.
interface ISubnet {
    function getNetworkRegistrationBlock(uint16 netuid) external view returns (uint64);

    function getRegisteredSubnetCounter(uint16 netuid) external view returns (uint64);

    function isSubnetDissolving(uint16 netuid) external view returns (bool);

    /// @dev The subnet's capacity settings; the tenth field is the owner's alpha-transfer switch.
    function getSubnetCapacityConfig(uint16 netuid)
        external
        view
        returns (
            uint16 minAllowedUids,
            uint16 maxAllowedUids,
            uint16 maxAllowedValidators,
            uint16 adjustmentInterval,
            uint16 targetRegistrationsPerInterval,
            uint16 minNonImmuneUids,
            uint16 immuneOwnerUidsLimit,
            uint16 bondsPenalty,
            bool ownerCutEnabled,
            bool transfersEnabled,
            uint16 maxRegistrationsPerBlock,
            uint8 mechanismCount
        );
}

address constant SUBNET_PRECOMPILE = 0x0000000000000000000000000000000000000803;
