// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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
error DepositTooSmall();
error WithdrawTooSmall();
error ClaimBelowNativePrecision();
error SupplyCapExceeded();
error NetuidOutOfRange();
error ChosenHotkeyNotInSet();
error SlippageExceeded(uint256 amountOut);
error ConsolidationBelowFloor();
error GatherBelowFloor();
/// @dev Located backing falls short of the recorded expectation, allowing for accounting dust.
error BackingShortfall(uint16 netuid, bytes32 hotkey, uint256 tracked);
/// @dev A declared shortfall holds priced operations shut until `syncBacking` observes full coverage.
error ShortfallOnFile();
error BackingUnchanged();
error NothingToRecover();
/// @dev The subnet owner disabled alpha transfers; TAO exits and TAO mailbox reclaims still work.
error AlphaTransfersDisabled(uint16 netuid);
/// @dev The located balances must cover the whole recorded expectation before the position parks.
error RecoveryIncomplete();
/// @dev The position rests on the parking hotkey until the registry publishes a newer set.
error Parked();
/// @dev The parking hotkey already belongs to another coldkey; deploy with an unused one.
error ParkingHotkeyUnavailable();
/// @dev Two attested entries would share one backing key; attesters must resolve the collision.
error SwappedHotkeyStillAttested();
/// @dev No owned receiving key was resolved for this attested name.
///      Restore an owner record or replace the registry entry; the backing timer cannot fix ownership.
error AttestedHotkeyRetired(bytes32 hotkey);
