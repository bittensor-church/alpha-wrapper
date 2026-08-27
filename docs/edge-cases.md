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
- A wrap or partial alpha exit that cannot leave every non-zero validator
  slice above the nominator sweep threshold reverts `PositionTooSmall`.
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
a dust threshold, folding the proceeds into that unstake's payout. Weight
alignment never deliberately leaves a non-zero target below that threshold:
small positions use fewer, larger validator slices, and a corrective move
is skipped if it would create a sweepable destination. A partial alpha exit
gathers first when direct delivery would leave a sweepable tail.

A partial `unwrapForTao` is sized to keep the remaining holders' backing
whole: the vault will not sell a chunk whose leftover the chain would
sweep, and sells less, or nothing, from that slot instead. Whatever stays
staked comes back to the caller as shares, except on a burn of the entire
supply, which drops a leftover below the chain's minimum.

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
