// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { VaultMath } from "src/libraries/VaultMath.sol";
import { MockAlpha } from "./MockAlpha.sol";
import { ALPHA_PRECOMPILE } from "src/interfaces/IAlpha.sol";

/// @dev Fixtures must seed minimums after `vm.etch`, which copies code but not storage.
uint256 constant CHAIN_MIN_STAKE = 2e6;

uint256 constant CHAIN_MIN_TRANSFER = 1e5;

uint256 constant CHAIN_NOMINATOR_MIN_STAKE = 20e6;

/// @dev Uses keccak256, not Frontier's blake2b; amounts are simplified for unit tests.
contract MockStaking {
    mapping(bytes32 => mapping(bytes32 => mapping(uint256 => uint256))) public stakes;
    uint256 public moveStakeRoundingLoss;
    uint256 public moveStakeResidual;
    uint256 public transferStakeRoundingLoss;
    bool public transferStakeReverts;
    bool public consumeAllGasOnFailure;
    bool public nativeTaoUnits;
    uint256 private _chainMinStakeTao;

    uint256 private _chainMinTransferTao;

    function setTransferStakeReverts(bool v) external {
        transferStakeReverts = v;
    }

    function setConsumeAllGasOnFailure(bool v) external {
        consumeAllGasOnFailure = v;
    }

    /// @dev Enable the precompile's RAO-to-EVM conversion without changing the quote's RAO units.
    function setNativeTaoUnits(bool enabled) external {
        nativeTaoUnits = enabled;
    }

    // Real precompile rejection consumes forwarded gas; plain Solidity revert would refund it.
    function _fail(string memory reason) private view {
        if (consumeAllGasOnFailure) {
            assembly {
                invalid()
            }
        }
        revert(reason);
    }

    /// @dev Alpha per (coldkey, netuid) across hotkeys, the total the chain's lock checks read.
    mapping(bytes32 => mapping(uint256 => uint256)) public coldkeyAlpha;

    function setStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid, uint256 amount) external {
        coldkeyAlpha[coldkey][netuid] = coldkeyAlpha[coldkey][netuid] + amount - stakes[hotkey][coldkey][netuid];
        stakes[hotkey][coldkey][netuid] = amount;
    }

    function _senderColdkey() private view returns (bytes32) {
        return keccak256(abi.encodePacked("evm:", msg.sender));
    }

    // Chain minimums use full-precision prices even when the EVM reader rounds to zero.
    function _belowTaoValue(uint256 amount, uint256 netuid, uint256 thresholdTao) private view returns (bool) {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 alphaPriceE18 = MockAlpha(ALPHA_PRECOMPILE).chainAlphaPrice(uint16(netuid));
        return (amount * alphaPriceE18) / VaultMath.ALPHA_PRICE_SCALE < thresholdTao;
    }

    function setChainMinStake(uint256 minStakeTao) external {
        _chainMinStakeTao = minStakeTao;
    }

    function setChainMinTransfer(uint256 minTransferTao) external {
        _chainMinTransferTao = minTransferTao;
    }

    function getDefaultMinStake() external view returns (uint256) {
        return _chainMinStakeTao;
    }

    function _belowMinTransfer(uint256 amount, uint256 netuid) private view returns (bool) {
        return _belowTaoValue(amount, netuid, _chainMinTransferTao);
    }

    // --- Conviction locks -------------------------------------------------------------------------
    // The chain keys a lock by hotkey as well; only the coldkey-wide locked mass matters to the vault.

    /// @dev Locked mass per (coldkey, netuid) in alpha RAO, and the one hotkey the chain keys it to.
    mapping(bytes32 => mapping(uint256 => uint256)) public lockedAlpha;
    mapping(bytes32 => mapping(uint256 => bytes32)) public lockHotkey;
    mapping(bytes32 => bool) private _acceptsLockedAlpha;
    mapping(bytes32 => uint256) public rejectLockedAlphaCalls;

    function setLockedAlpha(bytes32 coldkey, uint256 netuid, bytes32 hotkey, uint256 amount) external {
        lockedAlpha[coldkey][netuid] = amount;
        lockHotkey[coldkey][netuid] = amount == 0 ? bytes32(0) : hotkey;
    }

    /// @dev Models the flag a coldkey swap copies onto an account with no stake.
    function setAcceptsLockedAlpha(bytes32 coldkey, bool accepts) external {
        _acceptsLockedAlpha[coldkey] = accepts;
    }

    function getRejectLockedAlpha(bytes32 coldkey) external view returns (bool) {
        return !_acceptsLockedAlpha[coldkey];
    }

    function getColdkeyLock(bytes32 coldkey, uint256 netuid)
        external
        view
        returns (bool exists, bytes32 hotkey, uint256 locked, uint128 conviction, bool perpetual)
    {
        locked = lockedAlpha[coldkey][netuid];
        return (locked != 0, lockHotkey[coldkey][netuid], locked, conviction, perpetual);
    }

    function setRejectLockedAlpha(bool enabled) external payable {
        bytes32 coldkey = _senderColdkey();
        _acceptsLockedAlpha[coldkey] = !enabled;
        rejectLockedAlphaCalls[coldkey]++;
    }

    /// @dev Unlocked alpha leaves first; whatever a transfer takes beyond it carries the lock along.
    function _carriedLock(bytes32 coldkey, uint256 netuid, uint256 amount) private view returns (uint256) {
        uint256 locked = lockedAlpha[coldkey][netuid];
        if (locked == 0) return 0;
        uint256 total = coldkeyAlpha[coldkey][netuid];
        uint256 available = total > locked ? total - locked : 0;
        if (amount <= available) return 0;
        uint256 excess = amount - available;
        return excess > locked ? locked : excess;
    }

    function transferStake(
        bytes32 destination_coldkey,
        bytes32 hotkey,
        uint256 origin_netuid,
        uint256 destination_netuid,
        uint256 amount
    ) external payable {
        if (transferStakeReverts) {
            _fail("MockStaking: transferStake reverted");
        }
        if (!_hasOwnerRecord(hotkey)) {
            _fail("MockStaking: hotkey has no owner");
        }
        if (_belowMinTransfer(amount, origin_netuid)) {
            _fail("MockStaking: AmountTooLow");
        }
        bytes32 origin = _senderColdkey();
        uint256 carriedLock = _carriedLock(origin, origin_netuid, amount);
        if (carriedLock != 0) {
            if (!_acceptsLockedAlpha[destination_coldkey]) {
                _fail("MockStaking: AccountRejectsLockedAlpha");
            }
            bytes32 destinationLockHotkey = lockHotkey[destination_coldkey][destination_netuid];
            if (destinationLockHotkey != bytes32(0) && destinationLockHotkey != hotkey) {
                _fail("MockStaking: LockHotkeyMismatch");
            }
            lockedAlpha[origin][origin_netuid] -= carriedLock;
            if (lockedAlpha[origin][origin_netuid] == 0) lockHotkey[origin][origin_netuid] = bytes32(0);
            lockHotkey[destination_coldkey][destination_netuid] = hotkey;
            lockedAlpha[destination_coldkey][destination_netuid] += carriedLock;
        }
        stakes[hotkey][origin][origin_netuid] -= amount;
        coldkeyAlpha[origin][origin_netuid] -= amount;
        uint256 credited = amount > transferStakeRoundingLoss ? amount - transferStakeRoundingLoss : 0;
        stakes[hotkey][destination_coldkey][destination_netuid] += credited;
        coldkeyAlpha[destination_coldkey][destination_netuid] += credited;
    }

    function setTransferStakeRoundingLoss(uint256 loss) external {
        transferStakeRoundingLoss = loss;
    }

    function setMoveStakeRoundingLoss(uint256 loss) external {
        moveStakeRoundingLoss = loss;
    }

    /// @dev Fault injection: leave alpha at the source despite a successful move call.
    function setMoveStakeResidual(uint256 residual) external {
        moveStakeResidual = residual;
    }

    bool public moveStakeReverts;

    function setMoveStakeReverts(bool v) external {
        moveStakeReverts = v;
    }

    function moveStake(
        bytes32 origin_hotkey,
        bytes32 destination_hotkey,
        uint256 origin_netuid,
        uint256 destination_netuid,
        uint256 amount
    ) external payable {
        if (moveStakeReverts) {
            _fail("MockStaking: moveStake reverted");
        }
        if (!_hasOwnerRecord(origin_hotkey) || !_hasOwnerRecord(destination_hotkey)) {
            _fail("MockStaking: hotkey has no owner");
        }
        if (_belowMinTransfer(amount, origin_netuid)) {
            _fail("MockStaking: AmountTooLow");
        }
        uint256 moved = amount > moveStakeResidual ? amount - moveStakeResidual : 0;
        stakes[origin_hotkey][_senderColdkey()][origin_netuid] -= moved;
        coldkeyAlpha[_senderColdkey()][origin_netuid] -= moved;
        stakes[destination_hotkey][_senderColdkey()][destination_netuid] += moved - moveStakeRoundingLoss;
        coldkeyAlpha[_senderColdkey()][destination_netuid] += moved - moveStakeRoundingLoss;
    }

    function getStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid) external view returns (uint256) {
        return stakes[hotkey][coldkey][netuid];
    }

    /// @dev Models a missing owner record, not deletion of the hotkey identifier or its stake.
    mapping(bytes32 => bool) public hotkeyDeleted;

    function setHotkeyDeleted(bytes32 hotkey, bool deleted) external {
        hotkeyDeleted[hotkey] = deleted;
    }

    /// @dev Seed owner presence separately from balances so tests can model ownerless stake.
    ///      A hotkey without an explicit owner is owned by a coldkey derived from its own name.
    mapping(bytes32 => bool) private _hotkeyOwned;
    mapping(bytes32 => bytes32) private _hotkeyOwner;

    function setHotkeyOwned(bytes32 hotkey, bool owned) external {
        _hotkeyOwned[hotkey] = owned;
    }

    function setHotkeyOwner(bytes32 hotkey, bytes32 coldkey) external {
        _hotkeyOwned[hotkey] = true;
        _hotkeyOwner[hotkey] = coldkey;
        _recordOwnedHotkey(coldkey, hotkey);
    }

    /// @dev Every stake operation the chain accepts touches hotkeys that have an owner record.
    function _hasOwnerRecord(bytes32 hotkey) private view returns (bool) {
        return _hotkeyOwned[hotkey] && !hotkeyDeleted[hotkey];
    }

    /// @dev The owner a hotkey answers with while it has one, ignoring a deleted record.
    function ownerOf(bytes32 hotkey) public view returns (bytes32) {
        bytes32 owner = _hotkeyOwner[hotkey];
        return owner == bytes32(0) ? keccak256(abi.encodePacked("owner:", hotkey)) : owner;
    }

    /// @dev The neuron mock's association: an ownerless hotkey goes to `coldkey`; an owned one stays put.
    function associate(bytes32 hotkey, bytes32 coldkey) external {
        if (_hasOwnerRecord(hotkey)) return;
        hotkeyDeleted[hotkey] = false;
        _hotkeyOwned[hotkey] = true;
        _hotkeyOwner[hotkey] = coldkey;
        _recordOwnedHotkey(coldkey, hotkey);
    }

    function getHotkeyOwner(bytes32 hotkey) external view returns (bool, bytes32) {
        bool exists = _hasOwnerRecord(hotkey);
        return (exists, exists ? ownerOf(hotkey) : bytes32(0));
    }

    mapping(bytes32 => bytes32[]) private _ownedHotkeys;
    mapping(bytes32 => bytes32) private _coldkeyRoot;

    function getOwnedHotkeys(bytes32 coldkey) external view returns (bytes32[] memory) {
        return _ownedHotkeys[coldkey];
    }

    /// @dev The chain holds the owned hotkeys as a set.
    function _recordOwnedHotkey(bytes32 coldkey, bytes32 hotkey) private {
        bytes32[] storage owned = _ownedHotkeys[coldkey];
        for (uint256 i; i < owned.length; ++i) {
            if (owned[i] == hotkey) return;
        }
        owned.push(hotkey);
    }

    function getColdkeyRoot(bytes32 coldkey) external view returns (bool, bytes32) {
        return (_coldkeyRoot[coldkey] != bytes32(0), _coldkeyRoot[coldkey]);
    }

    function setColdkeyRoot(bytes32 coldkey, bytes32 root) external {
        _coldkeyRoot[coldkey] = root;
    }

    /// @dev An incoming coldkey swap narrowed to one subnet. It models the rules a swap runs against the
    ///      destination: the destination is refused when it is itself a hotkey, and refused when it already
    ///      holds stake, which the chain tests across all subnets and this fixture tests on `netuid`. On a
    ///      swap the source's stake, owned hotkeys, locks and accept-locked flag all land on the destination.
    function simulateColdkeySwap(bytes32 source, bytes32 destination, uint256 netuid, bytes32[] calldata hotkeys)
        external
    {
        require(!_hasOwnerRecord(destination), "MockStaking: NewColdKeyIsHotkey");
        require(coldkeyAlpha[destination][netuid] == 0, "MockStaking: ColdKeyAlreadyAssociated");
        for (uint256 i; i < hotkeys.length; ++i) {
            uint256 amount = stakes[hotkeys[i]][source][netuid];
            stakes[hotkeys[i]][source][netuid] = 0;
            stakes[hotkeys[i]][destination][netuid] += amount;
            coldkeyAlpha[source][netuid] -= amount;
            coldkeyAlpha[destination][netuid] += amount;
        }
        lockedAlpha[destination][netuid] = lockedAlpha[source][netuid];
        lockHotkey[destination][netuid] = lockHotkey[source][netuid];
        delete lockedAlpha[source][netuid];
        delete lockHotkey[source][netuid];
        _acceptsLockedAlpha[destination] = _acceptsLockedAlpha[source];
        _coldkeyRoot[destination] = source;
        bytes32[] storage sourceHotkeys = _ownedHotkeys[source];
        for (uint256 i; i < sourceHotkeys.length; ++i) {
            _hotkeyOwner[sourceHotkeys[i]] = destination;
            _recordOwnedHotkey(destination, sourceHotkeys[i]);
        }
        delete _ownedHotkeys[source];
    }

    mapping(bytes32 => mapping(uint256 => bytes32)) private _successor;
    mapping(bytes32 => mapping(uint256 => bool)) private _successorSet;

    function setHotkeySuccessor(bytes32 from, uint256 netuid, bytes32 to) external {
        _successor[from][netuid] = to;
        _successorSet[from][netuid] = true;
    }

    function clearHotkeySuccessor(bytes32 hotkey, uint256 netuid) external {
        delete _successor[hotkey][netuid];
        delete _successorSet[hotkey][netuid];
    }

    function getHotkeySuccessor(bytes32 hotkey, uint16 netuid) external view returns (bool, bytes32) {
        return (_successorSet[hotkey][netuid], _successor[hotkey][netuid]);
    }

    uint256 public taoPerAlpha;
    uint256 public taoPerAlphaDenom;
    bool public removeStakeReverts;
    mapping(bytes32 => bool) public removeStakeRevertsFor;
    uint256 public nominatorMinRequiredStake;
    /// @dev Zero means uncapped.
    uint256 public removeStakeCap;

    function setNominatorMinRequiredStake(uint256 thresholdTao) external {
        nominatorMinRequiredStake = thresholdTao;
    }

    function getNominatorMinRequiredStake() external view returns (uint256) {
        return nominatorMinRequiredStake;
    }

    function setRemoveStakeRate(uint256 num, uint256 denom) external {
        taoPerAlpha = num;
        taoPerAlphaDenom = denom;
    }

    function quoteTaoOut(uint256 alpha) public view returns (uint256) {
        return (alpha * taoPerAlpha) / taoPerAlphaDenom;
    }

    function setRemoveStakeReverts(bool v) external {
        removeStakeReverts = v;
    }

    function setRemoveStakeRevertsFor(bytes32 hotkey, bool v) external {
        removeStakeRevertsFor[hotkey] = v;
    }

    function setRemoveStakeCap(uint256 maxAlpha) external {
        removeStakeCap = maxAlpha;
    }

    function removeStake(bytes32 hotkey, uint256 alphaAmount, uint256 netuid) external payable {
        if (removeStakeReverts || removeStakeRevertsFor[hotkey]) {
            _fail("MockStaking: removeStake reverted");
        }
        if (!_hasOwnerRecord(hotkey)) {
            _fail("MockStaking: hotkey has no owner");
        }
        uint256 staked = stakes[hotkey][_senderColdkey()][netuid];
        uint256 locked = lockedAlpha[_senderColdkey()][netuid];
        uint256 total = coldkeyAlpha[_senderColdkey()][netuid];
        if (alphaAmount > (total > locked ? total - locked : 0)) {
            _fail("MockStaking: StakeUnavailable");
        }
        // Legacy arithmetic fixtures credit one wei per TAO RAO. Native-unit campaigns enable 1e9 below.
        uint256 consumed = removeStakeCap != 0 && alphaAmount > removeStakeCap ? removeStakeCap : alphaAmount;
        uint256 taoOut = quoteTaoOut(consumed);
        if (alphaAmount != staked && quoteTaoOut(alphaAmount) < _chainMinStakeTao) {
            _fail("MockStaking: AmountTooLow");
        }
        uint256 remainder = staked - consumed;
        // A dust remainder is force-sold into this payout; standalone fixtures may omit the alpha mock
        // when the threshold is zero.
        if (remainder != 0 && nominatorMinRequiredStake != 0) {
            if (_belowTaoValue(remainder, netuid, nominatorMinRequiredStake)) {
                taoOut += quoteTaoOut(remainder);
                remainder = 0;
            }
        }
        coldkeyAlpha[_senderColdkey()][netuid] -= staked - remainder;
        stakes[hotkey][_senderColdkey()][netuid] = remainder;
        (bool ok,) = msg.sender.call{ value: nativeTaoUnits ? taoOut * VaultMath.TAO_NATIVE_QUANTUM : taoOut }("");
        require(ok, "MockStaking: TAO credit failed");
    }
}
