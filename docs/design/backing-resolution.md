# Backing resolution

A design for the subsystem that decides whether a token's recorded backing is
still where the vault left it, to be built fresh on current `main`.

## The problem

The vault stakes users' alpha to validator hotkeys. A validator's operator can
rename its hotkey on chain, and the chain quietly carries every delegator's
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

Two facts are recorded, and neither involves a price:

**A rename leaves a lineage edge.** `swap_hotkey` writes
`HotkeySuccessor(netuid, old) -> new`. The per-subnet path records it
unconditionally; the global path records it for every subnet where the old key
was a member.

**A global rename removes the old key's owner.** `Owner::<T>::remove(old_hotkey)`.
The per-subnet path leaves ownership in place.

**The dust sweep does neither.** It calls
`decrease_stake_for_hotkey_and_coldkey_on_subnet` and touches no lineage and no
ownership.

The two rename paths differ in complementary ways, so between them every rename
trips at least one signal:

| Event | Lineage edge | Owner removed |
|---|---|---|
| Rename, one subnet | always | no |
| Rename, all subnets, key was a member | yes | yes |
| Rename, all subnets, key had deregistered | no | yes |
| Dust sweep | no | no |

"Neither signal" is therefore a sound reading of "the chain took it".

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

One `Slot.hotkey` cannot mean both things. Before a rename they are the same;
after one they differ, and collapsing them forces the vault to rediscover the
mapping by walking chain lineage — which is both redundant, since the vault
performed the follow itself, and unreliable, since lineage is not recorded on
every path.

Keeping both makes repeated renames an ordinary progression:

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
    bytes32[] active;      // with planned rename follows applied
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
| Edge from `active`, successor holds the expectation, unclaimed | renamed, reachable | plan `active = successor` |
| Edge, successor short, or already claimed | moved, out of reach | add to `missing` |
| No edge, `active` no longer owned | moved without lineage | add to `missing` |
| No edge, `active` still owned | the chain took it | accept; the settle re-anchors |

The last row is the sweep, and it self-heals: no attester, no price, no delay.

The vault follows at most one edge per operation. Renames of a registered key
are rate-limited to one per subnet per day, and each clean operation persists
the new `active`, so a longer trail is walked one hop per call rather than in a
loop.

## Recovery

`missing` clears two ways.

### Located

The attesters name where the alpha went, and the keys they have added since the
vault last settled hold what the record cannot find:

```
attestedSince && adopted + slack >= missing
```

`adopted` is the stake under union entries past the recorded slots — exactly the
keys carrying the attesters' signature. A registry nonce that moved for an
unrelated update authorizes nothing, because it names nothing. This is their
ordinary job and grants no new power.

### Written down

The classifier cannot be completed, and this is the reason the second path
exists rather than a concession that the first is badly built. A rename records
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
2. The record re-anchors to **exactly what the vault can locate**. The signers
   authorize *that* a write-down happens; the chain decides *how much*. They
   have no discretion over the amount.
3. The located total must be at least `minimumBacking`, or execution refuses.

Anyone may submit an approval, as with set attestations, so no new actor
appears.

## What this trusts, stated plainly

The gates establish that **the vault cannot find the alpha** — not that it does
not exist. No on-chain check closes that gap, and the write-down should be
described in the security model as the attesters ratifying a loss, not as the
contract detecting one.

The gap is exploitable by a malicious quorum: rename a validator they control
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
| Rename the vault can follow | planning `active = successor` | no |
| Dust sweep | accepted; the settle re-anchors | no |
| Rename it cannot follow, alpha findable | attesters naming the key | ordinary attestation |
| Alpha genuinely gone | write-down approval | special attestation |
| Stake parked under an unowned key | claiming the hotkey on chain | anyone, permissionless |

No path ends in a token that cannot be unstuck.

## Invariants

- No classification decision reads a price or a threshold, so no market move can
  revoke an earlier one.
- Each on-chain balance contributes to the total at most once.
- Each key satisfies at most one recorded expectation.
- Every staking call targets `active`, never a retired `logical` predecessor.
- An ordinary registry update cannot lower a recorded expectation.
- A rename edge is never reclassified as a sweep.
- Storage is written only from a fully valid plan, and records post-move
  balances actually read back.
- Views and mutating paths consume one plan, so they agree on what the record
  accounts for. They part on one point: a view honours an attestation naming
  where the alpha went as soon as it is published, while spending one is
  reserved to `rebalance`, so until that call the quote stands and the other
  rails refuse.
- Only a holder withdrawal, an accepted sweep, or a bound write-down may lower
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

1. Rename the vault can follow; wrap, both exit rails, and rebalance all proceed
   on the successor.
2. Settle after `A -> B`, then `B -> C` with the registry still naming `A`: all
   paths operate on `C` with no manual intervention.
3. Dust sweep: self-heals with no attestation, and stays self-healing after the
   alpha price rises.
4. Rename followed by a sweep at the successor: fails closed, then clears
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

## Sizing

`AlphaVault` on the branch reached 23,019 bytes against the 24,576 limit, with
the subsystem this replaces included. The planner removes four functions and the
dust machinery removes two precompile reads and the sentinel that stood in for a
lazily-loaded price; against that, `Slot` gains a word and the plan struct is
new. Keeping write-down verification in `ValidatorRegistry` is what makes the
budget comfortable rather than tight, and the figure should be measured early
rather than at the end.
