// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title StorageQueryReader
/// @notice Reads raw Substrate storage from the StorageQuery precompile (0x0807).
///         Constructs storage keys for SubtensorModule maps that use Identity hasher + u16 NetUid key.
library StorageQueryReader {
    error DissolvedQueueReadFailed();

    address constant STORAGE_QUERY = 0x0000000000000000000000000000000000000807;

    // twox_128("SubtensorModule") -- LE integer byte order, verified against subtensor source
    bytes16 constant PALLET_PREFIX = 0x658faa385070e074c85bf6b568cf0555;

    // twox_128("NetworkRegisteredAt")
    bytes16 constant NETWORK_REGISTERED_AT = 0x271d29b9b717ce3d8c571f1cbc180fa2;

    // twox_128("DissolvedNetworks")
    bytes16 constant DISSOLVED_NETWORKS = 0x3c50391079e54f03a7c9354a58591931;

    /// @notice Read the block number at which the current subnet on `netuid` was registered.
    /// @return blockNumber The registration block, or 0 if no subnet exists at this netuid.
    function readNetworkRegisteredAt(uint16 netuid) internal view returns (uint64 blockNumber) {
        bytes memory key = _buildKey(NETWORK_REGISTERED_AT, netuid);
        bytes memory result = _query(key);
        if (result.length < 8) return 0;
        return _decodeLEu64(result);
    }

    /// @notice Check whether `netuid` is currently in subtensor's DissolvedNetworks cleanup queue.
    /// @return True  = subnet cleanup is in progress; TAO refunds may not yet have been credited.
    ///         False = either the netuid was never dissolved, or every dissolution has been fully
    ///                 cleaned up.s
    function isNetuidInDissolvedQueue(uint16 netuid) internal view returns (bool) {
        bytes memory key = abi.encodePacked(PALLET_PREFIX, DISSOLVED_NETWORKS);
        (bool ok, bytes memory result) = STORAGE_QUERY.staticcall(key);
        if (!ok) revert DissolvedQueueReadFailed();
        if (result.length == 0) return false; // empty storage -> no dissolved networks

        // SCALE compact length prefix: single-byte mode has (length << 2) | 0b00 in the low byte.
        uint8 firstByte = uint8(result[0]);
        if ((firstByte & 0x03) != 0) revert DissolvedQueueReadFailed();
        uint256 len = uint256(firstByte >> 2);

        // Each NetUid is SCALE-encoded as a 2-byte little-endian u16.
        for (uint256 i = 0; i < len; i++) {
            uint256 pos = 1 + i * 2;
            if (pos + 1 >= result.length) revert DissolvedQueueReadFailed();
            uint16 entry = uint16(uint8(result[pos])) | (uint16(uint8(result[pos + 1])) << 8);
            if (entry == netuid) return true;
        }
        return false;
    }

    /// @dev Build a storage key: twox_128(pallet) ++ twox_128(item) ++ Identity(le_u16(netuid))
    ///      Identity hasher means the key bytes are used directly (no hashing).
    ///      NetUid is a u16 wrapper, SCALE-encoded as 2 bytes little-endian.
    function _buildKey(bytes16 itemPrefix, uint16 netuid) private pure returns (bytes memory) {
        return abi.encodePacked(
            PALLET_PREFIX,
            itemPrefix,
            bytes1(uint8(netuid & 0xFF)), // low byte (little-endian)
            bytes1(uint8(netuid >> 8)) // high byte
        );
    }

    /// @dev Call StorageQuery precompile. Entire calldata is the storage key.
    function _query(bytes memory key) private view returns (bytes memory) {
        (bool ok, bytes memory result) = STORAGE_QUERY.staticcall(key);
        if (!ok) return new bytes(0);
        return result;
    }

    /// @dev Decode a SCALE-encoded u64 (8 bytes, little-endian) from the start of `data`.
    function _decodeLEu64(bytes memory data) private pure returns (uint64) {
        uint64 val;
        for (uint256 i = 0; i < 8; i++) {
            val |= uint64(uint8(data[i])) << (i * 8);
        }
        return val;
    }
}
