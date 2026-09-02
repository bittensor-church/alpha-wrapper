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
edge, an ambiguous or converging swap, and a successor that cannot cover
the slot are all shortfalls, resolved by a watcher rather than guessed
at.

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

From that stamp the slot has the vault's **recovery window** - a
duration fixed at deployment, reported by the vault's `recoveryWindow`.
Until the loss is booked:

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

At the deadline the expectation may be given up on - by another call to
`syncBacking`, and only by that. Nothing else books a loss: an ordinary
deposit, exit or rebalance keeps refusing past the deadline, so no user
operation ever writes value off as a side effect, and a watcher's
transaction is what reopens the token. From then on quotes answer on what
the vault can locate.

## Recovering the alpha

`recoverStray(tokenId, sourceHotkey)` moves alpha the vault already
owns back under the key of the slot it makes whole. Anyone may call
it, and that is safe by construction rather than by permission: only the
subnet clone can stake under its own coldkey, so a balance found there
is already holders' backing, and shifting it between the clone's own
keys cannot take anything out.

- Recovery is **whole**. The chain moves stake entries whole - a swap
  migrates the full balance, a sweep removes an entire entry - so what a
  slot lost sits under exactly one key. The vault aims the find at the
  short slot with the largest expectation it covers; a source that
  covers none is not where the backing went, and the call refuses it.
- Finding the expectation makes the slot whole and ends its window. No
  call moves a deadline in either direction.
- A key any slot already resolves to is refused, whatever it holds above
  that slot's expectation. Backing that is already accounted for is not
  stray: one slot is never recapitalized out of another, and a surplus
  counts toward the total where it sits.
- It keeps working after the deadline. Until a settling call anchors the
  record, the slot still knows what it was owed.

Both keys must be usable by the chain. A hotkey nobody owns refuses
every stake operation naming it. Taking ownership of an abandoned hotkey
is open to anyone, costs nothing beyond the fee, and carries no claim on
the stake delegated under it - so a watcher associates the key first,
and the vault itself never owns one.

Association is not subnet registration. A watcher submits
`try_associate_hotkey(hotkey)` as a native Subtensor extrinsic (or
`tryAssociateHotkey(bytes32)` through the neuron precompile at `0x0804`).
That restores the global `Owner` entry checked by stake operations; the
abandoned key does not need a UID or renewed subnet membership. The staking
precompile's `getHotkeyOwner(bytes32)` reader at `0x0805` distinguishes an
ownerless key from an associated one.

The first successful claimant becomes the owner. That ownership does not let
the claimant spend stake delegated by the vault clone, because the stake still
belongs to the clone's coldkey. It does let the claimant initiate another
hotkey swap, however, which can strand the key again or move the stake farther
down its lineage. Association is therefore an operational liveness recovery,
not a permanent on-chain repair: watchers should claim promptly, retain the
claiming key, and continue monitoring the slot until holders have exited or the
backing has moved to a stable key.

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

### Deliberate swap-hide-deposit-recover ordering

A dishonest validator can manufacture that ordering rather than merely
benefit from an accidental late find:

1. Its attested hotkey carries some of the vault's alpha. The validator
   swaps to a successor, carrying that alpha with it, and then registers
   the old hotkey again. Subtensor removes the successor edge, so the
   vault sees the old key empty but can no longer discover the funded
   successor on chain.
2. If no watcher independently finds the successor before the recovery
   window expires, anyone - including the validator - can finalize the
   write-off with `syncBacking`.
3. The validator or a collaborator deposits after the token reopens and
   receives shares priced only against the backing the vault can still
   locate. A complete write-off can make this depositor the dominant
   holder for a comparatively small valid deposit.
4. The validator reveals the funded successor and calls `recoverStray`,
   or lets another caller do so. The returned alpha belongs pro rata to
   the post-deposit share supply, so the new shares capture most of it.

For a hidden balance that has not grown, this does **not** charge the old
cohort for the same principal twice or expose backing that remained
located. If `H` is the amount finalized as missing, the old cohort's
aggregate reduction between its pre-loss claim and its post-recovery
claim is at most `H`; as the new depositor's share of supply approaches
100%, the reduction approaches `H`. The attack changes who receives the
late `H` rather than extracting an additional `H` from the vault.

The `BackingWrittenOff` event is not necessarily a cap on the eventual
windfall. A hidden position can earn emissions, or the recovered source
can contain a surplus, after the vault last anchored its expectation.
`recoverStray` anchors the whole amount it actually moves, and all of
that amount accrues to the holders at recovery time. The principal bound
above therefore assumes the recovered source has not grown; any growth
while hidden is a separate transfer to the later cohort.

Naming the funded successor in a later validator attestation is not a
retroactive recovery for the cohort that bore the loss. Before write-off,
the unresolved record still freezes share-pricing calls and the stray
must be recovered explicitly. After write-off, a later deposit, exit or
rebalance can adopt that attested key and count the alpha already under
it as backing for the holders at that later time. Once the deadline has
been finalized, neither an attestation nor recovery reconstructs the old
cohort's entitlement.

Alpha below the chain's movement floor, and dust a chain operation
rounds away, may stay unrecovered and be socialized the same way.

## What a watcher does

The design assumes someone is watching every vault. Their job:

1. Call `syncBacking` promptly on any token reporting itself short, so
   the clock starts - and again once the deadline passes, since that call
   is the only thing that books the loss and reopens the token.
2. For any funded hotkey the chain has abandoned, verify
   `getHotkeyOwner(hotkey)` reports no owner and call
   `try_associate_hotkey(hotkey)`. Do not re-register it on the subnet;
   association alone makes the alpha movable again. Retain and monitor the
   claimed key because its owner can swap it again.
3. Find where the alpha went - deeper swap trails and erased lineage are
   resolved off chain - and call `recoverStray` with the key holding it.

`frozenUntil(tokenId)` reports the deadline: zero when nothing is
missing, `type(uint256).max` when a loss is visible but has no clock
yet, and a timestamp otherwise.

## Deposits

`wrap` reads the caller's mailbox under the chosen validator's key and
nowhere else. A hotkey swap carries a waiting mailbox deposit along with
everyone else's stake; the deposit stays the owner's, and it comes back
through `reclaimAlphaFromMailbox` naming the key that holds it, to be
staked again toward a live attested validator and wrapped.

A deposit is refused before the mailbox is flushed whenever the position
is short, so fresh money never recapitalizes a standing loss and then
gets priced against it.
