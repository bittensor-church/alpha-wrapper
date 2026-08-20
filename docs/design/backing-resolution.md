# Backing resolution

A design for the subsystem that decides whether a token's recorded backing is
still where the vault left it, to be built fresh on current `main`.

## The problem

The vault stakes users' alpha to validator hotkeys. A validator's operator can
swap its hotkey on chain, and the chain quietly carries every delegator's
stake to the new name. The vault reads the old name, sees nothing, and concludes
it is poorer than it is. It then prices shares off that number: new depositors
mint too many, exits are underpaid.

So before pricing anything, the vault has to answer one question about each
validator it recorded: **the alpha is not where I left it — did it move, or did
it cease to exist?**

- **Moved.** It still exists under some other hotkey. Pricing against the lower
  reading transfers value between share cohorts, so the call must refuse until
  the alpha is located.
- **Ceased to exist.** The chain force-sold a sub-threshold position; the
  proceeds reached the clone as TAO and the claim index already credited them to
  the holders of that moment. The lower reading is honest and nothing should
  have to intervene.

Everything below follows from answering that question well, and from accepting
that it cannot always be answered.

## What the chain tells us

One fact is recorded, and it involves no price:

**A hotkey swap leaves a lineage edge.** `swap_hotkey` writes
`HotkeySuccessor(netuid, old) -> new`. The per-subnet path records it
unconditionally; the global path records it for every subnet where the old key
was a member.

**The edge is readable, not permanent.** The chain clears a key's outgoing
successor whenever that key becomes live again - `clear_stale_hotkey_successor`
runs on both UID replacement and append - and again whenever the key is written
as a swap destination. Subtensor documents tip walks as advisory for this
reason.

**The dust sweep records nothing.** It calls
`decrease_stake_for_hotkey_and_coldkey_on_subnet` and touches no lineage.

So an edge is evidence and its absence is not:

| Event | Edge readable afterwards |
|---|---|
| Swap, one subnet | yes, until the old key is registered again |
| Swap, all subnets, key was a member | yes, same caveat |
| Swap, all subnets, key had deregistered | no |
| Dust sweep | no |

An operator can therefore swap away and register the old key again, leaving
the chain looking exactly as it does after a sweep. A design that read that
silence as "the chain took it" would write off alpha the operator still holds,
and reprice the token below its real backing on the way. The vault follows the
edge where there is one and holds the expectation where there is not.

## Why value is the wrong signal

An earlier design asked instead whether the recorded expectation was small
enough, priced at the current alpha price, for the sweep to be a plausible
cause. That reconstructs a past event from two live, moving numbers, and it is
wrong in both directions: a price rise turns a real sweep into a shortfall, a
price fall turns a real move into a write-off. It also cannot be repaired by
choosing better thresholds, because the inputs keep moving after the event.

No classification decision in this design reads a price or a threshold.

## State

```solidity
struct Slot {
    bytes32 logical;  // the identity the registry assigns weight to
    bytes32 active;   // the key currently holding the backing
    uint256 tracked;  // alpha this position is expected to account for
}
```

One `Slot.hotkey` cannot mean both things. Before a swap they are the same;
after one they differ, and collapsing them forces the vault to rediscover the
mapping by walking chain lineage — which is both redundant, since the vault
performed the follow itself, and unreliable, since lineage is not recorded on
every path.

Keeping both makes repeated hotkey swaps an ordinary progression:

```
                        logical   active
initial                 A         A
chain: A -> B           A         B
chain: B -> C           A         C
registry catches up     C         C
```

Every staking call uses `active`. Weight assignment and registry matching start
from `logical`. Nothing ever aims a transfer at a key the chain retired, so no
separate substitution pass is needed and no bounded alias walk has to exist.

When a new attested set arrives, desired keys match existing slots by `logical`
or by `active` — never by array index, since sets may be reordered. A key
matching nothing starts with `logical == active`. A dropped slot remains a
verified source until its backing is consolidated. Ambiguous matches, and two
desired keys resolving to one `active`, are errors.

## One planner

The current implementation carries two hand-written scans — one mutating, one
`view` — that must reach identical verdicts. Three defects on the existing
branch came from them disagreeing. A comment asking future readers to keep them
in step is not a mechanism.

Instead: one `view` planner produces a decision; the mutating path applies it.

```solidity
enum Status { Clean, Repairable, NeedsLocating, NeedsWriteDown, Collision }

struct Plan {
    Status status;
    bytes32[] logical;
    bytes32[] active;      // with planned swap follows applied
    uint256[] balances;
    uint256 totalLocated;
    uint256 missing;
    uint256 shortIndex;
}
```

A state-changing operation plans, rejects an unacceptable status, performs the
moves, re-reads the balances those moves touched, and only then persists. No
repair is written before the whole plan is known to be valid. Views consume the
same plan and never apply it, so what counts as accounted for is decided in one
place — by construction rather than by discipline.

The one point where a view and an operation part is deliberate: a view honours an
attestation naming where the alpha went as soon as it is published, while
spending one is reserved to `rebalance`. Between the naming and that call a quote
stands while the other rails still refuse, and a permissionless `rebalance`
closes the gap.

## Two scratch sets, not one

The scan needs to track two independent facts:

- **counted** — this on-chain balance is already in `totalLocated`.
- **claimed** — some slot has already used this key to satisfy its expectation.

A successor that the attesters happen to name is already *counted* in the union,
but it must still be *claimed* by at most one slot. Conflating the two lets two
recorded slots both lean on one balance, which reports a healthy total for a
position that is short.

## Classification

For each recorded slot where `balance + slack < tracked`:

| Observation | Conclusion | Action |
|---|---|---|
| Edge from `active`, successor holds the expectation, unclaimed | swapped, reachable | plan `active = successor` |
| Edge, successor short, or already claimed | moved, out of reach | add to `missing` |
| No edge | nothing on chain explains it | add to `missing` |

The first row is the ordinary validator hotkey swap, and it is the one case that
clears itself: no attester, no price, no delay. It is also the common one, which
is why it is the case worth automating. Everything else waits for a recovery
step, the chain's own dust sweep included - no on-chain fact separates a sweep
from a swap whose edge has since been cleared, so the vault keeps the
expectation and waits for someone to locate the alpha or for the window to run.

The vault follows at most one edge per operation. Swaps of a registered key
are rate-limited to one per subnet per day, and each clean operation persists
the new `active`, so a longer trail is walked one hop per call rather than in a
loop.

## What a shortfall actually closes

Only deposits. Minting against an understated position is the one direction the
gap can be exploited from, so `wrap` waits. Everything else carries on:

| | While a shortfall stands |
|---|---|
| Deposits | refused |
| Both exits | open, paid out of the located total |
| Quotes for exits | the located total, the number the exit pays |
| Alpha parked in a mailbox | reclaimable |
| Credited TAO | claimable |

An exit paid out of what the vault can locate can only ever shortchange the
caller who asked for it, so there is nobody to protect by refusing it, and
refusing would shut holders in over a loss they did not cause.

This puts one requirement on the settle. A withdrawal re-reads the record from
the chain, which would file the loss as an ordinary balance change, erase it,
and reopen deposits at the lowered price: the first withdrawal quietly
performing the write-off that the rest of this design exists to require
signatures for. So the plan tells the settle which slots it could not account
for, and those keep their expectation.

## Recovery

`missing` clears two ways.

### Found

Anyone points a short slot at the key actually holding its alpha:

```
recoverStray(tokenId, slotIndex, hotkey)
```

No quorum, no delay. That is safe by construction rather than by permission:
only the subnet clone can stake under its own coldkey, so a balance found there
is already holders' backing, and moving a slot onto it can only raise the
located total. There is nothing in it for a caller to take, which is exactly why
it should not wait on a signing ceremony: the person who spots the discrepancy
can act on it themselves.

Locating the key off chain is a scan of the subnet's hotkeys against the clone's
coldkey. That same scan is the only thing standing between a recoverable
position and the other door closing on it, which is why the window assumes
somebody is running one.

### Written down

The classifier cannot be completed, and this is the reason the second path
exists rather than a concession that the first is badly built. A swap records
an edge; if the successor's position is then swept, the edge still points at a
key holding nothing. The edge says "moved", the truth is "moved, then died", and
no further on-chain fact separates them. Walking deeper only relocates the
ambiguity.

Alpha that has ceased to exist cannot be named by anyone, so a design whose only
recovery is naming will lock that token forever. Since a permanent lock is not
acceptable, one recovery path must not require the alpha to exist.

That path is a clock, not an approval. The loss goes on file, and if nobody has
located the alpha a **three-hour recovery window** later, the record settles
onto what the chain still reports and the position resumes.

### Why not a signature

An earlier draft made this a threshold-signed acknowledgement, on the reasoning
that a quorum ratifies what the contract cannot detect. That reasoning does not
survive contact with what the signers would actually be asserting: *this alpha
is not coming back*. The window tests exactly that claim, permissionlessly and
with chain verification, because `recoverStray` is already open to anyone and
already proves its case against on-chain balances. Anyone who genuinely knows
where the alpha went has a strictly better move available than signing, and
anyone who does not is guessing on the same evidence the clock has.

What the signature bought, then, was not information but a veto — the ability to
withhold the clock indefinitely while recovery was attempted. That veto is the
same object as unbounded downtime for anything pricing off this vault, since the
window cannot start until a quorum acts and nothing obliges them to. A bounded
worst case that can be designed around beats an unbounded one that is
theoretically gentler, so the veto goes and the bound stays.

Removing it also removes an attack the signed version carried: a malicious
quorum could swap a validator they control twice, sign the resulting shortfall
off honestly through every gate, and settle a loss that was never real.

### The loss on file

What is recorded is a digest of the shortfall itself — which slots are
unaccounted for, and what each is owed — plus the timestamp it was first seen.

It deliberately digests the shortfall rather than the whole record. A digest
over every slot would move on any ordinary withdrawal, so a recorded loss could
never survive one; a digest over the shortfall alone is stable under activity
that loses nothing, and moves the moment a different or additional loss appears
- exactly when the window that is running stops covering what is in front of it.

That digest is re-checked before the write-off is ever taken. Without it, a loss
appearing while the window ran would be settled alongside the recorded one by
the first call after the deadline, having had no window of its own.

Three rules apply:

1. The token must independently be in an unexplained-shortfall state. A healthy
   position cannot be put on the clock, and no window can be opened against a
   future loss.
2. The record is **left standing** until the window is out. Being on file says
   the clock is running; it does not say the alpha stopped existing. Erasing
   each slot's expectation early would put a premature record beyond recovery,
   because `recoverStray` needs a slot that still knows what it is owed.
3. A loss already on file **keeps its original timestamp**. Repeat sightings
   must not push the deadline out, or an exit every couple of hours would hold
   a position shut indefinitely. A loss that differs is a different loss, and
   earns its own window.

### Who starts it, and who takes it

Exits put the loss on file in passing: they already compute the plan, they never
refuse, and they are the one thing a shut position is still guaranteed to see.
`declareShortfall(tokenId)` covers a position nothing else is touching. It grants
nothing and decides nothing — it writes down when the vault first saw the loss,
which is the one fact the chain cannot work out for itself.

The refusing rails cannot do it, because they revert and a revert leaves no
timestamp behind. That is why `wrap` keeps reverting rather than returning a
status: it moves the caller's alpha, and a returned status a caller forgets to
inspect is a silent failure.

Once the deadline passes, the **next call of any kind** takes the write-off —
deposit, rebalance, or either exit rail. Keying it to deposits alone would leave
the settle waiting on the one call a shut position is least likely to receive.

## What this trusts, stated plainly

The rules establish that **the vault cannot find the alpha** — not that it does
not exist, and not that nobody could have. No on-chain check closes that gap.
Running the window out is an inference from silence, not evidence of loss, and
the security model should describe it that way.

So the residual is real and worth naming: a loss that was recoverable all along,
and that nobody finds within three hours, is written off permanently. After the
settle `tracked` equals what the chain reports, so `recoverStray` reverts
`BackingIntact` and the alpha stops being claimable by anyone.

Two things bound that, neither of which removes it. Nobody profits from it: the
stranded alpha is unreachable by whoever caused the shortfall too, so a
premature settle is destruction with no beneficiary rather than a transfer.
And the evidence needed to prevent it is public — the vault's positions are one
`StakingHotkeys` read against its own coldkey — so the scan is cheap for anyone
willing to run it.

The window is short because the contracts pricing off this vault cannot wait,
and that is a deliberate trade: the cost of a bounded worst case is paid in
monitoring.

## Every case terminates

| State | Cleared by | Needs anyone? |
|---|---|---|
| Hotkey swap the vault can follow | planning `active = successor` | no |
| Hotkey swap it cannot follow, alpha findable | `recoverStray` | anyone, permissionless |
| Dust sweep, or alpha genuinely gone | the recovery window running out | anyone, permissionless |
| Stake parked under an unowned key | claiming the hotkey on chain | anyone, permissionless |

Holders can leave in every row, including while a row is still unresolved.

No path ends in a token that cannot be unstuck.

## Invariants

- No classification decision reads a price or a threshold, so no market move can
  revoke an earlier one.
- Each on-chain balance contributes to the total at most once.
- Each key satisfies at most one recorded expectation.
- Every staking call targets `active`, never a retired `logical` predecessor.
- An ordinary registry update cannot lower a recorded expectation.
- Silence is never read as evidence: only an edge the chain still shows may move
  a recorded expectation.
- Two recorded slots never resolve onto one key. A set that would make them
  collide is refused rather than priced. This is a property of the set, not of
  the backing, so the operating paths raise it and the views go on reporting the
  record as sound - a collided token is fully backed and merely unusable until
  the attesters drop one of the pair.
- Storage is written only from a fully valid plan, and records post-move
  balances actually read back.
- Views and mutating paths consume one plan and agree without caveat. Every
  quote refuses on the same terms the calls do, so a number handed out is one
  the vault stands behind.
- A withdrawal never lowers an expectation the plan could not account for.
  Only the recovery window running out does that.
- Only a holder withdrawal, or a settle taken after the window, may lower
  recorded backing.

## Carried over from PR #42

That branch is the backing feature and is replaced wholesale, but the following
are design-independent and should be preserved: the `MockStaking` guards that
refuse a deleted hotkey as move origin, move destination and unstake source; the
`test_parked_stake.py` localnet scenario, which exercises ownership removal and
permissionless reclaim and is unaffected by this design; the e2e extrinsic
helpers it added; the zero-hotkey mailbox recovery; the CI `pipefail` guard and
localnet image pin; and the scenario list in `HotkeySwapTripwire.t.sol` as a
test bank.

## Regression matrix

1. Swap the vault can follow; wrap, both exit rails, and rebalance all proceed
   on the successor.
2. Settle after `A -> B`, then `B -> C` with the registry still naming `A`: all
   paths operate on `C` with no manual intervention.
3. Dust sweep: fails closed at any alpha price, then clears once the window is
   out. A swap whose edge the chain has since cleared behaves identically,
   which is the point - the vault cannot tell them apart and does not guess.
4. Swap followed by a sweep at the successor: fails closed, then clears once
   the window is out.
5. Rotation drops `A`, nothing settles, then `A -> X -> Y`: the stale rotation
   cannot excuse the shortfall.
6. The same state with the attesters naming `Y`: clears through locating.
7. Two slots converge on one successor, both when it is attested and when it is
   not: views and mutating paths both reject.
8. A window granted for one loss covers that loss alone: a second one appearing
   while it runs is not settled alongside it, and the deadline cannot be pushed
   out by re-declaring or by exiting repeatedly.
9. Declaring against a healthy token is refused, and so is every quote against
   a token that cannot account for itself.
10. Zero-valued successors are governed by `exists`; mailbox stake stranded on
    zero is reclaimable on both rails.
11. Sets that reorder, grow and shrink while `logical` and `active` differ:
    weights stay with the intended validators and active keys stay unique.
12. A set naming both a slot's `logical` and the `active` its swap moved to:
    refused before any balance is read, and cleared by the attesters dropping
    one of the pair.

## Sizing

`AlphaVault` measures 23,815 bytes against the 24,576 limit, leaving 761 bytes.
The planner removes four functions and the dust machinery removes two precompile
reads and the sentinel that stood in for a lazily-loaded price; against that,
`Slot` gains a word and the plan struct is new. Settling on a clock rather than
a signature returns roughly 500 bytes on its own, since it drops a typehash, a
struct, a nonce mapping and a signature-verification path along with the two
public functions that fronted them.
