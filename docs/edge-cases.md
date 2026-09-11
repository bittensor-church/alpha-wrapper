# Edge cases

Hotkey swaps, ownerless keys and missing backing have a separate
[recovery runbook](hotkey-swaps.md). This page covers other chain constraints.

## Subnet dissolution

Subtensor dissolves a subnet asynchronously, burns its alpha and distributes the
TAO refund to stake holders, including the vault clone. Pricing an incomplete refund
would misallocate it, so the vault blocks operations priced on the dissolving
generation with `SubnetInDissolutionBlackoutPeriod`.

After cleanup, the old token permanently redeems for its clone's unreserved TAO.
`unwrap` pays pro rata in whole RAO; sub-RAO slices revert
`ClaimBelowNativePrecision` without burning shares. Combining shares with another
holder can clear that rounding boundary. With no unreserved refund, `unwrap`
reverts `NothingToUnwrap` and `previewUnwrap` reverts `SubnetDissolved`.
`sharePrice` and `previewWrap` reject dissolved positions. Accrued `claimTao`
entitlements remain available.

A later subnet using the same netuid has a separate token and clone. Its
cleanup never blocks the old refund: the vault tells generations apart by the
chain's registration counter.

A refund on an unwrapped deposit's mailbox is collected with
`reclaimTaoFromMailbox(netuid)`.

## Disabled alpha transfers

Disabling alpha transfers blocks wrapping, live alpha exits and alpha mailbox
reclaims. The vault reads the switch first and reverts `AlphaTransfersDisabled`,
so shares and stake are preserved and the caller keeps the gas the chain would
have taken. `unwrapForTao` and `reclaimMailboxAlphaAsTao` unstake instead, so
this setting does not block them; ownership, backing, minimums and pool
execution still can.

## Locked alpha

A coldkey can conviction-lock its alpha on a subnet. Locked alpha cannot be
unstaked, and a same-subnet transfer carries the lock along once the sender's
unlocked alpha is spent. Accounts refuse incoming locked alpha by default, but a
coldkey swap into an account that stakes nothing copies the source's flag and
locks onto it without that account's consent.

Locked alpha never backs a share:

- Mailboxes and subnet clones are created through `createMailbox` before they
  are funded. Creation rejects candidates that carry a lock, swap history or
  ownership roles (`CloneContaminated`; retry with a fresh UID), then makes each
  accepted clone a hotkey owned by an immutable guard, because the chain refuses
  coldkey swaps into existing hotkeys even at zero stake.
- `wrap` reverts `LockedDeposit` while the caller's mailbox holds a lock.
- Priced operations and quotes revert `LockedBacking` while the subnet clone
  holds a lock. The conviction hotkey need not hold the locked stake, so a lock
  is never apportioned to individual hotkeys.
- `reclaimAlphaFromMailbox` refuses a locked mailbox when the destination
  rejects locks; `reclaimMailboxAlphaAsTao` refuses any locked mailbox. Both fail
  before the chain can refuse and burn the forwarded gas.
- Funds sent to a rejected candidate return through `reclaimUnpreparedMailbox`,
  which never activates it; transferred alpha keeps its lock.

## Minimum stake size and rounding

The chain uses TAO-denominated minimums: higher for partial unstakes, lower for
transfers and same-subnet moves. The vault applies the higher one to every move
as a conservative floor, so alpha worth less than it waits until it grows. A
precompile rejection consumes forwarded gas.

- Small deposits revert `DepositTooSmall`; top up the mailbox to retry.
- Small alpha exits revert `WithdrawTooSmall`. Internal moves can instead fail
  `GatherBelowFloor` or `ConsolidationBelowFloor`.
- Small weight-alignment moves are skipped. Current share value uses total stake;
  the changed allocation can affect future emissions.
- A zero EVM price read cannot prove a move is too small. Deposit, gather and
  consolidation checks defer to the chain; weight-alignment moves skip.

Full stake drains on the TAO exit bypass the minimum. Partial exits must clear
the post-fee minimum, so the TAO route is not a guaranteed fallback for every
small holder. See [exit options](user-guide.md#native-tao-market-sale).

## Dust sweeps and rotation leftovers

After a partial unstake, the chain may force-sell a below-threshold remainder.
The vault avoids sales that would sweep other holders' backing into the caller's
payout. Unsold alpha is refunded as shares, except a full-supply exit discards a
sub-floor remainder.

A dropped validator's dust can block consolidation if no balance is large enough
to carry it. A later deposit can supply that balance because it lands before
consolidation. A full-supply TAO exit avoids consolidation, subject to its own
checks; neither route bypasses independent recovery restrictions.

A slot the pool would not pay for makes the plain TAO exit fail and burn its gas.
The exit that takes an exclusion mask sells the other slots and refunds the
rest as shares; the user guide describes the pre-flight that finds such slots.

The chain's root can raise the minimum a nominator may hold and sweep every
smaller position into TAO. A vault slot swept that way arrives as TAO on the
clone, claimable by holders, while the record reads short: the shortfall clock
starts and the position parks after the window.

## Stray TAO and alpha

Unsolicited TAO on a live clone enters a per-share claim index at the next share
balance change or claim, rather than inflating alpha backing. Claims survive full
exits and pay whole RAO, retaining finer residue.

TAO arriving at zero supply stays unassigned until shares exist. Unindexed TAO
present when dissolution starts, and later arrivals, instead back the dissolved
refund. Already-indexed claim liabilities stay separate.

Third-party alpha under tracked keys increases backing; stake elsewhere is not
automatically counted. Mailbox wraps credit only the caller's chosen key.
Untracked vault alpha joins the position through `recoverStray` under the
[recovery rules](hotkey-swaps.md), including their late-recovery ownership policy.
