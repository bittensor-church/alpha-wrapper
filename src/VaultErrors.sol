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
error DepositTooSmall();
error WithdrawTooSmall();
error ClaimBelowNativePrecision();
error SupplyCapExceeded();
error NetuidOutOfRange();
error ChosenHotkeyNotInSet();
error SlippageExceeded(uint256 amountOut);
error ConsolidationBelowFloor();
error GatherBelowFloor();
/// @dev Raised while the vault cannot account for backing a slot is owed; `tracked` is what the
///      named key was expected to hold. Only `syncBacking` clears it, by booking the loss.
error BackingShortfall(uint16 netuid, bytes32 hotkey, uint256 tracked);
error BackingUnchanged();
error NothingToRecover();
/// @dev A recovery named a slot that is missing nothing while another slot is.
error RecoveryMisdirected();
error RecoveryBelowFloor();
/// @dev The attested set names a hotkey the record has followed onto another attested key: the
///      old name is swapped away and refuses every stake operation, so the set cannot be served
///      until the attesters drop it.
error SwappedHotkeyStillAttested();
