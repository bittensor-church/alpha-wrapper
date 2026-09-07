# Hotkey swaps and recovery

The design uses automatic one-hop swap handling plus an external watcher.
Temporary wrap/exit failures while the watcher repairs chain state are accepted.
It does not promise every holder an immediate exit under every chain condition.

## What changes in a swap

A hotkey is an identifier. It does not disappear when Subtensor removes its
**owner record**. That record associates it with a coldkey and is required for
stake operations. It is separate from ownership of delegated alpha: the vault's
alpha stays under the vault clone's coldkey.

An all-subnet swap removes the old hotkey's owner record; a per-subnet swap
retains it. A swap can move stake to the successor or leave it under the old key.
In these docs, “ownerless” means the record is absent, not that the identifier
or its stake no longer exists.

## The problem fixed by PR #69

Suppose the registry names A and the vault holds 100 alpha there:

1. A swaps to B across all subnets. The 100 alpha moves to B; A loses its owner record.
2. The vault follows the swap and records B as the actual stake location.
3. An exit empties that slot. Previously, the vault then selected A to receive
   its next allocation. The chain rejected that move, although B was usable.

The fix keeps an owned receiving key after a drain. For an empty slot it prefers
the attested name if owned, then the recorded key, then that key's one-hop
successor, subject to collision checks. Funded slots stay at their resolved location.

This avoids an unnecessary watcher repair and gas-consuming chain rejection.
Under the watcher model, the original failure was recoverable by restoring A's
owner record or replacing A in the registry; it was not, by itself, theft or
permanent loss of the backing.

## Automatic handling has limits

The record keeps an attested name (`logical`), actual stake location (`active`),
expected alpha (`tracked`) and shortfall clock (`shortSince`).

The resolver follows at most one hop from each recorded active key, only when
the successor covers that slot's expectation within 1000 RAO of accounting slack.
It never counts one key for two slots. Separately observed swaps can advance the
record repeatedly; two unobserved swaps, an erased edge or a collision may need
a watcher. Subnet re-registration can erase lineage; owner association is a
different operation and does not re-register the key.

## Two independent recovery jobs

| Problem | Meaning | Repair |
| --- | --- | --- |
| Missing owner record | A required source or receiving key cannot be used, even if all alpha is located. | Associate the ownerless key; attesters can also replace an unusable receiving entry. |
| Missing backing | The vault cannot locate enough alpha to satisfy its record. | Recover the alpha, or explicitly finalize a write-off after the recovery window. |

They can occur together. `isBackingIntact() == true` does not prove an exit can
execute. An empty ownerless registry entry can block allocation without any
shortfall or recovery clock.

## Watcher runbook

1. Monitor current registry entries, recorded/resolved stake keys and backing
   status. Include empty entries and newly attested keys with no recorded slot.
2. For an ownerless key needed by a stake operation, call Subtensor's
   `try_associate_hotkey`. From EVM, check `getHotkeyOwner(bytes32)` on the staking
   precompile at `0x0805`, then use `tryAssociateHotkey(bytes32)` at `0x0804`.
   Association costs transaction fees and grants no ownership of the vault's
   delegated stake. Retain the claiming account: it controls later hotkey swaps,
   which could otherwise strand the position again.
3. For missing backing, call `syncBacking(tokenId)` to start its clock and locate
   the stake under the clone's coldkey using chain history. Call
   `recoverStray(tokenId, sourceHotkey)` before write-off where possible. The source
   plus located balance must cover a short slot; both move endpoints need owners
   and the move must satisfy chain minimums. Recovery can also happen before a clock starts.
4. If backing remains missing, a further `syncBacking` after the slot's
   `recoveryWindow` writes it down. Time passing alone does nothing. This removes
   that accounting restriction, not ownership or registry restrictions.
5. Attesters should replace old names with the intended successors, dropping the
   old entry in the same update. Resolve collisions before retrying allocation.

`recoverStray` neither creates owner records nor edits the registry. Both recovery
calls are permissionless and cannot pay the caller from vault funds.

A stray key can hold backing merged from several slots. Recovery moves the whole
find once, then reassigns other short slots' expectations to the measured surplus
at the receiving slot. Each alpha is counted once, without splitting the find
into potentially sub-minimum transfers. Any remaining shortage keeps its original
clock. Recovery also saves all resolved keys so a reduced expectation cannot
take a successor already covering another slot. Recovery emits `BackingRecovered`;
surplus beyond all shortages becomes new backing.

## Exit behavior and accepted tradeoffs

If an empty attested entry has no owned receiving key, `AttestedHotkeyRetired`
blocks wraps, rebalances and partial alpha exits with positive backing. The guard
is conservative: it applies even if that entry's rebalance move would be too small
to execute. A full-supply alpha exit may proceed, but is also blocked if any
recorded stake must first be consolidated from dropped validators. “Full supply”
means all outstanding shares, not merely one holder's balance.

`unwrapForTao` ignores registry weights and sells from recorded/resolved keys.
It avoids receiving-key allocation, but still needs usable source keys, intact
backing, an executable pool sale and an acceptable payout. Partial sales face
post-fee minimums and dust protections. Neither exit is unconditional.

On a live subnet, an unresolved backing shortfall blocks wraps, rebalances,
both exits and value quotes until recovery or explicit write-off. Share transfers,
claimable TAO and mailbox recovery do not depend on that backing check.

A revert preserves shares and stake, but costs gas. A finalized write-off really
reduces holders' accounted backing; alpha recovered later belongs to holders at
recovery time. Watcher availability is therefore a liveness dependency, and
recovery before write-off matters financially. See the
[late-recovery risk](security-model.md#recovery-window-tradeoff-and-late-recovery-attack).
