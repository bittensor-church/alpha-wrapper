// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IValidatorRegistry {
    /// @dev Empty means unconfigured. Otherwise 1..64 distinct nonzero hotkeys with matching nonzero
    ///      BPS weights summing to 10000. Ownership was checked at submission, not guaranteed now.
    function getValidators(uint256 netuid) external view returns (bytes32[] memory hotkeys, uint16[] memory weights);
}
