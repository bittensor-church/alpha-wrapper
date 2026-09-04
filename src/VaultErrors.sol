// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev The failure vocabulary of the alpha vault, declared once at file level so the vault, the
///      lens that quotes it, and the libraries they share all fail with the same selector.

error ZeroAmount();
error ZeroAddress();
error ZeroHotkey();
error ZeroColdkey();
error InsufficientShares();
error NoValidatorFound();
error ValidatorSetMalformed();
error SubnetNotRegistered();
error SubnetInDissolutionBlackoutPeriod();
error SubnetDissolved();
error NothingToUnwrap();
error NoSharesOutstanding();
/// @dev Backing exists but a share unit is worth less than the 1e18-scaled quote can express, which
///      only a written-off position recapitalized at the virtual rate reaches; a burn quote still
///      prices it.
error SharePriceBelowPrecision();
error DepositTooSmall();
error WithdrawTooSmall();
error ClaimBelowNativePrecision();
error SupplyCapExceeded();
error NetuidOutOfRange();
error ChosenHotkeyNotInSet();
error SlippageExceeded(uint256 amountOut);
error ConsolidationBelowFloor();
error GatherBelowFloor();
/// @dev The vault cannot account for backing a slot is owed; `tracked` is what the named key was
///      expected to hold. Clears when the alpha is found or the loss is written off.
error BackingShortfall(uint16 netuid, bytes32 hotkey, uint256 tracked);
error BackingUnchanged();
error NothingToRecover();
error RecoveryBelowFloor();
/// @dev The chain moves stake entries whole, so a slot's loss sits under one key; a source that
///      cannot cover the whole expectation is not where the backing went.
error RecoveryIncomplete();
/// @dev The attested set lists a swapped-away hotkey beside its successor; the vault cannot
///      serve it until the attesters drop the old name.
error SwappedHotkeyStillAttested();
