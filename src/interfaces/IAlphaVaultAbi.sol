// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Single declaration site for the vault's events and for errors raised on its behalf by the
///         linked allocation library and the clone factory, so callers decode them from the vault ABI.
interface IAlphaVaultAbi {
    event Deposited(address indexed user, uint256 indexed tokenId, uint256 assets, uint256 shares);
    /// @dev `alphaOut` is observed recipient credit in alpha RAO, not the requested transfer.
    event Unwrapped(address indexed user, uint256 indexed tokenId, uint256 shares, uint256 alphaOut);
    /// @dev `taoOut` is native TAO in EVM wei.
    event DissolvedSubnetUnwrapped(address indexed user, uint256 indexed tokenId, uint256 shares, uint256 taoOut);
    /// @dev Weight-alignment moves only; excludes consolidation and payout-gather hops.
    event Rebalanced(uint256 indexed tokenId, bytes32 indexed fromHotkey, bytes32 indexed toHotkey, uint256 amount);
    event SubnetProxyCreated(uint256 indexed tokenId, address clone);
    event MailboxCreated(address indexed user, uint256 indexed netuid, address mailbox);
    /// @dev `sharesBurned` is the caller's burn and `sharesRefunded` the shares minted back for alpha the
    ///      sale left unsold; a full burn's empty-vault refund rate can exceed the burn. `taoOut` is EVM wei.
    event UnwrappedForTao(
        address indexed user,
        uint256 indexed tokenId,
        uint256 sharesBurned,
        uint256 sharesRefunded,
        uint256 alphaSold,
        uint256 taoOut
    );
    event MailboxAlphaSoldForTao(
        address indexed user, uint256 indexed netuid, bytes32 indexed hotkey, uint256 alpha, uint256 taoOut
    );
    /// @dev `amount` is native TAO in EVM wei.
    event TaoClaimed(address indexed user, uint256 indexed tokenId, address recipient, uint256 amount);
    /// @dev The window starts once located backing above the floor sits on parking; smaller piles can stay behind.
    event BackingShortfallDeclared(uint256 indexed tokenId, uint256 expected, uint256 located);
    event BackingShortfallCleared(uint256 indexed tokenId);
    /// @dev Loss falls on holders at write-off; later recovery belongs to holders at recovery time.
    event BackingWrittenOff(uint256 indexed tokenId, uint256 expected, uint256 located);
    /// @dev The position rests on the parking hotkey until an attestation newer than `registryNonce` lands.
    event BackingParked(uint256 indexed tokenId, uint256 backing, uint256 registryNonce);
    event BackingRecovered(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 amount);

    error ConsolidationBelowFloor();
    error GatherBelowFloor();
    error DepositTooSmall();
    error CloneProtectionFailed(address clone);
    error CloneContaminated(address candidate);
    /// @dev Two attested entries would share one backing key; attesters must resolve the collision.
    error SwappedHotkeyStillAttested();
}
