// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

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
/// @dev Positive backing below share-price precision; use `previewUnwrap` for a larger burn.
error SharePriceBelowPrecision();
/// @dev The mailbox holds conviction-locked alpha; reclaim it to a coldkey that accepts locks.
error LockedDeposit();
error MailboxNotPrepared();
error SubnetCloneNotPrepared();
error LockedBacking();
error WithdrawTooSmall();
error ClaimBelowNativePrecision();
error SupplyCapExceeded();
error NetuidOutOfRange();
error ChosenHotkeyNotInSet();
error SlippageExceeded(uint256 amountOut);
/// @dev Located backing falls short of the recorded expectation, allowing for accounting dust.
error BackingShortfall(uint16 netuid, bytes32 hotkey, uint256 tracked);
/// @dev A declared shortfall holds priced operations shut until recovery completes or sync writes it off.
error ShortfallOnFile();
error BackingUnchanged();
error NothingToRecover();
/// @dev The subnet owner disabled alpha transfers; TAO exits and TAO mailbox reclaims still work.
error AlphaTransfersDisabled(uint16 netuid);
/// @dev A bit of the exclusion mask names a slot the record does not have.
error SlotMaskOutOfRange();
/// @dev Located backing remains exposed after collection; the recovery clock must not start.
error BackingNotSecured();
/// @dev The position rests on the parking hotkey until the registry publishes a newer set.
error Parked();
/// @dev The parking hotkey already belongs to another coldkey; deploy with an unused one.
error ParkingHotkeyUnavailable();
/// @dev No owned receiving key was resolved for this attested name.
///      Restore an owner record or replace the registry entry; the backing timer cannot fix ownership.
error AttestedHotkeyRetired(bytes32 hotkey);
