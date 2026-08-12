# Validator tracking and backing integrity for AlphaVault

Approved design, 2026-08-03. Written against:

- `~/Projects/alpha-wrapper` @ `781b14b` (main)
- `~/Projects/subtensor` @ `e4ffa2e13` (main, runtime v440) — all subtensor
  refs below
- `~/Projects/tao20-contract` (TAO20Index / BuybackTreasury as consumers of
  the vault's views)

Ships as a **fresh coordinated deployment** of AlphaVault and
ValidatorRegistry (both non-upgradeable; the registry address is immutable
in the vault). No migration of live positions is designed here — if a live
vault must be migrated instead, that is a separate work item and this
assumption must be revisited first.

## 1. Architecture

The vault holds users' alpha under per-subnet clone coldkeys, delegated to
at most three attested validators per subnet. The chain can relocate that
stake without the vault's participation: a validator's hotkey swap migrates
every delegator position to a new hotkey. A contract that remembers
validators only by hotkey silently loses sight of its own backing when that
happens, and everything priced off its views — share prices, integrator
NAVs — goes wrong quietly.

This design makes the vault's accounting follow the chain, and fail closed
in the narrow cases where the chain permits stake to be hidden:

1. **Anchor validators by uid, read by both legs.** Each tracked validator
   is stored as `(hotkey, uid)`. The chain rewrites `uid → hotkey` in the
   same extrinsic that migrates stake (fact 1), so reading the position
   under both the *stored* hotkey and the *uid-resolved* hotkey covers every
   single-swap mode in the block it happens — no detection, no freeze, no
   operator action.
2. **Per-slot marks catch what the legs cannot see.** Subtensor permits
   sequences that park stake under a key with no uid at all (fact 2). Each
   tracked slot keeps a mark — its balance as last observed — and any slot
   reading below its mark halts every mutating operation and pricing view.
   Legitimate events never trip a mark (stake moves *between a slot's own
   legs*, or stays put); only hiding sequences and genuine losses do.
3. **Cures are permissionless proofs, not privileged writes.**
   `demonstrateBacking` unfreezes the vault only when the caller shows
   hotkeys that verifiably hold the missing value, which the vault then
   moves home; `reanchorBacking` handles bookkeeping-only trips when no
   value is missing at all. Marks are only ever written from fresh chain
   reads. The single privileged path — accepting a genuine loss — is
   owner-gated behind a 72-hour public challenge window.

Prices are always live reads; marks gate, they never price.

## 2. Chain facts this design stands on (verified 2026-08-03, runtime v440)

1. **Registered swaps rebind the uid atomically with a whole-position stake
   migration.** `swap_hotkey_v2(hotkey, newHotkey, Option<netuid>,
   keep_stake)` rewrites `Keys(netuid, uid) → newHotkey` and membership for
   a registered validator (`swap/swap_hotkey.rs:626-646`; executed
   per-subnet in the all-subnets loop); when `keep_stake == false` (the
   legacy `swap_hotkey` hardcodes it, `macros/dispatches.rs:843-850`) the
   migration reads each delegator position in full and moves all of it in
   the same extrinsic (`:774+`). There is no partial re-key.
2. **A detached key can be swapped without moving any uid.** The uid rebind
   is conditional on membership (`swap_hotkey.rs:626`), but the stake
   migration is not, and the caller need only *own* the old key
   (`swap_hotkey.rs:86`) — it need not be registered. Therefore the
   sequence `A→B keep_stake=true` (uid now at B, stake left on A, A no
   longer a member) followed by `A→C keep_stake=false` moves the stake to
   `C` while no uid anywhere points at `C`. Stake can end up under a key
   that uid resolution can never find. This fact is why marks exist.
3. **`keep_stake=true` scope asymmetry.** One-subnet scope keeps the old
   key's owner record (`swap_hotkey.rs:530`); all-subnets scope deletes it
   (`:393`). Moves and unstakes require owner records on the keys involved
   (`hotkey_account_exists` = `Owner.contains_key`, `staking/helpers.rs:207`;
   `stake_utils.rs:1309-1319`, `:1213-1216`), so stake under an ownerless
   key is frozen until the permissionless, insert-only
   `try_associate_hotkey(hotkey)` restores a record
   (`macros/dispatches.rs:1523-1529`, `staking/account.rs:4-12` — it cannot
   hijack an owned key). While any tracked slot's key is ownerless, every
   vault path that would move or sell that position reverts at full gas:
   this state halts the subnet's operations until the substrate-side
   association is sent.
4. **Pruning recycles the slot and touches no stake.** On a full subnet a
   newcomer's registration rebinds the pruned uid to the newcomer
   (`subnets/registration.rs:27-29`, `subnets/uids.rs:62-116`) —
   third-party-timed — while the pruned key's positions persist untouched.
5. **Uids can be renumbered.** `trim_to_max_allowed_uids` compacts
   surviving validators to new uids (`subnets/uids.rs:151`, `Keys::swap` at
   `:322`) and lowers the uid count (`:379`); callable through
   `sudo_trim_to_max_allowed_uids` (`pallets/admin-utils/src/lib.rs:1927`).
   After a trim, a stored uid may point at a different validator or out of
   range. Anchors are therefore *refreshable pointers*, not permanent
   identities; the registry re-binds them at every attestation.
6. **A validator's coldkey can change.** A coldkey swap rewrites `Owner`
   for every owned hotkey (`swap/swap_coldkey.rs:168-186`). Any owner value
   captured earlier goes stale; the remedy is re-attestation (the registry
   re-captures owners at commit).
7. **Metagraph precompile** (`0x0000000000000000000000000000000000000802`):
   `getUidCount(uint16)` (1 db read), `getHotkey(uint16,uint16)` (1 db
   read), `getColdkey(uint16,uint16)` (2 db reads — the owner of the key
   currently at that uid) (`precompiles/src/metagraph.rs:29-36,163-186`).
   `getHotkey`/`getColdkey` revert `InvalidRange` on an unbound uid, and a
   failed precompile call consumes all forwarded gas with empty returndata
   — so no code path may resolve a uid it has not first bounded by a fresh
   `getUidCount` read. With that guard, in-range uids are always bound: on
   a live subnet uids are contiguous; trims compact and lower the count in
   one extrinsic; dissolution zeroes the count before clearing keys.
   Uid cap is 256 (`runtime/src/lib.rs:788`; the admin setter rejects
   larger, `pallets/admin-utils/src/lib.rs:566-568`) — raising it requires
   a runtime upgrade (runbook compatibility event).
8. **Two distinct chain floors.** Same-subnet moves and transfers require a
   tao value of at least the transfer minimum — 100,000 RAO (0.0001 TAO),
   whole-position moves included (`staking/stake_utils.rs:1035-1048`,
   `runtime/src/lib.rs:819`). Unstake sizing is governed separately
   (2e6-anchored family; full-balance unstakes exempt). No precompile
   exposes the transfer minimum; the vault mirrors it (§9).
9. **Value-destroying events exist.** Root raising the nominator threshold
   force-clears sub-threshold nominations — sold at min price, or deleted
   outright if the sale errors (`pallets/admin-utils/src/lib.rs:1149-1162`,
   `staking/helpers.rs:227-270`). A root-level coldkey swap of a clone
   removes the vault's control entirely. Both are loss events, not hiding
   events: nothing can demonstrate the value back (§8 loss path).
10. `getStake(hotkey, coldkey, netuid)` charges a flat 7 db reads =
    4,375 gas (`precompiles/src/staking.rs:336-356`); absent positions read
    zero. `transferStake` moves a position between coldkeys under one
    hotkey (`precompiles/src/staking.rs:263-272`, `CloneBase.flush`) — a
    flush cannot change the hotkey; only `moveStake` can.

## 3. Contract surface

### ValidatorRegistry (redeployed; ABI break, all consumers migrate)

```solidity
struct WeightAttestation {
    uint256 netuid;
    bytes32[] hotkeys;
    uint16[] uids;      // each validator's current slot
    uint256[] weights;
    uint256 nonce;
    uint256 deadline;
}

struct ValidatorSet {
    bytes32[3] hotkeys;
    uint16[3]  uids;
    bytes32[3] owners;  // captured at commit from the metagraph
    uint16[3]  weights;
}

function getValidators(uint256 netuid)
    external view
    returns (bytes32[3] memory hotkeys, uint16[3] memory uids, bytes32[3] memory owners, uint16[3] memory weights);

error UidOutOfRange();
error UidHotkeyMismatch();
```

At commit, per attested entry: read `getUidCount(netuid)` once and require
`uid < uidCount` (`UidOutOfRange` — resolving an unbound uid would burn the
transaction's gas, fact 7), then require `getHotkey(netuid, uid) == hotkey`
(`UidHotkeyMismatch` — swap-following depends on the binding being true at
attestation time), then capture `owners[i] = getColdkey(netuid, uid)`. The
EIP-712 typehash changes with the payload (attester tooling update, §15).

Solidity cannot overload by return type, so the richer `getValidators`
replaces the old signature outright. The complete consumer set to migrate:
`AlphaVault._resolveValidators` and `AlphaVault._unionStake`,
`src/interfaces/IValidatorRegistry.sol`, `test/mocks/MockValidatorRegistry.sol`,
the registry/vault test suites, and `scripts/get_vault_state.py`. TAO20 and
BuybackTreasury do not call the registry (the buyback depends on the
vault's `getCurrentValidators(uint256) → bytes32[3]`, which is preserved).

### AlphaVault

```solidity
struct TrackedSlot {
    bytes32 hotkey; // key the vault last confirmed holds this slot's stake
    uint16  uid;    // anchor for live resolution
}

/// Where the clone's stake was left at the last state-mutating call, with
/// each slot's balance as then observed. Marks gate; they never price.
mapping(uint256 => TrackedSlot[3]) private _trackedSlots;
mapping(uint256 => uint64[3])      private _slotMarks;   // rao; one packed word

/// Pending owner loss acceptance: proposal timestamp per token (0 = none).
mapping(uint256 => uint256) public backingLossProposedAt;
uint256 public constant LOSS_ACCEPTANCE_DELAY = 72 hours;

/// Tao floor mirroring the chain's same-subnet movement minimum. Distinct
/// from minStakeTaoFloor (which mirrors the unstake-sizing floor).
uint256 public minMoveTaoFloor; // init 100_000; owner-tunable up to MOVE_FLOOR_CAP = 10_000_000

error BackingShort(bytes32 hotkey, uint256 mark, uint256 observed);
error InsufficientDemonstration(uint256 presented, uint256 deficit);
error NothingToDemonstrate();
error NoAggregateSurplus();
error PresentedKeyAlreadyCounted(bytes32 hotkey);
error NoBackingDeficit();
error NoPendingBackingLoss();
error LossAcceptanceDelayNotMet();
error NoLiveTarget();
error MinMoveTaoFloorTooHigh();

event BackingDemonstrated(uint256 indexed tokenId, uint256 presented, uint256 deficit);
event BackingReanchored(uint256 indexed tokenId);
event BackingLossProposed(uint256 indexed tokenId, uint256 deficit);
event BackingLossAccepted(uint256 indexed tokenId, uint256 clearedDeficit);
event MinMoveTaoFloorUpdated(uint256 oldValue, uint256 newValue);

function demonstrateBacking(uint256 netuid, bytes32[] calldata strayHotkeys) external nonReentrant;
function reanchorBacking(uint256 netuid) external nonReentrant;
function proposeBackingLoss(uint256 tokenId) external onlyOwner;
function acceptBackingLoss(uint256 tokenId) external onlyOwner;
function setMinMoveTaoFloor(uint256 newValue) external onlyOwner;
function trackedSlots(uint256 tokenId) external view returns (TrackedSlot[3] memory, uint64[3] memory);
```

`_lastSeenHotkeys` and its getter are replaced by `_trackedSlots` /
`trackedSlots`. `getCurrentValidators` is unchanged. Internal union arrays
widen from 6 to 12 candidate legs. `unwrapForTao`'s sell loop iterates the
widened set.

## 4. Read path: legs, assignment, union

For pricing and operation working sets:

1. Read `uidCount = getUidCount(netuid)` once per call.
2. **Slot legs** — for each of the three tracked slots: the stored
   `hotkey`, plus `getHotkey(netuid, uid)` when `uid < uidCount` (an
   out-of-range anchor contributes its stored leg only).
3. **Attested legs** — for each registry slot: its hotkey, plus its
   uid-resolution under the same guard. These make freshly attested keys
   visible before the next consolidation re-points the tracked slots.
4. **Assignment**: walk tracked slot 0..2, stored leg then resolved leg,
   claiming each not-yet-claimed key for that slot; a slot's **observed
   balance** is the sum of `getStake` over the keys it claimed. Attested
   legs not claimed by any tracked slot are **union extras**: counted for
   pricing, never for marks.
5. **Union total** = Σ slot balances + Σ extras, every unique key read and
   counted exactly once. `totalStake`, `sharePrice`, previews, exits, and
   working sets all derive from this one construction.

Why assignment-robustness holds: the union total is independent of which
slot claims a key, and Σ slot balances is fixed by the claimed-key set — so
if value leaves the tracked keys, some slot must read below its mark (if
every slot were at or above its mark, the sum would be too). Detection
cannot be reshuffled away; at worst a claim shift trips a *different* slot
than the one that lost value, which fails closed and is repaired by §7-§8.

## 5. Marks and the trip rule

`_slotMarks[tokenId][i]` is slot *i*'s observed balance at the end of the
last state-mutating call. Every mutating operation (`wrap` — **before** the
mailbox flush, so a deposit can never paper over a shortfall — live-path
`unwrap`, `unwrapForTao`, `rebalance`) and every pricing view (`sharePrice`,
`previewWrap`, `previewUnwrap`) first computes the slot balances and
reverts `BackingShort(slot.hotkey, mark, observed)` on the first slot
reading below its mark. `totalStake` stays a raw reporter. Dissolving and
dissolved paths keep their existing blackout behavior and never touch
marks.

Marks are written **only from fresh chain reads**, in exactly four places:
the end-of-op refresh (§6), `demonstrateBacking` (§7), `reanchorBacking`
(§7), and `acceptBackingLoss` (§8). No function accepts a caller-supplied
mark or delta.

What never trips: a registered swap in either `keep_stake` mode (the
position moves between, or stays on, the slot's own legs), a prune (stake
stays on the stored leg), a trim (stored legs unaffected), rotation,
emission (balances only grow), donations. What trips: the detached-key
hiding sequence (fact 2 — both legs read empty), forced clearing, a
root-level clone coldkey swap, and transient read dips if the share-pool
rounding ever produces them (§16 measures; the cure is a top-up of that
slot's key at the transfer minimum, or its own emission).

## 6. Targets, consolidation, refresh

**Valid target.** Moves and deposit routing may only target an attested
slot whose anchor passes: `uid < uidCount`, `getHotkey(uid) == candidate`,
and `getColdkey(uid) == owners[slot]` (registry-captured). The owner check
guarantees *custody continuity* — the slot is still operated by the
attested coldkey — not validator identity in a deeper sense; a recycled or
renumbered slot fails it and is never a destination. If no attested slot
has a valid target, moves are skipped and `wrap` reverts `NoLiveTarget`
(deposits must not land on unverifiable destinations); exits that need no
target (`unwrapForTao`) still work. Re-attestation restores targets.

**Deposit flow.** `wrap`'s `chosenHotkey` must be an attested stored key or
a valid-target resolved key. The mailbox flush lands the deposit under
`chosenHotkey` itself (a flush changes only the coldkey — fact 10); the
same call's consolidation then moves it to the slot's valid target when the
value clears the move floor.

**Consolidation and refresh.** The existing rotated-stake consolidation
keeps its shape, with every destination passing the valid-target rule and
every floor pre-check on a move using `minMoveTaoFloor`. At operation end,
after consolidation, each tracked slot is refreshed to **the key the vault
confirmed holds the slot's stake** — the valid target it moved the stake
to, or the key the stake verifiably remained on — together with that key's
current uid binding when one exists (`Uids` is not EVM-readable directly;
the uid is taken from the attested slot the stake was consolidated onto).
Marks are then written from fresh reads of the refreshed slots. A slot is
never re-pointed away from a key that still holds its stake: if
consolidation could not run to completion for a slot, that slot's entry
and mark are left untouched.

## 7. Permissionless cures

### demonstrateBacking — show the missing value, verified

```solidity
function demonstrateBacking(uint256 netuid, bytes32[] calldata strayHotkeys) external nonReentrant
```

1. Guards: netuid in range, clone exists, not dissolving; the list is
   non-empty, at most 8 entries, no zeros, no duplicates; every presented
   key must be outside the current candidate-leg set
   (`PresentedKeyAlreadyCounted` — keys the union already reads prove
   nothing).
2. `deficit = Σ max(mark_i − observed_i, 0)` over tracked slots; zero →
   `NothingToDemonstrate`.
3. `presented = Σ getStake(strayKey, cloneColdkey, netuid)`; require
   `presented ≥ deficit` (`InsufficientDemonstration`) — coverage must come
   entirely from keys the union does not already count, so surplus or
   emission on healthy slots can never co-sign a partial demonstration.
4. For each presented position whose value clears the move floor:
   `moveStake` onto a valid attested target (`NoLiveTarget` if none
   exists). Positions below the floor are counted for coverage but left in
   place (each is worth under 0.0001 TAO; they drop out of protection at
   re-anchor — a bounded, disclosed residue).
5. Re-point each deficit slot to the target it received the stake (slots
   sharing a target are handled by assignment — each key still counts
   once); recompute all slot balances; write all marks from those fresh
   reads; emit `BackingDemonstrated`.

The caller is trusted for locations only: amounts come from the chain,
destinations are attested-and-owner-checked, and a wrong or partial list
reverts without changing anything. An ownerless presented key makes the
move revert (fact 3) — send `try_associate_hotkey` first (§15).

### reanchorBacking — repair a bookkeeping trip when nothing is missing

```solidity
function reanchorBacking(uint256 netuid) external nonReentrant
```

Requires some slot below its mark (`NoBackingDeficit` otherwise) **and**
`Σ observed_i ≥ Σ mark_i` (`NoAggregateSurplus` otherwise) — i.e., value
merely shifted between slots' claimed keys without leaving the tracked
set. Rewrites all marks from fresh reads and emits `BackingReanchored`.
Safety: the aggregate-intact requirement means total protection never
decreases through this call, so it cannot be used to hide a real deficit;
the only way to satisfy it while value is genuinely missing is to donate
at least the missing amount into the tracked keys — which makes the vault
whole by construction.

## 8. Loss acceptance — owner-gated, delayed

`proposeBackingLoss(tokenId)` requires a live deficit and records the
proposal (`BackingLossProposed`). `acceptBackingLoss(tokenId)` executes no
earlier than 72 hours later (`LossAcceptanceDelayNotMet`;
`NoPendingBackingLoss` without a proposal), requires the deficit to
**still** exist, rewrites all marks from fresh reads, clears the proposal,
and emits `BackingLossAccepted`.

The delay is load-bearing: an instant re-anchor during a *recoverable*
deficit would reopen trading against totals that exclude recoverable value
— cheap mints for whoever deposits first, the owner included. The delay
makes loss acceptance a public claim that anyone can falsify for 72 hours
by demonstrating the value instead. Genuine losses (fact 9) survive the
window because there is nothing to demonstrate. Declining to accept leaves
the vault frozen, which is always available.

## 9. Floors

`minMoveTaoFloor` (init 100,000 RAO; owner-tunable, capped at 10,000,000,
`MinMoveTaoFloorTooHigh`) gates every pre-check on a move or transfer:
consolidation, rebalance steps, gather hops, the deposit flush, delivery,
and `demonstrateBacking`'s repatriation moves. `minStakeTaoFloor`
(existing, init 2e6) keeps gating unstake sizing in the sell paths. Each
vault-side pre-check mirrors exactly one chain-side check; the
implementation records the mapping with subtensor citations in the PR
description.

## 10. Chain events and vault behavior (complete)

| Event | Read path / marks | Action |
|---|---|---|
| Registered swap, stake follows (common mode) | Resolved leg picks the new key up in the block the stake moved; slot balance unchanged; no trip | none; next op re-points the stored leg |
| Registered swap, stake stays (one-subnet `keep_stake=true`) | Stored leg keeps counting; no trip | none; next op consolidates to a valid target |
| All-subnets `keep_stake=true` (old key ownerless) | Stored leg keeps counting (the stake is recoverable, so counting it is honest); **every op touching the position reverts at full gas until the owner record is restored — a subnet-wide operational halt** | anyone: substrate `try_associate_hotkey(old)`; operator preferred (§15) |
| Detached-key double swap (fact 2) — the hiding sequence | Both legs empty → slot trips → all ops and pricing views revert | anyone: `demonstrateBacking([newKey])` — moves it home, resumes atomically |
| Prune (slot recycled) | Stored leg counts; stranger fails the owner check as a target; no trip | none; next op consolidates; re-attest at convenience |
| Prune, then the pruned key swapped `keep_stake=false` before any op | Hiding sequence — trips | `demonstrateBacking` |
| Uid trim (anchors renumbered) | Stored legs count; resolution may point at wrong validators until re-attestation (never used as targets — owner check); no trip | re-attest promptly (§15) |
| Validator coldkey swap | No balance change, no trip; captured owner goes stale → that slot loses its valid target | re-attest (registry re-captures owners) |
| Governance clearing (sale or delete branch) | Slot balance drops → trips (sale proceeds reach holders via the existing clone-TAO claim index) | owner: propose + accept loss |
| Root coldkey swap of the clone | All slots trip, permanently | remain frozen, or propose + accept if holders are compensated otherwise |

## 11. Consumer guarantees (TAO20Index, BuybackTreasury)

TAO20 calls `previewUnwrap` inside its mint and salvage transactions —
twice per on-index vault plus once per held off-index vault (roughly 40+
calls per mint) — and the buyback calls `unwrap` under an immutable 2.5M
gas stipend inside `try/catch`.

- **Gas class O(tracked slots), independent of subnet size**: a view costs
  one `getUidCount`, up to six guarded `getHotkey` resolutions, up to
  twelve `getStake` reads, and the registry/slot storage reads — ~45k
  typical, ~80k worst-case. A 40-call TAO20 mint budgets ~1.8M typical /
  ~3.2M worst for its NAV legs. `unwrap` stays ~300-400k — comfortable
  under the buyback stipend.
- **Views follow swaps in the same block**, so NAV computed from
  `previewUnwrap` cannot be fed a stale-location undercount by any
  single-swap timing.
- **One addition to the view revert surface, by design**: while a slot is
  tripped, pricing views revert `BackingShort`. For TAO20 this means a
  hiding attack or a genuine loss on any basket subnet halts minting and
  salvage until the cure lands — a deliberate choice: halting the index's
  primary market beats letting it mint against a poisoned NAV. The
  buyback's `try/catch` parks the affected vault and retries later,
  unchanged. Plain TAO20 redeems (pro-rata share transfers) never touch
  these views and keep working throughout.

## 12. Gas (live-priced 2026-08-03: 10 gwei, TAO $188.48)

| Operation | Today | This design |
|---|---|---|
| View (`previewUnwrap` / `sharePrice`) | ~33k | ~45k typical / ~80k worst (~$0.008-0.015) |
| `wrap` | ~250k | ~285k (~$0.054) |
| `unwrap` | ~175-250k | ~300-400k worst |
| `unwrapForTao` | ~170k | up to ~2x sell-loop cost at the 12-leg worst case |
| TAO20 mint NAV legs (~40 views) | ~1.3M | ~1.8M typical / ~3.2M worst (~$3.4-6.0 total tx, vs ~$2.5) |
| `demonstrateBacking` (attack recovery, rare) | — | ~150-250k |
| Registry commit | ~90k | ~130k (uid bound + binding check + owner capture per entry) |

Costs do not scale with subnet occupancy. **Bytecode is the binding
budget**: AlphaVault is at 22,293 of 24,576 bytes today; this design adds
material code. `forge build --sizes` is a hard gate after every
implementation step, with a pre-planned fallback of extracting the
demonstration/re-anchor logic into an external library.

## 13. Properties the design maintains (for implementers and auditors)

- Marks are written only from fresh chain reads; no caller-supplied value
  reaches them. Raising protection requires real balances; lowering it
  requires either an aggregate-intact re-anchor, a covered demonstration,
  or the delayed owner path.
- Deficit coverage counts only keys the union does not already read;
  surplus and emission on healthy slots never offset a missing slot.
- No permissionless call converts stake to TAO or moves it anywhere except
  onto attested, owner-checked targets.
- Every unique key is read and counted exactly once per pricing pass,
  regardless of how many legs name it.
- No unguarded uid resolution exists anywhere (registry commit included):
  every `getHotkey`/`getColdkey` call is preceded by a fresh
  `getUidCount` bound.

## 14. Residual risks (explicit)

1. **Freezes are attack-scoped but real.** A hiding sequence or loss halts
   the subnet's vault operations and, through the views, TAO20
   minting/salvage, until `demonstrateBacking` (anyone, minutes, one RPC
   read to locate — the chain's coldkey-to-hotkeys index is readable
   off-chain in one state query) or the owner path (72h) resolves it. The
   attacker pays swap fees and achieves a halt, not extraction.
2. **The ownerless corner halts without tripping.** All-subnets
   `keep_stake=true` leaves the position counted but immovable; operations
   revert at full gas until a substrate-side association no EVM caller can
   perform. Operator SLA required (§15).
3. **Custody, not identity.** The owner check binds targets to the attested
   coldkey, not to a specific hotkey: another hotkey of the same operator
   landing on the anchored uid would pass. Weights and slot identity are
   re-asserted at every attestation; the window between is accepted.
4. **Anchors go stale between attestations** (trim, coldkey swap). Stored
   legs keep every balance counted throughout — the cost of staleness is
   losing swap-*following* on that slot until re-attestation, during which
   a stake-moving swap of that validator lands in the hiding row (cured,
   not silent).
5. **Transient read dips** (share-pool rounding) would trip exactly like a
   tiny hide. Cure: top up the dipped slot's key at the transfer minimum,
   or wait for its emission; the localnet plan measures whether this
   occurs at all before any tolerance is considered.

## 15. Operational runbook

1. **Attester payload v2**: attestations carry uids; the typehash changes;
   stale uids revert at commit (in-range bound first, then the binding
   check) — re-read the metagraph and re-sign. Re-attest promptly after:
   any swap touching an attested validator, a prune of one, a uid trim on
   the subnet, or a validator coldkey swap.
2. **Watch loop** (any party; the attesters' infrastructure already watches
   these chains of events): on `BackingShort` appearing in view calls or
   op reverts — read the clone coldkey's staking index via one RPC state
   query, diff against the tracked keys, and call
   `demonstrateBacking(netuid, missingKeys)`. If the move reverts for a
   missing owner record, send `try_associate_hotkey(key)` from the
   operator's substrate account first (an operator association keeps the
   key out of stranger hands; a stranger who associates first can only
   relocate the position — never take it — but each relocation is another
   demonstration).
3. **Loss protocol**: `BackingLossProposed` is a public 72-hour challenge
   window — verify the deficit is genuinely unrecoverable (clearing
   deletion, clone coldkey swap) and attempt demonstration before it
   executes.
4. **Runtime upgrades**: re-verify the transfer minimum (mirrored as
   `minMoveTaoFloor`), the metagraph and staking precompile ABIs, and the
   uid cap before resuming operations.

## 16. Test plan

### Mocks

- `MockMetagraph` (installed at the metagraph precompile address):
  uid-indexed hotkeys and owners; `getUidCount`; `getHotkey`/`getColdkey`
  reverting on unbound uids; `setNeuron(netuid, uid, hotkey, owner)`;
  `trimUids(netuid, newCount, mapping)` for renumbering.
- `MockStaking`: owner-record flag per hotkey (moves and unstakes revert
  without it on the required side), the 100k move floor on
  moves/transfers (whole positions included), full-drain exemption on
  unstakes only, whole-position re-keying, and `transferStake` that keeps
  the hotkey fixed (coldkey-only, as the chain does).
- Test-base helpers: `swapHotkeyOneSubnet(old, new, netuid, keepStake)`
  (uid rebind only if `old` is a member; owner record kept),
  `swapHotkeyFull(old, new, netuid, keepStake)` (same, owner record of
  `old` cleared), `pruneNeuron(netuid, uid, newcomer, newcomerOwner)`
  (rebind, stake untouched), `associateHotkey(key, owner)`,
  `donateStake(...)`, `accrueEmission(...)`, clearing helpers (sale and
  delete branches).

### Unit (repo naming)

- `test_TotalStake_FollowsStakeMovingSwap` — same block, no intervening
  calls; `test_PreviewUnwrap_FollowsStakeMovingSwap` (the TAO20 guarantee).
- `test_TotalStake_CountsStakeKeepingSwapOnStoredLeg` /
  `test_TotalStake_CountsPrunedSlotOnStoredLeg` /
  `test_TotalStake_SurvivesUidTrim`.
- `test_Wrap_RevertsWhenSlotBelowMark` — the detached-key double swap
  (`A→B keep=true`, then `A→C keep=false`), both scopes; and
  `test_PreviewUnwrap_RevertsWhenSlotBelowMark`.
- `test_Wrap_ChecksMarksBeforeFlush` — a pending deposit cannot mask a
  deficit.
- `test_UnionStake_CountsCollidingLegOnce` — one key named by two legs;
  union exact, no double-count; `test_Unwrap_PaysFromDedupedUnion`.
- `test_Marks_QuietAcrossEmissionThenSwap` — emission growth on one slot
  never masks another slot's hide (the per-slot property).
- `test_Rebalance_RefusesRecycledSlotAsTarget` /
  `test_Wrap_RevertsOnForeignResolvedChosenHotkey` /
  `test_Wrap_RevertsWithoutLiveTarget`.
- `test_Consolidation_RepointsSlotToConfirmedKeyOnly` — a slot is never
  re-pointed away from a key still holding its stake (recycled-slot and
  `keep_stake=true` cases).
- `demonstrateBacking`: covers-and-resumes on the double-swap; rejects
  partial coverage, duplicate keys, union-member keys, empty deficit;
  counts sub-floor presented positions for coverage and leaves them; moves
  only to valid targets; ownerless presented key reverts, succeeds after
  `associateHotkey`; marks written from reads on every exit path.
- `reanchorBacking`: repairs an induced claim-shift trip; reverts while a
  real aggregate deficit exists; never lowers total protection.
- Loss path: delay enforced, still-deficit required (a demonstration
  during the window voids acceptance), non-owner reverts, events.
- Registry: in-range bound before binding check (out-of-range uid reverts
  `UidOutOfRange` cleanly, including inside `updateValidatorsBatch`),
  mismatch reverts, owners captured; all consumers compile against the new
  tuple.
- Floors: move-path boundaries at 100k (flush gate, gather, consolidation,
  rebalance, delivery, demonstration moves), unstake boundaries at 2e6,
  cap enforcement.

### Fuzz / invariant

- `testFuzz_Ops_PriceTrueBackingThroughChainEvents(uint8[] memory ops, uint8 eventKind, uint8 eventPoint)`
  — random operation interleavings with swaps (all four modes), prunes,
  trims, donations, emission injected at random points: every operation
  and view either executes against the exact union of vault-held stake or
  reverts `BackingShort`; hiding sequences always trip by the next touch.
- `testFuzz_Demonstrate_RestoresAnyHiddenAmount(uint256 amount)` — bound
  across the move floor; below it, coverage still accounts and the residue
  is bounded as specified.
- `invariant_EveryKeyCountedOnce` — pricing equals the mock ledger's total
  for keys in the candidate set, under arbitrary leg collisions.
- `invariant_MarksOnlyFromReads` — handler mirrors all four mark writers;
  marks never exceed what a fresh read returned at write time; total
  protection decreases only via the owner path.
- `invariant_NoMoveOutsideValidTargets` — every mock-logged move
  destination passed the target rule at execution time.

### Localnet e2e — mandatory before deployment

Real-runtime validation on a local subtensor node (per the e2e runbook:
`scripts/localnet.sh` from the subtensor checkout, btcli 9.23.2, 8M deploy
gas), extending the existing pytest suite. The mocks encode chain
semantics by hand; only a real node validates them:

1. **Hotkey swap, headline**: wrap a position; execute a real
   `swap_hotkey_v2(keep_stake=false)` on an attested validator; assert in
   the first block after inclusion, with no other calls: `totalStake` and
   `previewUnwrap` unchanged; then a full `wrap` and `unwrap` succeed and
   `trackedSlots` shows the re-pointed key. Repeat for the all-subnets
   scope.
2. **Stake-keeping swap** (`keep_stake=true`, one subnet): totals
   unchanged via the stored leg; the next `rebalance` consolidates onto
   the valid target.
3. **The hiding sequence**: `A→B keep_stake=true`, then `A→C
   keep_stake=false` (both scopes for the second leg where the chain
   permits): the next `wrap` reverts `BackingShort`;
   `demonstrateBacking([C])` moves the stake home and the same `wrap`
   succeeds; assert exact totals throughout.
4. **Ownerless corner**: all-subnets `keep_stake=true`; totals unchanged;
   `rebalance` reverts with the chain's missing-owner error;
   `try_associate_hotkey` from a substrate account; consolidation drains
   the key on the next op.
5. **Prune**: register a newcomer onto a full subnet recycling an attested
   slot; totals unchanged; the newcomer never appears as a move target;
   then swap the pruned key (`keep_stake=false`) and walk
   trip → demonstrate → resume.
6. **Trim**: `sudo_trim_to_max_allowed_uids`; totals unchanged; re-attest;
   swap-following works again.
7. **Registry round-trip**: attest with uids against the live metagraph;
   a deliberately stale uid reverts in-range-mismatch; an out-of-range uid
   reverts cleanly without burning the batch.
8. **Floors**: whole-position move at/below/above the real 100k transfer
   minimum; sub-floor demonstration residue behaves as specified.
9. **Consumer profile**: measure `previewUnwrap` gas on the live node;
   project the TAO20 mint call pattern; assert `unwrap` under a 2.5M
   stipend with margin.
10. **Share-pool dips**: co-nominator add/remove/emission churn while
    reading a tracked position every block; record any transient dip below
    a prior read. If observed, the tolerance decision is made explicitly
    with the recorded data — never silently.

## 17. Changes outside `src/`

- `e2e/alpha_e2e/environment.py` (reads the old `lastSeenHotkeys` view) and
  the three e2e tests asserting on it — migrate to `trackedSlots`.
- `scripts/get_vault_state.py` — new `getValidators` tuple shape.
- `test/mocks/MockValidatorRegistry.sol` — carries uids and owners.
- `src/interfaces/IValidatorRegistry.sol` — new signature;
  `src/interfaces/IMetagraph.sol` — new file for the metagraph precompile.

## 18. Out of scope

- Validator-cap expansion (three slots; the widened internals leave it a
  registry-shape change later).
- Subtensor-side changes.
- Migration of live vault positions (see the deployment assumption in the
  header).
- Mailbox flows beyond §6's deposit routing: reclaim paths are
  caller-directed per hotkey and unchanged.
- TAO20-side changes: none required; §11 states the guarantees and the one
  view-revert addition it must tolerate.
