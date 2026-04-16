// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal mock for the StorageQuery precompile at 0x0807.
contract MockStorageQuery {
    bytes16 constant NETWORK_REGISTERED_AT = 0x271d29b9b717ce3d8c571f1cbc180fa2;
    bytes16 constant DISSOLVED_NETWORKS = 0x3c50391079e54f03a7c9354a58591931;

    mapping(uint16 => uint64) public registeredAt;
    uint16[] private _dissolvedNetworks;

    function setRegisteredAt(uint16 netuid, uint64 blockNumber) external {
        registeredAt[netuid] = blockNumber;
    }

    /// @notice Overwrite the entire DissolvedNetworks Vec<u16>. Pass an empty array to clear.
    function setDissolvedNetworks(uint16[] calldata netuids) external {
        delete _dissolvedNetworks;
        for (uint256 i = 0; i < netuids.length; i++) {
            _dissolvedNetworks.push(netuids[i]);
        }
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        if (data.length < 32) return new bytes(0);
        bytes16 itemPrefix = bytes16(data[16:32]);

        if (itemPrefix == NETWORK_REGISTERED_AT) {
            if (data.length < 34) return new bytes(0);
            uint16 netuid = uint16(uint8(data[32])) | (uint16(uint8(data[33])) << 8);
            uint64 val = registeredAt[netuid];
            if (val == 0) return new bytes(0);
            bytes memory out = new bytes(8);
            for (uint256 i = 0; i < 8; i++) {
                out[i] = bytes1(uint8(val >> (i * 8)));
            }
            return out;
        }

        if (itemPrefix == DISSOLVED_NETWORKS) {
            uint256 len = _dissolvedNetworks.length;
            if (len == 0) return new bytes(0);
            bytes memory out = new bytes(1 + len * 2);
            out[0] = bytes1(uint8(len << 2));
            for (uint256 i = 0; i < len; i++) {
                uint16 n = _dissolvedNetworks[i];
                out[1 + i * 2] = bytes1(uint8(n & 0xFF));
                out[2 + i * 2] = bytes1(uint8(n >> 8));
            }
            return out;
        }

        return new bytes(0);
    }
}
