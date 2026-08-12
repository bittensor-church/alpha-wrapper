# Backing watermarks: swap-proof accounting for AlphaVault

Approved design, 2026-08-03. Written against:

- `~/Projects/alpha-wrapper` @ `781b14b` (main)
- `~/Projects/subtensor` @ `e4ffa2e13` (main, runtime v440) — all subtensor
  refs below

## 1. Architecture

The vault reads its stake from a small tracked set of hotkeys (the last-seen
validator set united with the currently attested set). A validator's hotkey
swap re-keys the vault's stake to a hotkey outside that set, so the vault's
reads go to zero while the stake still exists: share pricing collapses,
deposits mint too many shares, and exits underpay.

This design makes that detection unconditional with one watermark per
tracked position:

- `backingWatermark[tokenId][hotkey]` — the position's balance as last
  observed by the vault. Every mutating operation and every pricing view
  first re-reads each tracked position and reverts `BackingShort` if **any**
  position sits below its own watermark. A swap always moves a position in
  full (§2 fact 2), so a swapped slot reads zero against a positive
  watermark and trips on the next touch — no matter how much other slots
  grew in the meantime, and with no dependency on anyone calling anything
  first. Per-position comparison is what makes growth in one slot unable to
  conceal a loss in another; there is deliberately no aggregate to hide in
  and no mechanism that nets one slot's surplus against another's deficit.
- `recoverStray(netuid, strayHotkey, targetSlot)` — permissionless. Whoever
  knows where the chain moved the stake names the location; the vault reads
  the true amount from the chain, moves it onto an attested validator, and
  shifts watermark from the deficit slots to the target — capped by both the
  amount actually moved and the deficits that exist, so the watermark total
  is conserved and no caller can erode protection. Operations resume by
  themselves once no deficit remains.
- `checkpointBacking(netuid)` — permissionless, raise-only per slot: lifts
  each watermark to the position's current balance. This is hardening, not
  a load-bearing part of detection: it brings growth that accrued since the
  last operation (emission, donations) under protection sooner. Skipping it
  never weakens the swap guarantee — it only leaves recent growth
  unprotected until the next operation observes it.
- `proposeBackingLoss(tokenId)` / `acceptBackingLoss(tokenId)` — owner-only,
  two-step with a 72-hour delay, for the rare events that genuinely destroy
  stake. Acceptance re-anchors every watermark to the then-current reads so
  trading resumes at the truthful (lower) price; it executes only if a
  deficit still exists, so a recovery landing during the delay voids it.

Watermarks gate; they never price. Share prices always come from live chain
reads, so no caller can misprice the vault through the watermarks — only
halt or un-halt it, and un-halting below truth requires the owner plus 72
public hours during which anyone can cure the deficit instead.

Everything else in the vault — tracking, consolidation, rebalancing, the
mailbox flows, dissolution handling — keeps its current shape. Two
corrections ship alongside: the vault's move pre-checks gain their own floor
matching the chain's transfer minimum (§8), and alpha delivery becomes
exact-or-revert (§9).

## 2. Chain facts this design stands on (verified 2026-08-03, runtime v440)

1. **Vault-origin alpha is monotone outside vault-signed operations, and
   grows continuously.** Emission credits nominator positions every block
   cycle (`coinbase/run_coinbase.rs`); neuron pruning rebinds the uid but
   touches no stake storage (`subnets/uids.rs:62`,
   `subnets/registration.rs:27-29`). A tracked position reading below its
   last observed value therefore always means the stake was re-keyed away or
   destroyed (see fact 6 for the one rounding caveat).
2. **Hotkey swaps move entire positions, in four modes.** `swap_hotkey_v2(
   hotkey, newHotkey, Option<netuid>, keep_stake)` lets the validator choose
   scope and whether stake follows; the legacy `swap_hotkey` hardcodes
   `keep_stake=false` (`macros/dispatches.rs:843-878`). Uid and membership
   always rebind (`swap/swap_hotkey.rs:636-645`); when stake follows, the
   migration loop reads each position's full balance and moves all of it —
   there is no partial re-key (`:774+`). The all-subnets path deletes the
   old hotkey's owner record unconditionally (`:393`); the one-subnet path
   keeps it (`:530`). Swaps burn a fee; the per-subnet cooldown binds only
   where the old hotkey is a member or parent (`:238-249`) — a pruned hotkey
   holding vault stake is not necessarily rate-limited on that subnet. No
   other third-party path partially drains a position: governance clearing
   removes positions whole (fact 5), and only the clone's coldkey signs
   vault outflows.
3. **Owner records gate stake operations, and anyone can restore one.**
   Moves and unstakes require the hotkey's owner record to exist
   (`hotkey_account_exists` = `Owner.contains_key`, `staking/helpers.rs:207`;
   asserted at `stake_utils.rs:1310-1319` and `:1213-1216`). A hotkey left
   ownerless (fact 2, all-subnets + `keep_stake=true`) freezes its positions
   — but the permissionless extrinsic `try_associate_hotkey(hotkey)`
   (`macros/dispatches.rs:1521-1529`) re-creates the record, insert-only, so
   it cannot hijack an owned hotkey (`staking/helpers.rs:127-140`, pallet
   test `test_try_associate_hotkey`). Frozen positions are therefore
   recoverable, and pricing them as backing is honest.
4. **Two distinct chain floors, and the move floor has no full-drain
   exemption.** Same-subnet moves and transfers require a tao value of at
   least `DefaultMinTransfer` = **100,000 RAO (0.0001 TAO)** — including
   whole-position moves (`staking/stake_utils.rs:1035-1048`,
   `runtime/src/lib.rs:819`). Unstake sizing is governed separately
   (2e6-anchored staking floor family; full-balance unstakes are exempt).
   No precompile exposes the transfer minimum, so the vault mirrors it with
   an owner-tunable value.
5. **Governance nomination clearing can destroy alpha.** Root raising the
   nominator threshold runs a global clearing pass
   (`pallets/admin-utils/src/lib.rs:1149-1162`); the clone is a pure
   nominator, so its sub-threshold positions are force-unstaked whole at min
   price, and if the unstake errors the alpha is **deleted outright**
   (`staking/helpers.rs:227-270`). Mainnet threshold on 2026-08-03: 20e6 RAO.
6. **Stake reads and credits round.** The position getter floors a
   fixed-point share computation (`primitives/share-pool/src/lib.rs:420-434`)
   — co-nominator churn could transiently dip a read by 1 RAO — and every
   same-subnet move or transfer credits the destination through the same
   rounded arithmetic (`stake_utils.rs:957-1011`), so each executed leg can
   land marginally short. The cure table (§7) covers dips with a direct
   top-up; delivery accounting budgets one RAO per executed leg (§9); the
   localnet plan (§13) measures both.
7. `getStake(hotkey, coldkey, netuid)` on the staking precompile charges a
   flat 7 db reads = 4,375 gas per call (`precompiles/src/staking.rs:336-356`,
   625 gas per db read), and reads of absent positions return zero.

## 3. Contract surface

```solidity
/// Last observed balance per tracked position. Gates trading (fail closed);
/// never an input to pricing.
mapping(uint256 => mapping(bytes32 => uint256)) public backingWatermark;

/// Pending owner loss acceptance: proposal timestamp per token (0 = none).
mapping(uint256 => uint256) public backingLossProposedAt;

uint256 public constant LOSS_ACCEPTANCE_DELAY = 72 hours;

/// Tao floor mirroring the chain's same-subnet movement minimum. Distinct
/// from minStakeTaoFloor (which mirrors the unstake-sizing floor).
uint256 public minMoveTaoFloor; // init 100_000; owner-tunable up to MOVE_FLOOR_CAP = 10_000_000

error BackingShort(bytes32 hotkey, uint256 watermark, uint256 current);
error HotkeyNotStray();
error InvalidTargetSlot();
error NoBackingDeficit();
error NoPendingBackingLoss();
error LossAcceptanceDelayNotMet();
error MinMoveTaoFloorTooHigh();

event BackingCheckpointed(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 previousWatermark, uint256 newWatermark);
event StrayStakeRecovered(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 alpha, uint256 watermarkShifted);
event BackingLossProposed(uint256 indexed tokenId, uint256 deficit);
event BackingLossAccepted(uint256 indexed tokenId, uint256 clearedDeficit);
event MinMoveTaoFloorUpdated(uint256 oldValue, uint256 newValue);

function checkpointBacking(uint256 netuid) external;
function recoverStray(uint256 netuid, bytes32 strayHotkey, uint256 targetSlot) external nonReentrant;
function proposeBackingLoss(uint256 tokenId) external onlyOwner;
function acceptBackingLoss(uint256 tokenId) external onlyOwner;
function setMinMoveTaoFloor(uint256 newValue) external onlyOwner;
function trackedBacking(uint256 netuid) external view returns (uint256);
function backingDeficit(uint256 netuid) external view returns (uint256);
```

No interface changes: everything reads through the existing `IStaking`,
`IAlpha`, `ISubnet`, and `IAddressMapping` surfaces. No storage is removed;
`_lastSeenHotkeys` and the existing consolidation remain as they are.

## 4. Watermark mechanics

**Check set.** The union `_unionStake` already reads — last-seen hotkeys plus
the current attested set, deduplicated, at most six positions — which by
construction contains every hotkey that held a watermark at the end of the
previous operation (the last-seen set is refreshed only after a clean
consolidation, and departures are re-baselined to zero at that moment).

**Check.** Every mutating operation (`wrap`, live-path `unwrap`,
`unwrapForTao`, `rebalance`) walks the check set after its existing guards —
for `wrap`, before the mailbox flush, so a deposit can never paper over a
deficit — and reverts `BackingShort(hotkey, watermark, current)` on the
first position reading below its watermark. `recoverStray` and
`checkpointBacking` are exempt — they are the paths that restore coverage.

**The guarantee.** A swap moves a position in full (fact 2), so a swapped
tracked slot reads zero against a positive watermark and trips on the next
touch — unconditionally: with no checkpoint ever called, at any emission
rate, after any idle period. Growth on other slots cannot mask it because
no comparison sums slots, and no permissionless mechanism nets one slot's
surplus against another's deficit (that absence is load-bearing: any such
netting would re-create aggregate masking).

**What is not protected until observed:** growth itself. Emission and
donations accrued since the last observation sit above the watermark and are
not yet gated. A swap steals nothing extra from that: the swapped slot still
trips on its full watermark; only the unobserved growth rides along into the
recoverable stray, and recovery brings it back. `checkpointBacking` narrows
this unprotected-growth lag; it is cadence-flexible because nothing about
detection depends on it.

**Watermark writers — the complete list.** All from freshly read balances or
verified stake movements, never from bare caller input:

1. End-of-op re-baseline: every mutating operation ends by re-reading the
   check set (old tracked ∪ new tracked) and writing each watermark to the
   fresh read — including zeroing departed hotkeys, which a clean
   consolidation has just drained.
2. `checkpointBacking(netuid)`: per-slot raise-only —
   `watermark := max(watermark, current)` — emitting `BackingCheckpointed`
   per raised slot. Raising can only widen protection, and nothing that
   raises a balance is reversible by the caller (emission and donations
   cannot be pulled back out; only the clone signs outflows).
3. `recoverStray`: shifts watermark along with verifiably moved stake (§5) —
   conserving the per-token watermark total.
4. `acceptBackingLoss`: the only writer that can reduce the watermark total,
   owner-gated and delayed (§6).

**Views.** `sharePrice`, `previewWrap`, and `previewUnwrap` perform the same
per-slot check before quoting, so integrators can never read a quote the
vault knows is undercounted. `totalStake` stays a raw reporter.
`trackedBacking(netuid)` exposes the live tracked total and
`backingDeficit(netuid)` the summed per-slot deficits (zero when healthy) —
a watcher's whole loop is one `eth_call` each.

Dissolving and dissolved paths keep their existing blackout and TAO-refund
behavior; they neither check nor write watermarks, and `checkpointBacking`
reverts during the blackout.

## 5. recoverStray — permissionless, move-only, watermark-conserving

```solidity
function recoverStray(uint256 netuid, bytes32 strayHotkey, uint256 targetSlot) external nonReentrant
```

1. Guards: netuid in range, clone exists, subnet not dissolving, non-zero
   `strayHotkey`, `targetSlot` indexes a non-zero attested hotkey
   (`InvalidTargetSlot`), `strayHotkey` not itself attested (`HotkeyNotStray`).
2. `amount = getStake(strayHotkey, cloneColdkey, netuid)`; zero → `ZeroAmount`.
3. Move the full amount onto `attested[targetSlot]` through the clone.
4. Walk the check set in its fixed order and shift watermark onto the target:
   for each slot with a deficit, `shift = min(remaining amount, deficit)`;
   reduce that slot's watermark by `shift`, accumulate; add the accumulated
   total to the target hotkey's watermark. Emit `StrayStakeRecovered` with
   the amount and the watermark shifted.

The caller is trusted for nothing but locations: the amount comes from the
chain, the destination must be attested, and the chain rejects a move whose
source lacks an owner record or whose value is below the transfer minimum —
a bad call reverts and changes nothing. The watermark shift is capped by
both the stake actually moved and the deficits that actually exist, and the
per-token watermark total is conserved, so repeated or adversarial calls
cannot erode protection — they can only relocate stake the vault already
owns onto validators the registry already trusts. Stake moved in excess of
existing deficits simply lands above the target's watermark as unobserved
growth, captured at the next observation.

The natural caller is whoever ran the swap — the validator wants the
delegation following them — with the operator's watcher as backstop (§12).

## 6. Loss acceptance — owner-gated, delayed, re-anchoring

```solidity
function proposeBackingLoss(uint256 tokenId) external onlyOwner
function acceptBackingLoss(uint256 tokenId) external onlyOwner
```

`proposeBackingLoss` requires a live deficit (`NoBackingDeficit` otherwise),
records the proposal time, and emits `BackingLossProposed` with the summed
deficit. `acceptBackingLoss` executes no earlier than
`LOSS_ACCEPTANCE_DELAY` (72 hours) after the proposal
(`LossAcceptanceDelayNotMet`; `NoPendingBackingLoss` without one), requires
a deficit to **still** exist, re-reads the check set, writes every watermark
to its fresh read, clears the proposal, and emits `BackingLossAccepted`.

Why the delay is load-bearing: an immediate re-anchor during a *recoverable*
deficit would reopen trading against totals that exclude recoverable value —
cheap mints for whoever deposits first, the owner included. The delay turns
loss acceptance into a public claim — "this stake is gone" — that anyone has
72 hours to falsify by curing the deficit (`recoverStray`, association,
top-up), which makes the acceptance revert. Genuine losses (§7) survive the
delay because there is nothing to recover. The vault stays safely frozen
throughout; declining to accept leaves it frozen indefinitely.

Because the new watermarks equal what the reads return at execution,
acceptance creates zero slack: every future disappearance still trips. And
because pricing never reads watermarks, acceptance can only re-enable
trading at the truthful price of the moment it executes.

## 7. Chain events and cures (complete)

| Event | Vault behavior | Cure | Who |
|---|---|---|---|
| Swap, stake follows (`keep_stake=false`, either scope) — the common mode | Whole position leaves its tracked slot → zero under a positive watermark → next touch trips, unconditionally | `recoverStray(new hotkey)`; or no trip at all if attesters re-attest the new hotkey before any op runs | anyone |
| Swap, one subnet, stake stays (`keep_stake=true`) | Non-event: stake remains on the tracked hotkey, which keeps its owner record | existing consolidation absorbs it | — |
| Swap, all subnets, stake stays (old hotkey loses its owner record) | Stake remains tracked and counted (recoverable, so counting it is honest); moves and sells touching it revert until cured | substrate `try_associate_hotkey(old)` restores the record, then `recoverStray(old)` | anyone (operator preferred, §12) |
| Validator pruned from the subnet | Non-event: tracked reads are registration-independent and the hotkey keeps its owner record | existing consolidation absorbs it | — |
| Sub-move-floor stray (a small slot re-keyed away) | Trip on that slot's watermark; `recoverStray` alone reverts (fact 4: no full-drain exemption on moves) | top the stray up past the transfer minimum via `transferStake`, then `recoverStray` the whole position; or top up **the deficit slot itself** to its watermark (a donation to holders equal to the deficit — by definition below 0.0001 TAO per stray) | anyone |
| Read dip from share-pool rounding (fact 6, if it occurs) | Trip by a few RAO on the dipped slot | top up that slot (transfer minimum applies, ~0.0001 TAO) — or wait: the slot's own emission re-clears it | anyone |
| Governance clearing, sale branch | Trip on the cleared slot; sale proceeds land on the clone as TAO and flow to holders through the existing claim index | propose + accept loss (§6) | owner |
| Governance clearing, delete branch (alpha destroyed) | Trip on the cleared slot | propose + accept loss | owner |
| Root coldkey swap of the clone | Every slot trips, permanently | remain frozen (correct), or propose + accept if holders are compensated another way | owner |

## 8. Floors

`minMoveTaoFloor` (init 100,000 RAO, capped at 10,000,000) gates every
pre-check on a move or transfer: consolidation moves, rebalance moves,
gather hops, the deposit flush, and delivery. `minStakeTaoFloor` (existing,
init 2e6) keeps gating unstake sizing in the sell paths. Each vault-side
pre-check mirrors exactly one chain-side check; the implementation records
that mapping with subtensor citations in the PR description.

## 9. Exact-or-revert delivery

On the alpha rail, the delivery slot must cover the quoted assets to within
one RAO per executed transfer leg — gather hops plus the final delivery
transfer, since every leg credits through the same rounded share-pool
arithmetic (fact 6); otherwise the operation reverts. Burning shares against
backing the call cannot deliver would transfer the difference to remaining
holders; the vault never does it. Positions that cannot be gathered —
sub-move-floor residue — exit through `unwrapForTao`, where full drains are
exempt from chain floors and exact. `previewUnwrap` quotes the same assets;
realized delivery may sit below the quote only within the same per-leg
allowance. The one-RAO-per-leg constant is a documented decision pending the
localnet leg-credit measurement (§13).

## 10. Accepted trade-offs

1. **Common-mode swaps freeze the vault until cured.** The freeze is
   fail-closed, the cure is permissionless and usually single-call, swaps
   burn a chain fee, and re-attestation before the next op avoids the trip
   entirely. The chain's per-subnet swap cooldown limits churn for member
   and parent hotkeys, though not for a pruned hotkey still holding vault
   stake (fact 2). Frozen beats mispriced.
2. **All exits freeze during a trip, including the TAO rail.** An exit
   during an undercount would pay the exiter with other holders' backing.
3. **Unobserved growth is unprotected until observed.** Emission and
   donations accrued since the last operation or checkpoint sit above the
   watermarks; a swap in that window still trips on the full watermark, but
   the growth rides into the (recoverable) stray rather than being
   independently gated. Checkpoint cadence sizes this lag; swap detection
   never depends on it.
4. **Gas:** roughly +70-90k per mutating operation (up to six watermark
   reads at entry and six writes at exit on top of the union reads), plus
   ~40k per `checkpointBacking` call at whatever cadence the operator
   chooses. Independent of subnet size.
5. **The watcher is a production dependency for liveness, not for safety**
   (§12): freezes stay short and growth gets protected promptly only if
   someone calls the permissionless functions — but no safety property
   depends on it. The plan ships a reference watcher, not just a contract.

## 11. What this design does not do

- It does not locate strays on-chain. The contract detects that a tracked
  position lost value; finding where the chain put it takes one RPC state
  read (§12). Storing candidate locations on-chain was rejected: the
  chain's coldkey-to-hotkeys index is append-only and
  third-party-inflatable, so any on-chain walk of it is a
  denial-of-service surface.
- It does not track new hotkeys at runtime. The tracked set stays
  last-seen ∪ attested; recovery moves stake onto that set rather than
  growing it, so there is no list for an attacker to squat.
- It does not net surpluses against deficits, automatically or by request.
  Any such netting would let growth on one slot conceal a loss on another —
  the exact failure this design exists to prevent.
- It does not sell anything permissionlessly. Conversions of stake happen
  only through user-initiated exits and owner-acknowledged reconciliation.

## 12. Operational runbook (load-bearing for liveness)

1. **Watcher loop** (stateless, permissionless; a reference implementation
   ships with the plan): per netuid — skip if `isSubnetDissolving`; read
   `backingDeficit(netuid)`. If zero and positions have grown, call
   `checkpointBacking(netuid)` on the configured cadence (default hourly) to
   bring growth under protection. If non-zero, read the chain's
   coldkey-to-hotkeys index (`StakingHotkeys(cloneColdkey)`) via a single
   RPC state query, diff against the tracked set, and call `recoverStray`
   per hidden location with target-slot retry. The index is
   third-party-growable, so the watcher must tolerate bloat (stream or cap
   the diff, alert on unusual growth).
2. **Ownerless hotkey**: if moves from a located stray revert for a missing
   owner record, send `try_associate_hotkey(hotkey)` from the operator's own
   substrate account first (restoring the record from an operator key keeps
   the hotkey out of a stranger's hands), then `recoverStray`.
3. **Sub-floor stray**: top it up past the transfer minimum and
   `recoverStray`, or top up the deficit slot itself — §7. The watcher
   should alert rather than auto-spend above a configured value.
4. **Swap events**: on a `HotkeySwapped` event touching an attested
   validator, call `recoverStray` (or re-attest) promptly; on a prune, no
   action is needed.
5. **Threshold watch**: a raise of the nominator threshold
   (`getNominatorMinRequiredStake`) is an immediate clearing event for
   sub-threshold slots (fact 5) — expect a trip and reconcile per §7.
6. **Loss proposals**: a `BackingLossProposed` event is a public 72-hour
   challenge window — verify the deficit is genuinely unrecoverable and
   attempt cures before it executes.
7. **Runtime upgrades**: verify the transfer minimum and staking-precompile
   behavior against the new runtime before resuming operations; the vault
   mirrors the transfer minimum as a constant because no getter exists.

## 13. Test plan

Mocks must model the chain behavior this design's safety rests on:

- `MockStaking`: hotkey existence (owner-record flag; moves and unstakes
  revert without it), the 100k RAO move floor on moves/transfers with **no
  full-drain exemption**, full-drain exemption on unstakes only,
  whole-position re-keying for swaps, a per-leg transfer-credit shave knob
  (fact 6), a single-RAO read-shave helper, a donation helper, and an
  emission helper growing every position under a hotkey (fact 1).
- Swap helpers, all four modes: owner-record removal only in all-subnets
  mode, stake re-key (whole positions) only when stake follows; an
  association helper restoring the owner-record flag.
- A prune helper that touches no stake, and clearing helpers for both the
  sale and delete branches.

Suites (repo naming conventions):

- Unit: per-slot trip on a re-keyed position and quiet across deposits,
  exits, rebalances, rotations, prunes, and stake-keeping swaps; wrap's
  check runs pre-flush; **the unconditional-detection regression: grow one
  slot by more than another slot's whole balance via emission, call
  nothing, swap the other slot away — the next touch trips** (the property
  an aggregate cannot provide); `checkpointBacking` raises per slot, never
  lowers, no-ops when nothing grew, reverts during the blackout;
  `recoverStray` happy path with watermark shift capped by deficit and by
  moved amount (storage asserts on both caps), guard reverts, dead-target
  retry, ownerless-source revert then success after association, sub-floor
  revert then both cures (top-up-stray-then-recover; top-up-deficit-slot),
  watermark total conserved across any recoverStray outcome;
  propose/accept loss: delay enforcement, still-deficit requirement (a
  recovery during the window voids acceptance), re-anchor + events,
  non-owner reverts; both floors on their correct paths; delivery within
  the per-leg allowance and revert beyond it; view reverts while tripped.
- Fuzz: random interleavings of ops, all four swap modes, prunes, donations,
  clearing, emission growth, and (optional) checkpoint calls — every op
  either executes with every tracked position at or above its watermark or
  reverts `BackingShort`; **detection of a stake-moving swap holds across
  all interleavings with zero checkpoint calls**; a second hidden position
  is never masked by recovering the first; the per-token watermark total
  never decreases through any permissionless call sequence; full-supply
  `unwrapForTao` exits succeed with sub-move-floor residue present.
- Invariant suite (handler holds a ground-truth ledger; hidden states
  persist until explicitly cured; checkpoint cadence configurable,
  including never): whenever the vault is live, no tracked position is
  below its watermark and quoted backing matches the ledger up to
  unobserved growth; watermarks only ever equal freshly read balances or
  conserved shifts along verified moves; every alpha-rail burn delivers
  within the per-leg allowance or reverts.
- **Localnet e2e — mandatory before deployment.** The mocks encode chain
  semantics by hand; only a real runtime validates them: all four
  `swap_hotkey_v2` modes against a wrapped position, including
  `try_associate_hotkey` recovery of an ownerless key and a
  real-emission-then-swap sequence with no checkpoint (must trip); a real
  prune; the real 100k transfer minimum at its boundary including a
  whole-position sub-floor rejection and the top-up-then-recover path; a
  threshold raise with both clearing branches if reachable; co-nominator
  churn measuring read dips; measured per-leg transfer credit — gather hops
  and the final delivery — for §9.

## 14. Out of scope

- Validator-cap changes (registry stays at 3).
- Subtensor-side changes.
- Mailbox flows — caller-directed per hotkey; a swapped mailbox hotkey is
  user-recoverable via the existing `reclaimAlphaFromMailbox`.
