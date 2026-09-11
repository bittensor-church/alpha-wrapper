// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { VaultMath } from "./VaultMath.sol";
import { VaultReads } from "./VaultReads.sol";
import { IAlpha, ALPHA_PRECOMPILE } from "../interfaces/IAlpha.sol";
import { IStaking, STAKING_PRECOMPILE } from "../interfaces/IStaking.sol";
import { SubnetClone } from "../SubnetClone.sol";
import { CloneBase } from "../CloneBase.sol";
import { INeuron, NEURON_PRECOMPILE } from "../interfaces/INeuron.sol";
import {
    ConsolidationBelowFloor,
    GatherBelowFloor,
    SwappedHotkeyStillAttested,
    LockedDeposit,
    ZeroAmount,
    DepositTooSmall,
    CloneProtectionFailed
} from "../VaultErrors.sol";
import { CloneFactory } from "../CloneFactory.sol";

/// @dev Deployed once and linked into the vault. Stake movement runs by delegatecall, so clones and
///      hotkey association still see the vault as caller and logs still originate from the vault.
///      Callers retain the backing gates, reentrancy guard and accounting; this library writes only the
///      clone records handed to it by storage reference.
library VaultAllocation {
    event Rebalanced(uint256 indexed tokenId, bytes32 indexed fromHotkey, bytes32 indexed toHotkey, uint256 amount);
    event SubnetProxyCreated(uint256 indexed tokenId, address clone);
    event MailboxCreated(address indexed user, uint256 indexed netuid, address mailbox);

    /// @dev Delegatecall keeps the vault as the initializer and the depositor as msg.sender.
    function prepareClones(
        CloneFactory factory,
        mapping(uint256 => address) storage subnetClone,
        mapping(address => mapping(uint256 => address)) storage mailboxes,
        uint256 tokenId,
        uint256 netuid,
        bytes32 uid
    ) external returns (address mailbox, address clone) {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 nid = uint16(netuid);
        VaultReads.requireNotDissolving(nid);
        clone = subnetClone[tokenId];
        if (clone == address(0)) {
            clone = factory.deploySubnetClone(tokenId, nid, uid);
            _initializeClone(clone);
            subnetClone[tokenId] = clone;
            emit SubnetProxyCreated(tokenId, clone);
        }
        mailbox = mailboxes[msg.sender][netuid];
        if (mailbox == address(0)) {
            mailbox = factory.deployMailbox(msg.sender, nid, uid);
            _initializeClone(mailbox);
            mailboxes[msg.sender][netuid] = mailbox;
            emit MailboxCreated(msg.sender, netuid, mailbox);
        }
    }

    function _initializeClone(address clone) private {
        CloneBase(payable(clone)).initialize(address(this));
        bytes32 coldkey = VaultReads.coldkeyOf(clone);
        if (!VaultReads.ownedBy(coldkey, coldkey) || !IStaking(STAKING_PRECOMPILE).getRejectLockedAlpha(coldkey)) {
            revert CloneProtectionFailed(clone);
        }
    }

    function admitDeposit(address userClone, bytes32 chosenHotkey, uint16 nid)
        external
        view
        returns (uint256 totalDeposit, uint256 alphaPriceE18)
    {
        bytes32 mailboxColdkey = VaultReads.coldkeyOf(userClone);
        totalDeposit = IStaking(STAKING_PRECOMPILE).getStake(chosenHotkey, mailboxColdkey, nid);
        if (totalDeposit == 0) revert ZeroAmount();
        alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(nid);
        if (alphaPriceE18 != 0 && _taoValue(totalDeposit, alphaPriceE18) < _minStakeTao()) {
            revert DepositTooSmall();
        }
        if (VaultReads.lockedAlphaOf(mailboxColdkey, nid) != 0) revert LockedDeposit();
    }

    /// @dev Keep funded slots on resolved keys; empty slots need a usable receiving key. A key is usable
    ///      only under the coldkey that owned the attested name, so a vacated name claimed by anyone
    ///      else reports as retired. Keys remain exclusive even for empty slots.
    function assignActives(
        bytes32[] memory logicals,
        bytes32[] memory keys,
        uint256[] memory balances,
        bytes32[] memory currentSet,
        bytes32[] memory owners,
        uint16 netuid
    ) external view returns (bytes32[] memory actives, bytes32 retired) {
        actives = new bytes32[](currentSet.length);
        for (uint256 i; i < currentSet.length;) {
            bytes32 name = currentSet[i];
            bytes32 owner = owners[i];
            uint256 at = VaultMath.indexOf(logicals, name);
            bytes32 key;
            bool live;
            if (at != VaultMath.INDEX_NOT_FOUND && balances[at] != 0) {
                key = keys[at];
                live = VaultReads.ownedBy(key, owner);
            } else if (_keyHeldElsewhere(keys, logicals, currentSet, name, at)) {
                if (at == VaultMath.INDEX_NOT_FOUND) revert SwappedHotkeyStillAttested();
                key = keys[at];
                live = VaultReads.ownedBy(key, owner);
            } else {
                (key, live) = _receivingKey(keys, logicals, currentSet, name, owner, at, netuid);
                if (key != name && VaultMath.contains(actives, key)) revert SwappedHotkeyStillAttested();
            }
            actives[i] = key;
            if (!live && retired == bytes32(0)) retired = name;
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Start at the richest source or destination, letting a fresh deposit carry rotated-out dust.
    function chooseRichestSlot(bytes32[] memory sourceKeys, bytes32[] memory currentSet, bytes32 coldkey, uint16 netuid)
        public
        view
        returns (
            bytes32 richestHotkey,
            uint256 richestBalance,
            uint256[] memory sourceBalances,
            bool hasRotatedOutBalance
        )
    {
        sourceBalances = new uint256[](sourceKeys.length);
        bytes32 richestRotatedOut;
        uint256 richestRotatedOutBalance;
        for (uint256 i; i < sourceBalances.length;) {
            bytes32 candidate = sourceKeys[i];
            if (!VaultMath.contains(currentSet, candidate)) {
                uint256 balance = IStaking(STAKING_PRECOMPILE).getStake(candidate, coldkey, netuid);
                sourceBalances[i] = balance;
                if (balance > richestRotatedOutBalance) {
                    richestRotatedOut = candidate;
                    richestRotatedOutBalance = balance;
                }
            }
            unchecked {
                ++i;
            }
        }
        if (richestRotatedOutBalance == 0) return (currentSet[0], 0, sourceBalances, false);

        hasRotatedOutBalance = true;
        richestHotkey = currentSet[0];
        for (uint256 i; i < currentSet.length;) {
            uint256 balance = IStaking(STAKING_PRECOMPILE).getStake(currentSet[i], coldkey, netuid);
            if (balance > richestBalance) {
                richestHotkey = currentSet[i];
                richestBalance = balance;
            }
            unchecked {
                ++i;
            }
        }
        if (richestRotatedOutBalance > richestBalance) {
            richestHotkey = richestRotatedOut;
            richestBalance = richestRotatedOutBalance;
        }
    }

    /// @dev Unique nonzero sources absent from the record, without balance reads.
    function novelSources(bytes32[] memory keys, bytes32[] memory sources)
        external
        pure
        returns (bytes32[] memory strays)
    {
        bytes32[] memory unique = new bytes32[](sources.length);
        uint256 count;
        for (uint256 i; i < sources.length; ++i) {
            bytes32 source = sources[i];
            if (source != bytes32(0) && !VaultMath.contains(keys, source) && !VaultMath.contains(unique, source)) {
                unique[count++] = source;
            }
        }
        strays = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            strays[i] = unique[i];
        }
    }

    /// @dev A still-attested slot reserves its resolved key even while empty.
    function _keyHeldElsewhere(
        bytes32[] memory keys,
        bytes32[] memory logicals,
        bytes32[] memory currentSet,
        bytes32 key,
        uint256 ownSlot
    ) private pure returns (bool) {
        uint256 holder = VaultMath.indexOf(keys, key);
        if (holder == VaultMath.INDEX_NOT_FOUND || holder == ownSlot) return false;
        return VaultMath.contains(currentSet, logicals[holder]);
    }

    /// @dev Prefer the attested name, then the recorded active key, then its one-hop successor, each
    ///      only under the attested owner. Resume from the record: the name's edge may predate swaps
    ///      already followed.
    function _receivingKey(
        bytes32[] memory keys,
        bytes32[] memory logicals,
        bytes32[] memory currentSet,
        bytes32 name,
        bytes32 owner,
        uint256 ownSlot,
        uint16 netuid
    ) private view returns (bytes32 key, bool live) {
        if (VaultReads.ownedBy(name, owner)) return (name, true);

        key = ownSlot == VaultMath.INDEX_NOT_FOUND ? name : keys[ownSlot];
        live = key != name && VaultReads.ownedBy(key, owner);
        if (!live) {
            bytes32 successor = VaultReads.hotkeySuccessor(key, netuid);
            if (successor != bytes32(0) && VaultReads.ownedBy(successor, owner)) {
                key = successor;
                live = true;
            }
        }
        if (
            key != name
                && (VaultMath.contains(currentSet, key) || _keyHeldElsewhere(keys, logicals, currentSet, key, ownSlot))
        ) {
            revert SwappedHotkeyStillAttested();
        }
    }

    function _alignToWeights(
        uint256 tokenId,
        address clone,
        bytes32[] memory hotkeys,
        uint16[] memory weights,
        uint256[] memory balances,
        uint256 alphaPriceE18
    ) private {
        uint256 total = VaultMath.sumBalances(balances);

        if (weights.length == 1 || total == 0) return;

        uint256 lastIndex = weights.length - 1;
        uint256[] memory targets = new uint256[](weights.length);
        {
            uint256 assigned;
            for (uint256 i; i < lastIndex;) {
                targets[i] = (total * weights[i]) / VaultMath.BPS_BASE;
                assigned += targets[i];
                unchecked {
                    ++i;
                }
            }
            targets[lastIndex] = total - assigned;
        }

        // Each step settles one cached target, so N-1 steps bound the loop.
        // Settlement rereads actual chain balances afterwards.
        uint256 minStakeTao = _minStakeTao();
        for (uint256 round; round < lastIndex;) {
            if (!_rebalanceStep(tokenId, clone, hotkeys, balances, targets, alphaPriceE18, minStakeTao)) break;
            unchecked {
                ++round;
            }
        }
    }

    function _rebalanceStep(
        uint256 tokenId,
        address clone,
        bytes32[] memory hotkeys,
        uint256[] memory balances,
        uint256[] memory targets,
        uint256 alphaPriceE18,
        uint256 minStakeTao
    ) private returns (bool) {
        uint256 overIndex;
        uint256 maxOver;
        uint256 underIndex;
        uint256 maxUnder;
        for (uint256 i; i < balances.length;) {
            if (balances[i] > targets[i]) {
                uint256 over = balances[i] - targets[i];
                if (over > maxOver) {
                    maxOver = over;
                    overIndex = i;
                }
            } else if (balances[i] < targets[i]) {
                uint256 under = targets[i] - balances[i];
                if (under > maxUnder) {
                    maxUnder = under;
                    underIndex = i;
                }
            }
            unchecked {
                ++i;
            }
        }

        if (maxOver == 0 || maxUnder == 0) return false;

        uint256 moveAmount = maxOver < maxUnder ? maxOver : maxUnder;
        // A rejected precompile call consumes forwarded gas. Skip unproven moves and tolerate weight drift.
        if (alphaPriceE18 == 0 || _taoValue(moveAmount, alphaPriceE18) < minStakeTao) return false;
        _move(clone, hotkeys[overIndex], hotkeys[underIndex], VaultMath.netuidOf(tokenId), moveAmount);
        emit Rebalanced(tokenId, hotkeys[overIndex], hotkeys[underIndex], moveAmount);
        balances[overIndex] -= moveAmount;
        balances[underIndex] += moveAmount;
        return true;
    }

    /// @dev Move all dropped-key backing onto tracked destinations before rewriting the record.
    ///      Recovery may leave a below-floor pile in place; other callers refuse it.
    /// @return leftBelowFloor True only when the richest source/destination is below the conservative floor.
    function consolidateRotatedStake(
        address clone,
        bytes32 coldkey,
        uint16 netuid,
        bytes32[] memory sourceKeys,
        bytes32[] memory currentSet,
        uint256 alphaPriceE18,
        bool leaveUnmovable
    ) external returns (bool leftBelowFloor) {
        if (!_anyRotatedOut(sourceKeys, currentSet)) return false;
        (bytes32 rollerHotkey, uint256 richestBalance, uint256[] memory sourceBalances, bool hasRotatedOutBalance) =
            chooseRichestSlot(sourceKeys, currentSet, coldkey, netuid);
        if (!hasRotatedOutBalance) return false;
        // The pile starts at the largest balance and only grows, up to rounding on each move,
        // so its starting size bounds every hop to within that rounding.
        if (_isBelowFloorAtAnyPrice(richestBalance, alphaPriceE18)) {
            if (leaveUnmovable) return true;
            revert ConsolidationBelowFloor();
        }
        _rollRotatedStake(clone, coldkey, netuid, sourceKeys, currentSet, rollerHotkey, sourceBalances);
        return false;
    }

    /// @dev Never revisit the starting key: its cached balance is stale once the pile leaves.
    function _rollRotatedStake(
        address clone,
        bytes32 coldkey,
        uint16 netuid,
        bytes32[] memory sourceKeys,
        bytes32[] memory currentSet,
        bytes32 rollerHotkey,
        uint256[] memory sourceBalances
    ) private {
        bytes32 richestHotkey = rollerHotkey;
        for (uint256 i; i < sourceBalances.length;) {
            bytes32 sourceHotkey = sourceKeys[i];
            if (sourceHotkey != richestHotkey && _isRotatedOut(sourceHotkey, currentSet) && sourceBalances[i] > 0) {
                // Read the live pile; summing earlier credits would over-ask after chain rounding.
                uint256 pile = IStaking(STAKING_PRECOMPILE).getStake(rollerHotkey, coldkey, netuid);
                _move(clone, rollerHotkey, sourceHotkey, netuid, pile);
                rollerHotkey = sourceHotkey;
            }
            unchecked {
                ++i;
            }
        }
        if (_isRotatedOut(rollerHotkey, currentSet)) {
            uint256 pile = IStaking(STAKING_PRECOMPILE).getStake(rollerHotkey, coldkey, netuid);
            _move(clone, rollerHotkey, currentSet[0], netuid, pile);
        }
    }

    function _anyRotatedOut(bytes32[] memory hotkeys, bytes32[] memory currentSet) private pure returns (bool) {
        for (uint256 i; i < hotkeys.length;) {
            if (_isRotatedOut(hotkeys[i], currentSet)) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /// @dev Fetch current backing before weight alignment. Runs inside the vault's reentrancy guard.
    function rebalance(
        uint256 tokenId,
        address clone,
        bytes32[] memory hotkeys,
        uint16[] memory weights,
        bytes32 coldkey,
        uint256 alphaPriceE18
    ) external {
        uint256[] memory balances = VaultReads.fetchBalances(hotkeys, coldkey, VaultMath.netuidOf(tokenId));
        _alignToWeights(tokenId, clone, hotkeys, weights, balances, alphaPriceE18);
    }

    /// @dev Gather an alpha payout, measure recipient credit, then align the remainder. The vault
    ///      checks slippage and settles its record after this returns; failures revert all stake moves.
    function deliverAndAlign(
        uint256 tokenId,
        address clone,
        bytes32[] memory hotkeys,
        uint16[] memory weights,
        uint256[] memory balances,
        bytes32 coldkey,
        bytes32 userColdkey,
        uint256 assets,
        uint256 alphaPriceE18
    ) external returns (uint256 alphaOut) {
        uint16 netuid = VaultMath.netuidOf(tokenId);
        uint256 deliveryIndex;
        for (uint256 i = 1; i < balances.length;) {
            if (balances[i] > balances[deliveryIndex]) deliveryIndex = i;
            unchecked {
                ++i;
            }
        }
        // Gather hops can round down, so summed balances cannot determine the final deliverable amount.
        uint256 deliverable = balances[deliveryIndex];
        if (balances[deliveryIndex] < assets) {
            // Start with the largest slot; reject an unmovable pile before forwarding gas to the chain.
            if (_isBelowFloorAtAnyPrice(balances[deliveryIndex], alphaPriceE18)) {
                revert GatherBelowFloor();
            }
            // Re-read every hop: requesting a cached sum can exceed the balance after chain rounding.
            for (uint256 i; i < balances.length && balances[deliveryIndex] < assets;) {
                if (i != deliveryIndex && balances[i] != 0) {
                    uint256 pile = IStaking(STAKING_PRECOMPILE).getStake(hotkeys[deliveryIndex], coldkey, netuid);
                    _move(clone, hotkeys[deliveryIndex], hotkeys[i], netuid, pile);
                    balances[i] += balances[deliveryIndex];
                    balances[deliveryIndex] = 0;
                    deliveryIndex = i;
                }
                unchecked {
                    ++i;
                }
            }
            deliverable = IStaking(STAKING_PRECOMPILE).getStake(hotkeys[deliveryIndex], coldkey, netuid);
        }
        uint256 requested = assets < deliverable ? assets : deliverable;
        alphaOut = _flushMeasured(clone, hotkeys[deliveryIndex], userColdkey, netuid, requested);
        // Chain rounding also changes the balances available to rebalance.
        uint256[] memory postBalances = VaultReads.fetchBalances(hotkeys, coldkey, netuid);
        _alignToWeights(tokenId, clone, hotkeys, weights, postBalances, alphaPriceE18);
    }

    /// @dev Bound slippage against actual recipient credit, including chain-side stake-share rounding.
    function _flushMeasured(address clone, bytes32 hotkey, bytes32 userColdkey, uint16 netuid, uint256 amount)
        private
        returns (uint256)
    {
        uint256 recipientBefore = IStaking(STAKING_PRECOMPILE).getStake(hotkey, userColdkey, netuid);
        _flush(clone, hotkey, userColdkey, netuid, amount);
        uint256 recipientAfter = IStaking(STAKING_PRECOMPILE).getStake(hotkey, userColdkey, netuid);
        return recipientAfter > recipientBefore ? recipientAfter - recipientBefore : 0;
    }

    /// @dev Reject only if the amount is below the floor even at the upper bound hidden by price rounding.
    function _isBelowFloorAtAnyPrice(uint256 alphaAmount, uint256 alphaPriceE18) private view returns (bool) {
        return alphaPriceE18 != 0
            && _taoValue(alphaAmount, alphaPriceE18 + VaultMath.ALPHA_PRICE_QUANTUM_E18) < _minStakeTao();
    }

    function _taoValue(uint256 alphaAmount, uint256 alphaPriceE18) private pure returns (uint256) {
        return (alphaAmount * alphaPriceE18) / VaultMath.ALPHA_PRICE_SCALE;
    }

    /// @dev The only exposed minimum is for unstakes; using it for transfers/moves is conservative.
    function _minStakeTao() private view returns (uint256) {
        return IStaking(STAKING_PRECOMPILE).getDefaultMinStake();
    }

    function _hasOwner(bytes32 hotkey) private view returns (bool exists) {
        (exists,) = IStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkey);
    }

    /// @dev The chain refuses to move stake through a hotkey with no owner record; claim one for the vault.
    function _ensureOwned(bytes32 hotkey) private {
        if (!_hasOwner(hotkey)) INeuron(NEURON_PRECOMPILE).tryAssociateHotkey(hotkey);
    }

    function _move(address clone, bytes32 fromHotkey, bytes32 toHotkey, uint16 netuid, uint256 amount) private {
        _ensureOwned(fromHotkey);
        _ensureOwned(toHotkey);
        SubnetClone(payable(clone)).moveStake(fromHotkey, toHotkey, netuid, amount);
    }

    function _isRotatedOut(bytes32 hotkey, bytes32[] memory currentSet) private pure returns (bool) {
        return !VaultMath.contains(currentSet, hotkey);
    }

    function _flush(address holder, bytes32 hotkey, bytes32 destColdkey, uint16 netuid, uint256 amount) private {
        _ensureOwned(hotkey);
        CloneBase(payable(holder)).flush(destColdkey, hotkey, netuid, amount);
    }
}
