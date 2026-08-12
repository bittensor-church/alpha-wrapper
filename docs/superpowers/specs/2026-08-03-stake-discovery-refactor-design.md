# Stake discovery: metagraph enumeration + per-position stake reads

Approved design, 2026-08-03. Written against:

- `~/Projects/alpha-wrapper` @ `781b14b` (main)
- `~/Projects/subtensor` @ `e4ffa2e13` (main, runtime v440) — all subtensor
  refs below

The validator cap stays at 3; vault internals are dynamic, so a later cap
expansion is a registry-only change.

## 1. Architecture

The vault stores no record of where its stake sits. Every operation discovers
the truth from the chain:

- the subnet's registered hotkeys are enumerated through the metagraph
  precompile and unioned with the attested validator set,
- the vault's amount under each candidate is read with the per-position stake
  getter,
- one scalar per tokenId (`accountedAlpha`) is a fail-closed accounting
  checksum that gates trading and never feeds pricing,
- stranded positions are recovered through a permissionless **move-only**
  function,
- genuine losses are reconciled through an owner-gated, non-subtractive
  **re-anchor**.

A registered validator's hotkey swap is a non-event: the swap rebinds the uid
in the same extrinsic, so enumeration keeps seeing the position wherever the
chain puts it. Swaps by or into unregistered identities fail closed and are
recoverable (or explicitly recognized as losses) — never silently mispriced.

## 2. Chain facts this design stands on (verified 2026-08-03, runtime v440)

1. `getStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid) → uint256` —
   staking precompile V2 at `0x0000000000000000000000000000000000000805`
   (`precompiles/src/staking.rs:336-356`): reads
   `get_stake_for_hotkey_and_coldkey_on_subnet`, charging the worst-case
   transitional V1/V2 fallback of 7 db reads (4,375 gas) per call, recorded
   before the read. A zero or unknown hotkey reads as zero — no revert path
   for absent positions.
2. Metagraph precompile at `0x0000000000000000000000000000000000000802`:
   `getUidCount(uint16) → uint16` (1 db read), `getHotkey(uint16, uint16) →
   bytes32` (1 db read, `precompiles/src/metagraph.rs:163-172`). `getHotkey`
   reverts (`InvalidRange`) on a uid with no key. Error-class precompile
   failures (`InvalidRange`, a disabled precompile) consume all forwarded
   gas. Uids `0..getUidCount-1` are contiguously assigned on a live subnet —
   see fact 10 for why enumeration is blackout-gated during dissolution.
3. db read = 625 gas (`weight_per_gas` = 3e12/75e6 = 40,000 weight/gas;
   RocksDB read = 25M ref-time). EVM block gas limit 75M
   (`runtime/src/lib.rs:1047`). Per enumerated uid, discovery pays one
   `getHotkey` plus one `getStake` (~6k gas with call overhead): ≈ 1.6-1.8M
   at the 256-uid cap.
4. Neuron pruning (`replace_neuron`, `subnets/uids.rs:62`) rebinds the uid and
   strips `Uids`/`Keys`/`IsNetworkMember` from the old hotkey but touches no
   stake storage — the pruned hotkey's alpha positions persist, invisible to
   uid enumeration. Pruning fires inside a newcomer's registration
   (`subnets/registration.rs:27-29`): third-party-timed.
5. **Hotkey swaps (v440 semantics — four distinct modes).**
   `swap_hotkey_v2(hotkey, newHotkey, Option<netuid>, keep_stake)` lets the
   caller choose `keep_stake`; the legacy `swap_hotkey` hardcodes
   `keep_stake=false` (`macros/dispatches.rs:843-878`). Uid/Keys/membership
   always rebind to the new hotkey (`swap/swap_hotkey.rs:636-645`); alpha
   positions move only when `keep_stake == false` (`:774+`). The all-subnets
   path removes `Owner(old_hotkey)` unconditionally (`:393`); the one-subnet
   path keeps it (`:530`). Consequences:
   | Mode | Chain result | Vault behavior |
   |---|---|---|
   | all-subnets, `keep_stake=false` | stake+uid → new; old ownerless | Position visible under new (registered). Old is not in the enumerated set → never a move target (§6). Consolidation may hop the position to another live attested validator until re-attestation: churn, no loss. |
   | one-subnet, `keep_stake=false` | stake+uid → new; old keeps Owner | Same as above; old is unregistered → never a target. |
   | one-subnet, `keep_stake=true` | uid → new; stake stays on old (exists) | Old visible while attested; drained by any op while visible (§5); if the registry rotates to new with no op in between, old is invisible → `BackingShort` trip → `recoverStray(old)` moves it back. Documented freeze window. |
   | all-subnets, `keep_stake=true` | uid → new; stake stays on old, **ownerless** | Moves and unstakes on the old hotkey revert while it has no owner record (`hotkey_account_exists` = `Owner.contains_key`, `staking/helpers.rs:207`; required by moves `stake_utils.rs:1310-1319` and unstakes `:1213-1216`), so the position freezes rather than strands: any signed substrate account restores the record with the permissionless `try_associate_hotkey(old_hotkey)` (`macros/dispatches.rs:1521-1529` → `staking/helpers.rs:127-140`, insert-only so an owned hotkey cannot be hijacked), after which `recoverStray` moves it normally. Affects every delegator of that validator, not just the vault. |
6. **Two distinct chain floors.** Same-subnet moves/transfers require
   `tao_equivalent >= DefaultMinTransfer` = **100,000 RAO (0.0001 TAO)** on
   v440 (`staking/stake_utils.rs:1045`, `runtime/src/lib.rs:819`). Unstake
   sizing is governed separately (staking floor family, 2e6-anchored;
   full-balance unstakes are floor-exempt). No precompile exposes the
   transfer minimum, so the vault mirrors it with an owner-tunable value.
7. **Governance nomination clearing.** Root raising the nominator threshold
   immediately runs a global clearing pass (`pallets/admin-utils/src/lib.rs:
   1149-1162`). The clone is always a pure nominator, so its sub-threshold
   positions are eligible: each is force-unstaked at min price, and **if the
   unstake errors, the alpha is deleted outright**
   (`staking/helpers.rs:227-270`). Mainnet threshold on 2026-08-03: 20e6 RAO
   (0.02 TAO). Both branches shrink vault alpha without a vault op.
8. Vault-origin alpha is otherwise monotone outside vault-signed operations:
   emission only adds; pruning moves nothing; registered-validator swaps
   re-key atomically with the uid rebind.
9. **Exact per-position monotonicity of the stake getter is unproven.** The
   getter is a fixed-point floor over a share pool
   (`primitives/share-pool/src/lib.rs:420-434`); co-nominator churn moves the
   numerator and denominator and 1-RAO transient dips cannot be excluded from
   a source read. The design must tolerate micro-dips without weakening the
   tripwire (§9 cures; §13 mandatory property test).
10. **Dissolution is phased, and the uid count falls first.** The cleanup
    driver removes the scalar network parameters — including the uid count —
    before it starts clearing the `Keys` map (`subnets/dissolution.rs:827-843`
    phase order; `SubnetworkN::remove` at `:273`, metered `Keys::clear_prefix`
    at `:147-148`): a window exists where `getUidCount` reads **zero** while
    keys and stake teardown are still in progress. Unguarded discovery would
    not revert there — it would silently degrade to the attested set and
    report a near-zero total. Every discovery caller, views included, must
    therefore sit behind the dissolution blackout. Dissolution converts every
    alpha position to TAO credited to the staker coldkey's balance
    (settlement in `staking/remove_stake.rs:650-832`, dispatched from
    `dissolution.rs:691-785`); the vault's blackout + dissolved path handles
    this state.
11. **Uid cap is hard at 256 on v440.** `sudo_set_max_allowed_uids` rejects
    values above `DefaultMaxAllowedUids` = 256 (`pallets/admin-utils/src/lib.rs
    :566-568`, `runtime/src/lib.rs:788`). Raising it requires a runtime
    upgrade (or a root raw-storage write — root is already in the threat
    model), either of which this design treats as a compatibility event (§12).
12. Precompiles are gated by `PrecompileEnable`; a disabled precompile errors
    on every call with an opaque, no-returndata error that consumes forwarded
    gas (`precompiles/src/extensions.rs:181-190`), and the staking V1/V2
    precompiles share a single enable flag. The metagraph precompile is
    load-bearing alongside staking (§12 runbook).

## 3. Storage and interface surface

```solidity
/// Alpha total the vault accounted for at the end of its last mutating op.
/// Gates trading (fail closed); never an input to pricing.
mapping(uint256 => uint256) public accountedAlpha;

/// Tao floor mirroring the chain's same-subnet movement minimum. Distinct
/// from minStakeTaoFloor (which mirrors the unstake-sizing floor).
uint256 public minMoveTaoFloor; // init 100_000; owner-tunable up to MOVE_FLOOR_CAP = 10_000_000

error BackingShort(uint256 accounted, uint256 discovered);
error HotkeyNotStray();
error NoLiveTarget();
error MinMoveTaoFloorTooHigh();

event StrayStakeRecovered(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 alpha);
event BackingLossAccepted(uint256 indexed tokenId, uint256 previousAccounted, uint256 newAccounted);
event MinMoveTaoFloorUpdated(uint256 oldValue, uint256 newValue);

function recoverStray(uint256 netuid, bytes32 strayHotkey) external nonReentrant;
function acceptBackingLoss(uint256 tokenId) external onlyOwner;
function setMinMoveTaoFloor(uint256 newValue) external onlyOwner;
function discoveredBacking(uint256 netuid) external view returns (uint256);
```

Interfaces: discovery reads amounts through the existing
`IStaking.getStake(bytes32, bytes32, uint256)`. New
`src/interfaces/IMetagraph.sol`: `getUidCount(uint16)`,
`getHotkey(uint16, uint16)`,
`METAGRAPH_PRECOMPILE = 0x0000000000000000000000000000000000000802`.

## 4. Discovery

```solidity
function _discoverPositions(uint16 netuid, bytes32 coldkey, bytes32[3] memory attested)
    private view
    returns (bytes32[] memory hotkeys, uint256[] memory stakes, uint256 positionCount, uint256 total, uint256 registeredCount);
```

1. `uidCount = getUidCount(netuid)`; collect `getHotkey(netuid, uid)` for
   `uid` in `0..uidCount-1`. Injective per subnet → duplicate-free.
2. Append attested hotkeys not already present, **skipping `bytes32(0)`
   slots** (the registry stores contiguous non-zero prefixes, so 1- and
   2-validator sets carry zero slots) and deduplicating against the **full
   candidate list** — an overlapping candidate read twice would inflate the
   total. Keeps a kicked-but-still-attested validator visible. The first
   `registeredCount` candidates are the registered set — callers use this
   boundary for target eligibility (§6).
3. Read `getStake(candidate, coldkey, netuid)` per candidate; results are
   index-aligned with the candidate list; sum the total; non-zero entries are
   the position set. `uidCount == 0` degrades to the attested set alone.
4. **Every** caller of discovery — views included — sits behind the
   dissolution blackout check (fact 10: enumeration is unsafe mid-cleanup).

### Working set (per mutating op, in memory)

`(bytes32 hotkey, uint256 balance, bool registered)` triples: attested slots
first in registry order (present even at zero balance), then every discovered
non-attested position (strays; all registered by construction). Balances are
updated in memory as the op moves stake, with post-move re-reads where
exactness matters.

## 5. Mutating-op skeleton

Applies to `wrap`, live-path `unwrap`, `unwrapForTao`, `rebalance`:

1. Resolve validators, blackout checks.
2. **Discover + tripwire**:
   `if (total < accountedAlpha[tokenId]) revert BackingShort(accounted, total);`
3. Run the op against the working set:
   - **Consolidation**: every position outside the attested ∩ registered
     slots — registered strays, and attested slots whose hotkey has lost its
     uid (a just-swapped or just-pruned validator) — is drained onto the
     **first eligible target** (§6) whenever its value clears
     `minMoveTaoFloor` (`_isBelowFloorAtAnyPrice` analogue against the move
     floor). Draining attested-but-unregistered slots is what keeps a stray
     from ever forming: the position is moved while the attested union still
     makes it visible, so any op (or a permissionless `rebalance` poke)
     between the chain event and the registry refresh neutralizes the race.
     Sub-move-floor residues stay in place and stay counted — rediscovered
     every op, no rescue needed. If no eligible target exists, consolidation
     is skipped entirely (positions remain visible; nothing is parked on a
     dead identity).
   - `wrap` prices shares from the discovered total *before* the mailbox
     flush; the flush destination (`chosenHotkey`) must be attested **and**
     registered, else `ChosenHotkeyNotInSet`.
   - Weight alignment computes targets over attested **and registered**
     slots only (an unregistered attested slot is zero-target — consolidation
     has already drained it) and skips any move whose destination is
     unregistered (drift over stranding).
   - **Delivery is exact-or-revert**: after the gather, the delivery slot
     must hold at least `assets - executedHops` RAO; otherwise revert. The
     1-RAO-per-hop credit allowance is a documented decision pending the
     mandatory e2e hop-credit measurement (§13). A shortfall a sub-floor
     stray population would force is therefore never silently absorbed —
     such positions exit via `unwrapForTao`, where full drains are
     floor-exempt and exact. Burning shares against backing the call cannot
     deliver would transfer the difference to remaining holders; the vault
     never does it. `previewUnwrap` quotes the same `assets`; realized
     delivery may sit below the quote only within that same executed-hop
     allowance.
4. **Re-baseline** (no second enumeration): re-read `getStake` over the
   working-set hotkeys; `accountedAlpha[tokenId] := summed total`. Immune to
   per-move rounding because it re-reads.

Dissolved/dissolving paths never discover and never touch `accountedAlpha`.

### Views

- `totalStake(tokenId)`: dissolution-guarded; then discovery total, raw (no
  tripwire) — it reports, it does not gate.
- `sharePrice`, `previewWrap`, `previewUnwrap`: existing guards, then
  discovery + `BackingShort` check — integrators never receive a silently
  undercounted quote.
- `discoveredBacking(netuid)`: dissolution-guarded (reverts
  `SubnetInDissolutionBlackoutPeriod` during cleanup — watchers must check
  `isSubnetDissolving` first, §12); otherwise the raw discovery total using
  the raw registry set (zero slots skipped).

## 6. Eligible-target rule

A hotkey is an eligible move/flush **target** iff it is in the current
attested set **and** in the current enumerated registered set. Rationale: the
registry can lag the chain (a swap or prune rebinds the uid before attesters
refresh), and v440 makes a stale attested hotkey either unregistered, or
worse, nonexistent (ownerless) — a move onto it either reverts or parks stake
on an identity no discovery can see. The registered set is already produced
by discovery, so the check is free. Sources need no such gate: everything
discovery returns is registered or attested-and-visible, and a source that no
longer exists makes the chain reject the move — failing the op closed.

When no attested hotkey is registered, all moves are skipped; `wrap` reverts
(no valid flush destination); live-path `unwrap` reverts whenever the
delivery slot cannot cover the quote without a gather (gathers need targets),
per the exact-or-revert rule; `unwrapForTao` still exits (sells need no
target); pricing is unaffected. The vault waits for re-attestation.

## 7. recoverStray — permissionless, move-only

```solidity
function recoverStray(uint256 netuid, bytes32 strayHotkey) external nonReentrant
```

The caller supplies only a location; amounts and eligibility come from the
chain. No tripwire on this path — it is the cure that runs while every other
mutating path reverts `BackingShort`. It relocates stake between
vault-controlled positions and does nothing else: it never converts stake to
TAO and **never touches `accountedAlpha`** — the baseline is a safety
reference no permissionless caller may influence in either direction. The
move path only raises the discovered total, so ops resume by themselves once
it covers the baseline.

1. `tokenId = currentTokenId(netuid)`; clone must exist; dissolution blackout;
   `ZeroHotkey` guard.
2. `strayHotkey` in the attested set → `HotkeyNotStray()` (registered
   non-attested hotkeys are allowed: harmless early consolidation).
3. `amount = getStake(strayHotkey, cloneColdkey, netuid)`; zero → `ZeroAmount`.
4. Run discovery once (rare path; gas is acceptable) to obtain the registered
   set; pick the first eligible target per §6; none → `NoLiveTarget()`.
5. `moveStake(strayHotkey → target, amount)`; emit `StrayStakeRecovered`.
   A sub-move-floor amount or a nonexistent source makes the chain reject the
   move and the call revert — those states are handled by donation top-up or
   `acceptBackingLoss` (§9).

## 8. acceptBackingLoss — owner-gated, re-anchoring, never subtractive

```solidity
function acceptBackingLoss(uint256 tokenId) external onlyOwner
```

Requires `discovered < accountedAlpha[tokenId]` (there must be a shortfall to
accept). Sets `accountedAlpha[tokenId] := discovered total` (fresh discovery
inside the call) and emits `BackingLossAccepted(tokenId, old, new)`.

Safety argument: the baseline is only ever written from a *discovered
total* — at op end or here — never adjusted by a caller-influenced delta.
Re-anchoring to current truth leaves **zero slack**: any position hidden at
acceptance time is excluded from protection (that is the disclosed loss), but
every future disappearance still trips, because the new baseline equals what
discovery actually sees. Pricing never reads the baseline, so the owner
cannot misprice the vault through this function — only re-enable trading at
the truthful discovered price. Abuse surface is bounded to unfreezing early,
publicly visible through the event.

Used for the terminal/loss states: all-subnets `keep_stake=true` swap residue
(fact 5), governance clearing including its delete-on-error branch (fact 7 —
TAO proceeds, when they exist, land on the clone and flow to holders through
the existing claim index automatically), and root coldkey swap of the clone.
Leaving the vault frozen instead is always available by simply not calling it.

## 9. Shortfall cures (complete set)

| Shortfall cause | Cure | Who |
|---|---|---|
| Swap/prune left stake on an attested-but-unregistered hotkey (pre-refresh window) | any op, or a permissionless `rebalance(netuid)` poke, drains it while still visible — the stray never forms | anyone |
| Stake visible off-set but movable | consolidation (in-op) or `recoverStray` | anyone |
| Stake hidden (pruned + rotated out; one-subnet `keep_stake=true` after refresh) | `recoverStray(hotkey)` — location from one RPC read of the chain's coldkey→hotkeys index (§12) | anyone |
| Stake under an ownerless hotkey (all-subnets `keep_stake=true`) | substrate `try_associate_hotkey(hotkey)` to restore the owner record, then `recoverStray(hotkey)` | anyone (operator preferred, §12) |
| Micro-dip (share-pool rounding, fact 9) or sub-move-floor stranded dust | donation top-up: any stake transferred to the clone coldkey under a registered hotkey raises the discovered total above the baseline (~0.0001 TAO minimum) | anyone |
| Genuine loss (clearing delete-branch, root coldkey swap) | `acceptBackingLoss` re-anchor | owner |

## 10. Accepted trade-offs

1. **Donations count.** Third-party stake parked for the clone coldkey under
   *registered* hotkeys is backing. Bounded by the 256-uid cap;
   inflation-attack surface covered by the virtual-shares math. Under
   unregistered hotkeys it is invisible and inert until moved in via
   `recoverStray` (also a donation).
2. **Alpha-rail exits are exact-or-revert.** No under-delivery band. A
   position whose movable backing cannot cover the quoted assets reverts and
   exits via `unwrapForTao`.
3. **Views revert instead of degrading**: `BackingShort` during a stranded
   window, the blackout error during dissolution cleanup.
4. **Per-op discovery gas**: ≈ 2.5-3M gas worst case per mutating op at the
   256-uid cap (start-of-op discovery plus the end-of-op re-baseline reads;
   `recoverStray` runs one discovery). Views are free off-chain.
5. **Freeze windows are accepted operational states**: one-subnet
   `keep_stake=true` swaps after registry refresh, and prune+rotation races,
   trip the vault until a permissionless cure lands. Frozen beats mispriced.

## 11. Known freeze / loss states (explicit)

**Recoverable, two-step (freeze, not loss):** an all-subnets
`keep_stake=true` swap leaves the position under an ownerless hotkey. The
vault trips, and the cure runs off the EVM first: any signed substrate
account calls `try_associate_hotkey(oldHotkey)` to restore the owner record
(insert-only, so it cannot hijack an owned hotkey), after which the
permissionless `recoverStray(netuid, oldHotkey)` moves the position onto a
live validator and ops resume. The operator should be the associating account
so the restored owner is not a stranger who could swap the hotkey again to
grief; a stranger can only relocate positions, never seize them, since each
position stays keyed to its staker's coldkey.

**Genuine losses (`acceptBackingLoss`):**

- Governance clearing delete-branch (fact 7): alpha deleted with no proceeds
  and no state left to recover.
- Root `swap_coldkey` of the clone: positions re-key to a coldkey the vault
  does not control. Permanent freeze is the correct response; explicit
  `acceptBackingLoss` to zero applies only if holders are compensated another
  way.

## 12. Operational requirements (load-bearing)

Recovery is *initiated* on-chain but *located* off-chain. These are explicit
production dependencies, not conveniences:

1. **Watcher loop** (permissionless, stateless): if `isSubnetDissolving` →
   skip; else compare `discoveredBacking(netuid)` to
   `accountedAlpha[currentTokenId(netuid)]`. On shortfall, read the chain's
   coldkey→hotkeys index (`StakingHotkeys(cloneColdkey)`) via RPC state query
   at current height — no archive node, no indexer — diff against the
   enumerated set, and call `recoverStray` for each hidden location.
2. **Attestation ordering (stray prevention)**: on a swap or prune event
   touching an attested validator, poke the permissionless
   `rebalance(netuid)` *before* re-attesting — consolidation drains the
   attested-but-unregistered slot while the attested union still makes it
   visible. Never drop a hotkey from a subnet's attested set while the clone
   still holds stake under it (one `getStake` read to verify). Under this
   ordering, hidden strays require a policy violation, not just bad timing.
3. **Ownerless-hotkey cure**: when a shortfall traces to a hotkey whose owner
   record is gone (moves and unstakes on it revert), send
   `try_associate_hotkey(hotkey)` from the operator's own substrate account
   before calling `recoverStray`. Restoring the record from an operator key
   keeps the hotkey out of a stranger's hands; the vault's clone coldkey
   cannot do this itself (it signs only through precompiles).
4. **Threshold monitoring**: watch the nominator threshold
   (`getNominatorMinRequiredStake`, already consumed by the vault) — a raise
   is an immediate clearing event for sub-threshold slots (fact 7).
5. **Runtime-upgrade policy**: pin supported spec versions. An upgrade that
   changes the transfer minimum, the uid cap, precompile ABIs/addresses,
   dissolution behavior, or gas weights is a compatibility event: verify the
   floors and re-run the e2e matrix before resuming operations.
   `PrecompileEnable` for staking + metagraph is part of the same watch
   (fact 12); a disabled precompile shows up as ops reverting with the
   chain's disable error, distinguishable from `BackingShort` and from the
   blackout error.
6. **Bytecode budget**: `AlphaVault` runtime code is 22,293 bytes today —
   2,283 under EIP-170. `forge build --sizes` is a hard gate in the plan; if
   the margin is exceeded, discovery/recovery move to an external library.

## 13. Test plan

Mocks (they must model the chain behavior that decides safety here, not just
balances):

- `MockStaking`: **hotkey existence** (`Owner`-equivalent flag) with
  moves/unstakes reverting for nonexistent hotkeys; the same-subnet move
  floor (100k RAO tao-equivalent) enforced on moves; full-drain exemption on
  unstakes only.
- `MockMetagraph`: uid-indexed hotkeys, out-of-range revert, and a helper
  zeroing the uid count while positions persist — the state phased
  dissolution produces (fact 10).
- Swap semantics, all four modes: uid rebind always; stake re-key iff
  `keep_stake == false`; owner removal iff all-subnets.
- Prune semantics: uid rebind, stake untouched.
- Clearing semantics: force-conversion of sub-threshold nominations plus the
  delete-on-error variant.
- Donation helper; share-pool dip helper (shave a position by single RAO) for
  fact-9 rounding.

Suites (naming per repo convention):

- Unit: tripwire trips on stranding, quiet through all registered-validator
  swap modes; eligible-target gating (stale attested hotkey never a
  destination; `NoLiveTarget` when none registered); wrap pre-flush pricing +
  registered `chosenHotkey` gate; exact-or-revert delivery incl. the
  hop-bounded rounding allowance; `recoverStray` move path, `HotkeyNotStray`,
  `ZeroAmount`, `NoLiveTarget`, chain-rejected sub-floor move;
  `acceptBackingLoss` re-anchor + event + only-on-shortfall; donation cure;
  view blackout during phased dissolution (the blackout error fires before
  any discovery read while the uid count reads zero and stakes persist);
  single-validator registry (zero attested slots skipped, no double-counted
  candidates); both floors used on their correct paths.
- Fuzz: random op/swap(4 modes)/prune/donation/clearing interleavings —
  invariant: every op executes against the true discovered total or reverts
  `BackingShort`; share value preserved across registered swaps at any point;
  post-baseline donation + recovery can never lower the pre-existing
  baseline; multiple simultaneous hidden locations — recovering one never
  masks another (baseline covers their sum until each is cured or accepted);
  full-supply `unwrapForTao` exit with up to 256 sub-move-floor strays.
- Invariant suite (handler tracks a ground-truth position ledger, hidden
  states persist across arbitrary sequences): (a) ops enabled ⇒ quoted
  backing equals complete chain truth; (b) `accountedAlpha` is only ever a
  value some discovery actually returned (never caller-adjusted); (c) a
  stale attested identity is never a move destination; (d) every share burn
  delivers its quoted assets within the hop-rounding bound or reverts.
- **Localnet e2e — mandatory before deployment.** The mocks encode chain
  semantics by hand; only a real runtime validates them: all four
  `swap_hotkey_v2` modes against a wrapped position; a real prune via
  registration on a full subnet; stale-registry window (swap before
  re-attestation — assert no move to the stale identity);
  `HotKeyAccountNotExists` surfacing; the real 100k move floor and 20e6
  nomination threshold boundaries; measured per-hop move-credit deficit
  (validates the exact-or-revert allowance in §5); co-nominator churn
  against the real share pool (characterize getter dips — if dips are
  observed, decide between the donation cure alone and an explicit
  comparison epsilon as a documented decision); phased-dissolution view
  behavior (blackout error, not a silent near-zero total);
  `PrecompileEnable` off/on.

## 14. Out of scope

- Validator cap changes (registry stays at 3; vault internals are dynamic).
- Subtensor-side changes.
- Mailbox flows — caller-directed per hotkey; mailbox stake under a swapped
  hotkey is user-recoverable via
  `reclaimAlphaFromMailbox(netuid, strayHotkey, dest)`.
