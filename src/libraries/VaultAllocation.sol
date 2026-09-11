// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { StakeOps } from "./StakeOps.sol";
import { VaultClones } from "./VaultClones.sol";
import { VaultMath } from "./VaultMath.sol";
import { VaultReads } from "./VaultReads.sol";
import { IAlpha, ALPHA_PRECOMPILE } from "../interfaces/IAlpha.sol";
import { IStaking, STAKING_PRECOMPILE } from "../interfaces/IStaking.sol";
import { LockedDeposit, ZeroAmount } from "../VaultErrors.sol";
import { IAlphaVaultAbi } from "../interfaces/IAlphaVaultAbi.sol";
import { CloneFactory } from "../CloneFactory.sol";

/// @dev Deployed once and linked into the vault. Holds clone preparation, deposit admission, the
///      receiving-key rules, consolidation of dropped validators, payout gathering and weight alignment.
///      Stake movement runs by delegatecall, so clones and hotkey association still see the vault as
///      caller and logs still originate from the vault. Callers retain the backing gates, reentrancy
///      guard and accounting; this library writes only the clone records handed to it by storage reference.
library VaultAllocation {
    /// @dev What collection does with a pile the chain would refuse to move.
    enum CollectionPolicy {
        RevertBelowFloor,
        LeaveBelowFloor
    }

    /// @dev One position under one alpha price: the caller reads the price once and every floor test in
    ///      the call uses that read.
    struct Context {
        uint256 tokenId;
        address clone;
        bytes32 coldkey;
        uint16 netuid;
        uint256 alphaPriceE18;
    }

    /// @dev Delegatecall keeps the vault as the initializer and the depositor as msg.sender.
    function prepareClones(
        CloneFactory factory,
        mapping(uint256 => address) storage subnetClone,
        mapping(address => mapping(uint256 => address)) storage mailboxes,
        uint256 tokenId,
        uint256 netuid,
        bytes32 uid
    ) external returns (address mailbox, address clone) {
        return VaultClones.prepareClones(factory, subnetClone, mailboxes, tokenId, netuid, uid);
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
        if (StakeOps.isBelowFloorAtReadPrice(totalDeposit, alphaPriceE18)) {
            revert IAlphaVaultAbi.DepositTooSmall();
        }
        if (VaultReads.lockedAlphaOf(mailboxColdkey, nid) != 0) revert LockedDeposit();
    }

    /// @dev Keep funded slots on resolved keys; empty slots need a usable receiving key. A key is usable
    ///      only under the coldkey that owned the attested name, so a vacated name claimed by anyone
    ///      else reports as retired. Keys remain exclusive even for empty slots.
    function assignActives(
        VaultReads.Slot[] memory slots,
        VaultReads.Backing memory backing,
        VaultReads.ValidatorSet memory set,
        uint16 netuid
    ) external view returns (bytes32[] memory actives, bytes32 retired) {
        bytes32[] memory logicals = VaultReads.logicalsOf(slots);
        bytes32[] memory keys = backing.keys;
        bytes32[] memory currentSet = set.hotkeys;
        actives = new bytes32[](currentSet.length);
        for (uint256 i; i < currentSet.length;) {
            bytes32 name = currentSet[i];
            bytes32 owner = set.owners[i];
            uint256 at = VaultMath.indexOf(logicals, name);
            bytes32 key;
            bool live;
            if (at != VaultMath.INDEX_NOT_FOUND && backing.balances[at] != 0) {
                key = keys[at];
                live = VaultReads.ownedBy(key, owner);
            } else if (_keyHeldElsewhere(keys, logicals, currentSet, name, at)) {
                if (at == VaultMath.INDEX_NOT_FOUND) revert IAlphaVaultAbi.SwappedHotkeyStillAttested();
                key = keys[at];
                live = VaultReads.ownedBy(key, owner);
            } else {
                (key, live) = _receivingKey(keys, logicals, currentSet, name, owner, at, netuid);
                if (key != name && VaultMath.contains(actives, key)) {
                    revert IAlphaVaultAbi.SwappedHotkeyStillAttested();
                }
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
            revert IAlphaVaultAbi.SwappedHotkeyStillAttested();
        }
    }

    function _alignToWeights(
        Context memory context,
        bytes32[] memory hotkeys,
        uint16[] memory weights,
        uint256[] memory balances
    ) private {
        uint256 total = VaultMath.sumBalances(balances);

        // A single slot already holds every unit there is to align.
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
        uint256 minStakeTao = StakeOps.minStakeTao();
        for (uint256 round; round < lastIndex;) {
            if (!_rebalanceStep(context, hotkeys, balances, targets, minStakeTao)) break;
            unchecked {
                ++round;
            }
        }
    }

    function _rebalanceStep(
        Context memory context,
        bytes32[] memory hotkeys,
        uint256[] memory balances,
        uint256[] memory targets,
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
        if (context.alphaPriceE18 == 0 || StakeOps.taoValue(moveAmount, context.alphaPriceE18) < minStakeTao) {
            return false;
        }
        StakeOps.move(context.clone, hotkeys[overIndex], hotkeys[underIndex], context.netuid, moveAmount);
        emit IAlphaVaultAbi.Rebalanced(context.tokenId, hotkeys[overIndex], hotkeys[underIndex], moveAmount);
        balances[overIndex] -= moveAmount;
        balances[underIndex] += moveAmount;
        return true;
    }

    /// @dev Move all dropped-key backing onto tracked destinations before rewriting the record.
    ///      Recovery may leave a below-floor pile in place; other callers refuse it.
    /// @return leftBelowFloor True only when the richest source/destination is below the conservative floor.
    function consolidateRotatedStake(
        Context memory context,
        bytes32[] memory sourceKeys,
        bytes32[] memory currentSet,
        CollectionPolicy policy
    ) external returns (bool leftBelowFloor) {
        if (!_anyRotatedOut(sourceKeys, currentSet)) return false;
        (bytes32 rollerHotkey, uint256 richestBalance, uint256[] memory sourceBalances, bool hasRotatedOutBalance) =
            chooseRichestSlot(sourceKeys, currentSet, context.coldkey, context.netuid);
        if (!hasRotatedOutBalance) return false;
        // The pile starts at the largest balance and only grows, up to rounding on each move,
        // so its starting size bounds every hop to within that rounding.
        if (StakeOps.isBelowFloorAtAnyPrice(richestBalance, context.alphaPriceE18)) {
            if (policy == CollectionPolicy.LeaveBelowFloor) return true;
            revert IAlphaVaultAbi.ConsolidationBelowFloor();
        }
        _rollRotatedStake(context, sourceKeys, currentSet, rollerHotkey, sourceBalances);
        return false;
    }

    /// @dev Never revisit the starting key: its cached balance is stale once the pile leaves.
    function _rollRotatedStake(
        Context memory context,
        bytes32[] memory sourceKeys,
        bytes32[] memory currentSet,
        bytes32 rollerHotkey,
        uint256[] memory sourceBalances
    ) private {
        bytes32 richestHotkey = rollerHotkey;
        bytes32 coldkey = context.coldkey;
        uint16 netuid = context.netuid;
        for (uint256 i; i < sourceBalances.length;) {
            bytes32 sourceHotkey = sourceKeys[i];
            if (sourceHotkey != richestHotkey && !VaultMath.contains(currentSet, sourceHotkey) && sourceBalances[i] > 0)
            {
                // Read the live pile; summing earlier credits would over-ask after chain rounding.
                uint256 pile = IStaking(STAKING_PRECOMPILE).getStake(rollerHotkey, coldkey, netuid);
                StakeOps.move(context.clone, rollerHotkey, sourceHotkey, netuid, pile);
                rollerHotkey = sourceHotkey;
            }
            unchecked {
                ++i;
            }
        }
        if (!VaultMath.contains(currentSet, rollerHotkey)) {
            uint256 pile = IStaking(STAKING_PRECOMPILE).getStake(rollerHotkey, coldkey, netuid);
            StakeOps.move(context.clone, rollerHotkey, currentSet[0], netuid, pile);
        }
    }

    function _anyRotatedOut(bytes32[] memory hotkeys, bytes32[] memory currentSet) private pure returns (bool) {
        for (uint256 i; i < hotkeys.length;) {
            if (!VaultMath.contains(currentSet, hotkeys[i])) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /// @dev Fetch current backing before weight alignment. Runs inside the vault's reentrancy guard.
    function rebalance(Context memory context, bytes32[] memory hotkeys, uint16[] memory weights) external {
        uint256[] memory balances = VaultReads.fetchBalances(hotkeys, context.coldkey, context.netuid);
        _alignToWeights(context, hotkeys, weights, balances);
    }

    /// @dev Gather an alpha payout onto one slot and measure recipient credit, leaving the rest of the
    ///      backing where it lies. The vault checks slippage and settles its record after this returns;
    ///      failures revert all stake moves.
    function deliver(
        Context memory context,
        bytes32[] memory hotkeys,
        uint256[] memory balances,
        bytes32 userColdkey,
        uint256 assets
    ) external returns (uint256 alphaOut) {
        return _gatherAndFlush(context, hotkeys, balances, userColdkey, assets);
    }

    /// @dev `deliver`, then align the remainder to the attested weights.
    function deliverAndAlign(
        Context memory context,
        bytes32[] memory hotkeys,
        uint16[] memory weights,
        uint256[] memory balances,
        bytes32 userColdkey,
        uint256 assets
    ) external returns (uint256 alphaOut) {
        alphaOut = _gatherAndFlush(context, hotkeys, balances, userColdkey, assets);
        // Chain rounding also changes the balances available to rebalance.
        uint256[] memory postBalances = VaultReads.fetchBalances(hotkeys, context.coldkey, context.netuid);
        _alignToWeights(context, hotkeys, weights, postBalances);
    }

    function _gatherAndFlush(
        Context memory context,
        bytes32[] memory hotkeys,
        uint256[] memory balances,
        bytes32 userColdkey,
        uint256 assets
    ) private returns (uint256 alphaOut) {
        bytes32 coldkey = context.coldkey;
        uint16 netuid = context.netuid;
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
            if (StakeOps.isBelowFloorAtAnyPrice(balances[deliveryIndex], context.alphaPriceE18)) {
                revert IAlphaVaultAbi.GatherBelowFloor();
            }
            // Re-read every hop: requesting a cached sum can exceed the balance after chain rounding.
            for (uint256 i; i < balances.length && balances[deliveryIndex] < assets;) {
                if (i != deliveryIndex && balances[i] != 0) {
                    uint256 pile = IStaking(STAKING_PRECOMPILE).getStake(hotkeys[deliveryIndex], coldkey, netuid);
                    StakeOps.move(context.clone, hotkeys[deliveryIndex], hotkeys[i], netuid, pile);
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
        alphaOut = _flushMeasured(context.clone, hotkeys[deliveryIndex], userColdkey, netuid, requested);
    }

    /// @dev Bound slippage against actual recipient credit, including chain-side stake-share rounding.
    function _flushMeasured(address clone, bytes32 hotkey, bytes32 userColdkey, uint16 netuid, uint256 amount)
        private
        returns (uint256)
    {
        uint256 recipientBefore = IStaking(STAKING_PRECOMPILE).getStake(hotkey, userColdkey, netuid);
        StakeOps.flush(clone, hotkey, userColdkey, netuid, amount);
        uint256 recipientAfter = IStaking(STAKING_PRECOMPILE).getStake(hotkey, userColdkey, netuid);
        return recipientAfter > recipientBefore ? recipientAfter - recipientBefore : 0;
    }
}
