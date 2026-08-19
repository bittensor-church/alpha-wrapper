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
expectation and lets the attesters settle what happened.

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
coldkey. That same scan is what lets the attesters establish that alpha is
genuinely gone before signing the other door.

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

That path is a distinct threshold-signed approval — not a validator-set
attestation, sharing no type hash and no nonce with one:

| Field | Prevents |
|---|---|
| chain id, vault address | replay across deployments |
| tokenId | applying to another position |
| hash of the current `(logical, active, tracked)` slots | spending a stale approval on a later, different loss |
| minimum backing that must remain | executing against a state worse than the signers saw |
| dedicated write-down nonce | replay |
| deadline | indefinite standing authority |

The slot hash is what makes it causal, and it is the property a bare registry
nonce lacked. It also voids the approval automatically the moment anyone locates
the alpha and attests it, since that changes the state it was signed against.

Verification belongs in `ValidatorRegistry`, which already holds the EIP-712
machinery and has the bytecode room the vault does not.

Three gates apply at execution:

1. The token must independently be in an unexplained-shortfall state. A healthy
   position cannot be written down, and no approval can be pre-authorized
   against a future loss.
2. The record is **left standing**. An acknowledgement says deposits may
   resume; it does not say the alpha stopped existing. Erasing each slot's
   expectation would put a premature acknowledgement beyond recovery, because
   `recoverStray` needs a slot that still knows what it is owed. The first
   deposit after the window settles the record onto what is really there.
3. The located total must be at least `minimumBacking`, or execution refuses.

Anyone may submit an approval, as with set attestations, so no new actor
appears.

Deposits then wait out a **24-hour challenge window**. Anyone who can still find
the alpha may `recoverStray` during it, which ends the window along with the
shortfall. The window costs holders nothing, since exits, mailbox reclaims and
TAO claims never stop, so it falls only on new money. The asymmetry argues for
being generous with it: too short and a premature acknowledgement dilutes
existing holders permanently, too long and deposits merely wait.

An earlier draft rejected a timelock here, on the grounds that a warning is
useless while exits are frozen. Exits are no longer frozen, so the window now
has an audience that can act on it.

## What this trusts, stated plainly

The gates establish that **the vault cannot find the alpha** — not that it does
not exist. No on-chain check closes that gap, and the write-down should be
described in the security model as the attesters ratifying a loss, not as the
contract detecting one.

The gap is exploitable by a malicious quorum: swap a validator they control
twice, producing a genuine unexplained shortfall; sign a write-down, which every
gate passes honestly; deposit at the depressed price; then attest the hidden key
and profit on the cheap shares. This is a capability they do not have today,
because at present they choose where stake goes but cannot reduce recorded
backing — delegated stake belongs to the clone's coldkey.

Two things bound it, neither of which removes it. Gate 2 denies them any choice
of amount, so the attack is not tunable. And a write-down destroys nothing: if
the alpha is later found and attested it re-enters the union and the total
recovers, making the damage a transfer between share cohorts rather than a burn.

A timelock was considered and rejected. Its purpose would be to let holders exit
ahead of a write-down, but exits revert in precisely the state being recovered
from, so the warning reaches an audience that cannot act on it. The
auto-voiding property that would have justified it comes from the slot hash
instead.

## Every case terminates

| State | Cleared by | Needs anyone? |
|---|---|---|
| Hotkey swap the vault can follow | planning `active = successor` | no |
| Hotkey swap it cannot follow, alpha findable | `recoverStray` | anyone, permissionless |
| Dust sweep, or alpha genuinely gone | write-down approval, then the window | special attestation |
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
- Views and mutating paths consume one plan and agree without caveat. An exit's
  quote is the number that exit pays; a deposit's quote refuses on the same
  terms the deposit does.
- A withdrawal never lowers an expectation the plan could not account for.
  Only a bound write-down does that, and only by letting the next deposit
  settle it.
- Only a holder withdrawal, or a bound write-down and the deposit that follows
  it, may lower recorded backing.

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
3. Dust sweep: fails closed at any alpha price, then clears through a
   write-down. A swap whose edge the chain has since cleared behaves
   identically, which is the point - the vault cannot tell them apart and does
   not guess.
4. Swap followed by a sweep at the successor: fails closed, then clears
   through a write-down.
5. Rotation drops `A`, nothing settles, then `A -> X -> Y`: the stale rotation
   cannot excuse the shortfall.
6. The same state with the attesters naming `Y`: clears through locating.
7. Two slots converge on one successor, both when it is attested and when it is
   not: views and mutating paths both reject.
8. A write-down bound to one slot state cannot be replayed against another
   token, another state, another set, or after its deadline.
9. A write-down against a healthy token is refused.
10. Zero-valued successors are governed by `exists`; mailbox stake stranded on
    zero is reclaimable on both rails.
11. Sets that reorder, grow and shrink while `logical` and `active` differ:
    weights stay with the intended validators and active keys stay unique.
12. A set naming both a slot's `logical` and the `active` its swap moved to:
    refused before any balance is read, and cleared by the attesters dropping
    one of the pair.

## Sizing

`AlphaVault` on the branch reached 23,019 bytes against the 24,576 limit, with
the subsystem this replaces included. The planner removes four functions and the
dust machinery removes two precompile reads and the sentinel that stood in for a
lazily-loaded price; against that, `Slot` gains a word and the plan struct is
new. Keeping write-down verification in `ValidatorRegistry` is what makes the
budget comfortable rather than tight, and the figure should be measured early
rather than at the end.
