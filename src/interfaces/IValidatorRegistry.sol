// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IValidatorRegistry {
    /// @dev Empty means unconfigured. Otherwise 1..64 distinct nonzero hotkeys with matching nonzero
    ///      BPS weights summing to 10000. Ownership was checked at submission, not guaranteed now.
    function getValidators(uint256 netuid) external view returns (bytes32[] memory hotkeys, uint16[] memory weights);

    /// @notice The coldkey that owned `hotkey` when it was last attested; zero if never attested.
    function attestedOwner(bytes32 hotkey) external view returns (bytes32);

    /// @notice Attestations landed for `netuid`; each landing increments it by one.
    function nonces(uint256 netuid) external view returns (uint256);
}
