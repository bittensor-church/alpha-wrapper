// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IValidatorRegistry
/// @notice Read interface that AlphaVault consumes to learn which validator hotkeys
///         to stake under, and in what BPS proportions, for a given subnet.
interface IValidatorRegistry {
    /// @notice Returns the per-subnet validator hotkeys and their BPS weights.
    /// @dev    `hotkeys` and `weights` are equal length and hold 1..64 entries, with no zero hotkey
    ///         and no zero weight; the weights sum to 10000. A subnet is configured iff the returned
    ///         length is non-zero.
    /// @param  netuid Subnet id.
    /// @notice Signed acknowledgement that a token's backing is gone. `slotsHash` pins the record
    ///         the signers examined, so an approval cannot be kept back for a later, different loss.
    struct BackingWriteDown {
        address vault;
        uint256 tokenId;
        bytes32 slotsHash;
        uint256 minimumBacking;
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice Spend one such approval. Callable only by the vault it names.
    function consumeWriteDown(BackingWriteDown calldata approval, bytes[] calldata signatures) external;

    /// @notice Attestation counter for a subnet, bumped by every accepted validator-set update.
    function nonces(uint256 netuid) external view returns (uint256);

    function getValidators(uint256 netuid) external view returns (bytes32[] memory hotkeys, uint16[] memory weights);
}
