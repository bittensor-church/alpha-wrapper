# Backing resolution and the recovery window

The vault holds alpha under its own coldkey, delegated to validator
hotkeys. A validator can swap its hotkey at any time, and the chain
sweeps small stake entries without recording why. Either event moves or
removes the vault's backing without a single vault call. This page
describes what the vault does about that.

## What the vault remembers

Each token carries one compact record per attested validator:

| Field | Meaning |
| --- | --- |
| `logical` | The validator the registry assigns weight to. |
| `active` | The key the vault expects to be holding that validator's alpha. |
| `tracked` | The exact balance the last settling call read under `active`. |
| `shortSince` | When a call first found that balance missing; zero while it is there. |

`logical` and `active` are the same key almost always. They differ only
between a hotkey swap and the moment the attesters name the new key.

Every call that moves alpha ends by rewriting the whole record from the
chain, so `tracked` is a fresh read rather than an accumulated figure.
Comparisons allow `TRACKED_SLACK_RAO` (1000 RAO) of give, because the
chain credits its own transfers, moves and swap migrations a few RAO
short of the amount asked for. That slack is an accepted ceiling on
accounting dust the vault will never chase - not a claim that the chain
preserves exact equality.

## Resolving a slot

For each slot, in order:

1. Read the balance under `active`. If it covers `tracked` within the
   slack, the slot is intact and nothing else is read.
2. Otherwise read exactly one successor edge for `active`.
3. Accept that successor only when all of the following hold:
   - the edge exists and does not point at `active` itself;
   - no other slot already answers for that key;
   - the successor covers `tracked` within the slack; and
   - `active` itself now reads zero.
4. A call that uses the successor records it as the slot's `active`.
   `logical` stays where the attesters put it.

The successor's own successor is never read. A two-hop trail, an erased
edge, an ambiguous or converging swap, and a partial find are all
shortfalls, resolved by a watcher rather than guessed at.

Health is per slot. Growth on one validator never covers a deficit on
another, and the position's value is the sum over the keys the slots
resolve to - never over keys the registry merely names as destinations,
so changing the attested set cannot change the reported backing.

### Why an absent edge proves nothing

The chain drops a hotkey's successor edge as soon as that hotkey is
registered again. A validator can therefore swap away carrying the
vault's alpha, re-register the old key, and leave exactly the state a
dust sweep leaves: a balance gone, and nothing on chain saying where.
The vault does not distinguish them and does not guess between them.

## The recovery window

A slot that cannot account for itself and has no clock yet blocks every
share-pricing and alpha-moving path. It has no deadline, because a call
that reverts leaves no record behind - only a successful call can write
one. Anyone may call `syncBacking(tokenId)`, which moves no alpha and
stamps the moment the vault first saw the loss.

From that stamp the slot has **three hours**. While the window stands:

- `wrap`, `rebalance`, `unwrap` and `unwrapForTao` revert
  `BackingShortfall`.
- On the lens, `totalStake`, `sharePrice`, `previewWrap` and
  `previewUnwrap` revert the same way. `locatedStake`,
  `isBackingIntact` and `frozenUntil` answer throughout.
- ERC-1155 share transfers and `claimTao` stay open: shares and the
  native TAO a holder has already earned belong to the holder whatever
  the alpha is doing.
- Mailbox reclaims stay open: they touch only the caller's own mailbox.

Repeated sightings never move a deadline, and each slot's loss runs its
own clock, so a second loss neither restarts the first nor rides it out.
A slot that accounts for itself again gives its clock up, so a later
identical loss starts from no clock at all.

At the deadline the expectation lapses. Quotes answer again on what the
vault can locate, and the next successful call that moves the position
takes that figure as the new expectation. There is no separate
finalizer.

## Recovering the alpha

`recoverStray(tokenId, slotIndex, sourceHotkey)` moves alpha the vault
already owns back under the key a slot expects it at. Anyone may call
it, and that is safe by construction rather than by permission: only the
subnet clone can stake under its own coldkey, so a balance found there
is already holders' backing, and shifting it between the clone's own
keys cannot take anything out.

- Recovery is **additive**. Several calls can carry fragments home, and
  the slot is whole only once its key covers what it was owed.
- No call moves a deadline, in either direction. Finding the whole
  expectation ends the window; finding part of it does not extend one.
- Drawing on a key another slot answers for is allowed only above that
  slot's own expectation, re-read after the move. One slot's backing can
  never be drained to make another look whole.
- It keeps working after the deadline. Until a settling call anchors the
  record, the slot still knows what it was owed.

Both keys must be usable by the chain. A hotkey nobody owns refuses
every stake operation naming it. Taking ownership of an abandoned hotkey
is open to anyone, costs nothing beyond the fee, and carries no claim on
the stake delegated under it - so a watcher claims the key first, and
the vault itself never owns one.

## What is written off, and who bears it

At the deadline the missing remainder is given up on and the loss falls
across everyone holding shares from that moment. This is a write-off
policy, not a finding that the alpha was destroyed. Alpha found later is
new backing for whoever holds shares then.

That transfer between cohorts is deliberate, and it is not merely
passive drift. Deposits reopen at the deadline while `recoverStray`
keeps working, so whoever knows where the stray alpha sits controls the
order: they can deposit against the written-down price and only then
bring the alpha home, taking most of it from the holders who bore the
loss. The vault does not prevent that. It is the accepted price of a
bounded window, chosen over leaving a token shut indefinitely, and there
is no recapitalization mechanism.

Alpha below the chain's movement floor, and dust a chain operation
rounds away, may stay unrecovered and be socialized the same way.

## What a watcher does

The design assumes someone is watching every vault. Their job:

1. Call `syncBacking` promptly on any token reporting itself short, so
   the clock starts.
2. Take ownership of any funded hotkey the chain has abandoned, so the
   alpha under it can move again.
3. Find where the alpha went - deeper swap trails and erased lineage are
   resolved off chain - and call `recoverStray` with the key holding it.

`frozenUntil(tokenId)` reports the deadline: zero when nothing is
missing, `type(uint256).max` when a loss is visible but has no clock
yet, and a timestamp otherwise.

## Deposits

A hotkey swap carries a waiting mailbox deposit along with everyone
else's stake, so `wrap` looks under the chosen validator's key and, if
that is empty, under its single direct successor. Nothing reads a second
edge. A deposit further down a trail comes back through
`reclaimAlphaFromMailbox` and is staked again.

A deposit is refused before the mailbox is flushed whenever the position
is short, so fresh money never recapitalizes a standing loss and then
gets priced against it.
