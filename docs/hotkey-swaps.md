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

## An emptied slot after a swap

Suppose the registry names A and the vault holds 100 alpha there:

1. A swaps to B across all subnets. The 100 alpha moves to B; A loses its owner record.
2. The vault follows the swap and records B as the actual stake location.
3. An exit empties that slot. The next allocation for A goes to B, because B is
   the key A's owner holds.

For an empty slot the vault prefers the attested name, then the recorded key,
then that key's one-hop successor, each only while the attested owner holds it,
subject to collision checks. Funded slots stay at their resolved location.

## Automatic handling has limits

The record keeps an attested name (`logical`), actual stake location (`active`)
and expected alpha (`tracked`). One shortfall clock covers the whole token.

The resolver follows at most one hop from each recorded active key, only when
the successor covers that slot's expectation within 1000 RAO of accounting slack.
It never counts one key for two slots. Separately observed swaps can advance the
record repeatedly: any priced operation, and a `syncBacking` call on a position
that accounts for itself, writes a followed swap into the record. Two
unobserved swaps, an erased edge or a collision need a watcher. Subnet re-registration can erase lineage; owner association is a
different operation and does not re-register the key.

## Who a name answers to

The registry records the coldkey that owned each hotkey when it was attested. A
receiving key is usable only under that coldkey: the attested name itself, the
recorded active key, or its one-hop successor, whichever the attested owner
holds. A validator's own rename keeps its coldkey, so its successor qualifies. A
vacated name claimed by anyone else reports `AttestedHotkeyRetired` and receives
nothing; the attesters retire it by publishing a set without it.

The chain refuses to move stake through a hotkey with no owner record. When the
vault has to move stake off such a key, it claims the key for its own coldkey
first, then moves. That claim serves the move and is permanent; it does not
make the key an attested destination. A validator's coldkey swap changes the
owner of its hotkeys, and the attesters confirm the new owner by publishing
again.

## The parking hotkey

At deployment the vault claims one hotkey for its own coldkey, the parking
hotkey. Nobody else can rename it, rename into it, or claim it. Every recovery
and every write-off gathers located backing onto that hotkey when a balance
clears the conservative movement floor. Otherwise sub-floor balances may stay
behind without delaying the fixed window. Completion collapses the record to
parking; abandoned dust needs explicit `recoverStray` sources later. The position
is then parked:

- Deposits and weight alignment wait for an attestation newer than the one in
  force when the position parked.
- Alpha exits pay from the parking hotkey; the alpha arrives delegated to it and
  the holder moves it to a validator with their own `moveStake`.
- TAO exits sell from the parking hotkey. Share transfers and TAO claims work.
- Nothing on the parking hotkey earns emissions until the position is released.

One parking hotkey serves every subnet. The chain keys stake by hotkey, coldkey
and subnet, and each subnet's position rests under its own clone coldkey, so
parking one subnet moves nothing of another's and each position is released by
its own attesters.

The first wrap, rebalance or alpha exit after a newer attestation rolls the
parked alpha onto the attested set, aligns it and clears the parked state.
Re-publishing the same set under a new nonce releases a position whose lost
name was already replaced or never mattered.

## Two independent recovery jobs

| Problem | Meaning | Repair |
| --- | --- | --- |
| Name answers to the wrong coldkey | The attested name, its recorded key and its successor are all unusable. | Attesters publish a set without the name, or the attested owner reclaims it. |
| Missing backing | The vault cannot locate enough alpha to satisfy its record. | Park it with `recoverStray`, or let `syncBacking` write off the difference after the window. |

They can occur together. `isBackingIntact() == true` does not prove an exit can
execute. An attested entry that answers to a stranger blocks allocation without
any shortfall or recovery clock.

## Watcher runbook

1. Monitor current registry entries, recorded/resolved stake keys, backing
   status and `awaitingAttestation`. Include empty entries and newly attested
   keys with no recorded slot.
2. For missing backing, call `syncBacking(tokenId)`. It secures all located
   backing on `parkingHotkey` before starting one fixed recovery window, except
   below-floor piles. Other collection failures revert without changing the clock
   or obligation.
3. Locate more alpha under the clone's coldkey and call
   `recoverStray(tokenId, sources)`. Partial finds park immediately and reduce
   the pooled deficit; no validator association is needed. Recovery can also
   start before an explicit sync. `missingStake(tokenId)` reports unlocated alpha; it excludes located dust
   that may also be written off if it cannot be parked.
4. While recovery is open, priced operations refuse. Further syncs collect
   returns at recorded locations. Partial recovery never extends the deadline.
   At expiry, sync collects returns before writing off the remaining deficit.
   Full recovery or write-off leaves the position parked. Alpha recovered later
   belongs to the holders at that time.
5. After completion, attesters publish a newer set even if all backing returned.
   Remove any lost or captured name, naming the intended successor. The next wrap or `rebalance(netuid)` releases the
   parked position onto it.

`recoverStray` never edits the registry and cannot pay the caller from vault
funds. Partial collection emits `BackingRecovered`; completion emits
`BackingParked`. A write-off emits `BackingWrittenOff` before it. Both calls
are permissionless.

## Exit behavior and accepted tradeoffs

If an attested entry has no usable receiving key, `AttestedHotkeyRetired`
blocks wraps, rebalances and partial alpha exits. The guard is conservative: it
applies even if that entry's rebalance move would be too small to execute. A
full-supply alpha exit may proceed. "Full supply" means all outstanding shares,
not merely one holder's balance.

`unwrapForTao` ignores registry weights and sells from recorded keys, including
the parking hotkey. It still needs intact backing, an executable pool sale and
an acceptable payout. Partial sales face post-fee minimums and dust protections.

On a live subnet, a shortfall blocks wraps, rebalances, both exits and value
quotes until the position parks or the loss is written off. Share transfers,
claimable TAO and mailbox recovery do not depend on that backing check.

A parked position pays exits but takes no deposits and earns nothing until the
attesters publish again. Any validator in the set can force a parking event by
renaming its key and cutting the trail; the cost to holders is emissions until
the next attestation lands.

A revert preserves shares and stake, but costs gas. A finalized write-off really
reduces holders' accounted backing; alpha recovered later belongs to holders at
recovery time. Watcher and attester availability are therefore liveness
dependencies, and recovery before write-off matters financially. See the
[late-recovery risk](security-model.md#recovery-window-tradeoff-and-late-recovery-attack).
