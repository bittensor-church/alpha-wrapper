# Edge cases

Events outside the vault's control - dissolution, disabled transfers,
the chain's minimums, dust sweeps, stray TAO - can hit a position at any
time. This page lists them and what the vault does about each.

## Subnet dissolution

Subtensor dissolves subnets asynchronously. Chain-side cleanup burns the
subnet's alpha, converts the pool to TAO and refunds holders pro-rata,
the vault's clone included.

While cleanup runs the vault freezes every share-priced operation on
that netuid; the calls revert with `SubnetInDissolutionBlackoutPeriod`.
Pricing mid-refund would distribute an incomplete amount.

Once cleanup completes the position is permanently dissolved: the
netuid's current registration block differs from the token id's. From
then on `unwrap` pays native TAO pro-rata from the clone's refund
balance. On the lens, `previewUnwrap` quotes that payout while
`sharePrice` and `previewWrap` revert with `SubnetDissolved`. Both payouts start once the
refund sits on the clone: until it arrives - or while all of the clone's
TAO is reserved for claims - `unwrap` reverts `NothingToUnwrap` and
`previewUnwrap` reverts `SubnetDissolved`. `claimTao` works throughout.

The blackout is scoped by netuid because the chain reports dissolution
by netuid alone. An old, already-dissolved
position on a reused netuid is therefore also frozen while its successor
dissolves, and resumes when that cleanup completes. This is a deliberate
availability tradeoff.

A dissolution refund can also land on your deposit mailbox if stake was
still parked there; `reclaimTaoFromMailbox(netuid)` recovers it.

## Subnet owner disables alpha transfers

A subnet owner can turn off alpha transfers at any time. Wrapping, the
alpha exit and `reclaimAlphaFromMailbox` all transfer stake between
coldkeys, so all three revert on such a subnet, with shares and mailbox
balances intact. The TAO paths (`unwrapForTao`,
`reclaimMailboxAlphaAsTao`) unstake rather than transfer and keep
working.

## The chain's minimum stake size

Subtensor rejects stake operations below TAO-denominated minimums: a
higher one for unstakes, a lower one for transfers and moves. Its
rejection burns all gas sent with the call, and the only minimum
readable on the EVM is the higher one, so the vault applies that as one
conservative floor to every operation - it can refuse a deposit the
chain itself would still move. When the subnet's alpha price is
readable, the vault checks sizes before calling the chain; at a zero
price read the call goes straight to the chain, and a too-small one
fails there at full gas. The checks:

- A deposit under the floor reverts `DepositTooSmall`; top the mailbox
  up and wrap once.
- An alpha-exit request under the floor reverts `WithdrawTooSmall`,
  and the related guards (`GatherBelowFloor`, `ConsolidationBelowFloor`)
  refuse internal moves that are provably below it.
- A rebalance move under the floor is silently skipped. The split
  drifts from target until a later operation produces a movable amount;
  share value is unaffected because it depends on the total alone.

Every position keeps an exit. A burn of the token's entire supply via
`unwrapForTao` is exempt from the floor, so the last holder can always
sell - at worst the pool fills short and hands part back as shares for
another try. A sub-floor position with co-holders takes one top-up
deposit first, then exits the same way.

## The chain's dust sweep

After a partial unstake, the chain force-sells any stake entry left below
a dust threshold, folding the proceeds into that unstake's payout. A
partial `unwrapForTao` is sized to keep the remaining holders' backing
whole: the vault will not sell a chunk whose leftover the chain would
sweep, and sells less, or nothing, from that slot instead. Whatever
stays staked comes back to the caller as shares, except
on a burn of the entire supply, which drops a leftover below the chain's
minimum.

## A validator swaps its hotkey

A validator can move its identity to a new hotkey at any time, carrying
the vault's alpha with it. The vault reads the chain's own successor
edge and follows it one hop, so the ordinary swap resolves itself on the
next call and holders never notice.

One hop is all it reads. A validator that swapped twice before the vault
looked, an edge the chain has since dropped, or two swaps converging on
one key all leave backing the vault cannot account for.
So does the chain's dust sweep, which records nothing at all - and a
swap looks exactly like it once the old key is registered again and the
edge disappears, so the vault does not guess between them.

Backing that cannot be accounted for shuts the token for the vault's
**recovery window** (fixed at deployment; `recoveryWindow` reports it)
from the moment a call records it. `wrap`, `rebalance`, `unwrap`,
`unwrapForTao` and every value quote (`totalStake`, `sharePrice`,
`previewWrap`, `previewUnwrap`) revert `BackingShortfall`. The watch
surface (`locatedStake`, `isBackingIntact`, `frozenUntil`),
`claimableTaoOf`, share transfers, `claimTao` and the mailbox reclaims
stay open throughout.

Anyone can act inside the window. `syncBacking(tokenId)` starts the
clock and moves no alpha; `recoverStray(tokenId, slotIndex, sourceHotkey)`
carries the found alpha back under the key its slot expects. The chain
moves stake entries whole, so the loss sits under one key and one
successful call brings it all home; a source that cannot cover it is
refused. Neither call needs a signature or a quorum, because the alpha
in question already sits under the vault's own coldkey.

Whatever is still missing at the deadline is written off by a further
`syncBacking` call - nothing else books it, so no deposit or exit gives up
on backing as a side effect. The token then reopens valued at what it can
find, and the loss falls across everyone holding shares at that moment. Alpha found afterwards is new backing for
whoever holds shares then. Both halves of that are deliberate - the
alternative is a token that stays shut indefinitely. The full account is
in [design/backing-resolution.md](design/backing-resolution.md).

## A hotkey nobody owns

A hotkey swap that keeps its stake leaves the vault's alpha under a key
the chain no longer records an owner for. The record still finds it, so
nothing is missing and no window opens - but the chain refuses every
stake operation naming that key, so the alpha cannot move.

Taking ownership of an abandoned hotkey is open to anyone, costs nothing
beyond the transaction fee, and gives the claimant no claim on the stake
delegated under it. Once someone claims it, exits go through again. The
vault never owns a hotkey itself.

## Stray TAO

Native TAO can arrive on a clone outside any exit: the chain force-sold
dust into it, or someone simply sent TAO there. Folding it into the share
price would gift it to future depositors, so it is instead credited
pro-rata to the holders of the token at the moment the arrival is
recorded, through a cumulative per-share index. Recording happens at the
next balance change or claim on that token. `claimableTaoOf` and
`claimTao` pay it out. The fine print:

- Claims pay in whole native quantums - the chain moves TAO in 1e9-wei
  steps - and the sub-quantum remainder stays reserved for you.
- Entitlements survive transfers and full exits.
- TAO arriving at zero share supply stays unassigned until shares
  exist again. TAO arriving during or after dissolution is refund
  backing and goes through the dissolved unwrap instead.

## Validator rotation leftovers

When the registry drops a validator, the vault must roll its stake onto
the current set, and the chain's minimum can block that roll for a dust
position. At a readable price the call refuses cheaply with
`ConsolidationBelowFloor`; at a zero EVM price read the roll goes
straight to the chain, whose rejection burns the call's gas. Either way
the position self-heals: the next deposit lands before the roll and
carries the rotated-out dust with it. Until then, burning the token's
entire supply via `unwrapForTao` still exits.

## Third-party dust

Anyone can stake to the vault's or a mailbox's coldkey without asking.
The vault only counts stake under validators it tracks, `wrap` only
credits your own mailbox's balance under the hotkey you chose, and stake
planted on the vault's own slots just raises the backing for existing
holders. Wraps and exits proceed regardless of what a third party
parks.
