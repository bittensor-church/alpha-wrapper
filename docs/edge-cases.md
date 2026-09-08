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

A later subnet using the same netuid has a separate token and clone. Its cleanup
normally does not block the old refund. The exception is late cleanup, when the
registration block reads zero: the vault cannot distinguish that from its own
generation's unfinished refund and waits.

A refund on an unwrapped deposit's mailbox is collected with
`reclaimTaoFromMailbox(netuid)`.

## Disabled alpha transfers

Disabling alpha transfers blocks wrapping, live alpha exits and alpha mailbox
reclaims. Their reverts preserve shares and stake. `unwrapForTao` and
`reclaimMailboxAlphaAsTao` unstake instead, so this setting does not block them;
ownership, backing, minimums and pool execution still can.

## Minimum stake size and rounding

The chain uses TAO-denominated minimums: higher for partial unstakes, lower for
transfers and same-subnet moves. Only the higher minimum is exposed to the vault,
so it uses that conservative floor. A precompile rejection consumes forwarded gas.

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
