# Dynamic validator set (1..64) — design

Raises the per-subnet validator set in `ValidatorRegistry` from a fixed 3 to a
dynamic 1..64, and generalizes `AlphaVault` to stake across the full attested
set. Written 2026-08-12 against `main` @ `c6533a5`, verified against
`~/Projects/subtensor` @ `c02a376ec`.

Supersedes the cap-10 proposal in `validators_cap_research.md`. The on-chain
validator-permit verification described there is **out of scope here** and is
not implemented by this change.

---

## 1. Goal and locked decisions

Attesters must be able to spread a subnet's stake across up to 64 validators,
with the vault holding **real stake on every attested validator** in the
attested BPS proportions. The motivation is a decentralization mandate: visible
distribution of stake, not a bounded active subset.

Locked, with the cost consequences accepted:

1. `MAX_VALIDATORS = 64`, a `constant`. No admin setter.
2. Dynamic arrays for the per-netuid set. No fixed-size arrays, no packing tricks.
3. **Full alignment on every state-mutating call.** The position is exactly
   on-weight when any call returns — today's invariant, preserved at 64. No
   cursor, no amortization, no eventual consistency.
4. **First caller pays in full.** Whoever transacts first after a set change
   absorbs the whole realignment cost.
5. Rotated-out stake is handled by the **same** mechanism as weight drift: a
   dropped validator is one whose target weight is zero.

### 1.1 Three is the default; 64 is the ceiling

Real sets are expected to hold **3 validators**. 64 is the extreme the contract
must survive, not the case it should be tuned for. Two consequences bind the
whole design:

- **No regression at 3.** Every generalization must leave a 3-validator `wrap`
  and `unwrap` at or near today's cost. The gas snapshot keeps the existing
  3-validator entries precisely so a regression there is visible in CI, and the
  64-validator entries are added alongside them rather than replacing them.
- **Optimize the common path, bound the rare one.** The set-version fast path
  (§4.3) exists for this: an ordinary call reads one storage word instead of the
  whole remembered set, which matters at 3 and matters enormously at 64.

The costs in §1.2 are the ceiling, not the expected bill.

### 1.2 Accepted costs

| Path | N=3 today | N=64 |
|---|---:|---:|
| `wrap`, typical | 268,544 | ~1.5M (~$3.90) |
| `wrap`, first call after full set rotation | 400,695 | ~4.2M (~$11) |
| `unwrap`, typical | 154,571 | ~1.3M (~$3.40) |

At 10 Gwei and 1 TAO = $260. These are estimates to be replaced by measured
values in `snapshots/AlphaVault.json` (§6.4).

Worst case fits comfortably in the chain's 75,000,000 block gas limit
(`runtime/src/lib.rs:1047`), so no path can be gas-bricked. The cost is real but
bounded, and it is the direct price of the decentralization mandate: spreading a
one-hotkey deposit across 64 validators is 63 `moveStake` dispatches, and no
design that keeps the position continuously on-weight can avoid them.

---

## 2. Chain facts this design depends on

All verified in subtensor source, not inferred from signatures.

### 2.1 Batched stake reads — the one real gas win

`getStakeInfoForColdkeyAndNetuid(bytes32 coldkey, uint256 netuid, bytes32[] hotkeys)`
on the staking precompile (`0x…0805`), `precompiles/src/staking.rs:358`.

- **`MAX_STAKE_INFO_HOTKEYS = 64`** (`staking.rs:62`) — a hard bound on the
  input array. This is why 64 is the right cap: it is the largest set the chain
  will price in a single call.
- Cost: `7` db reads per hotkey (`STAKE_INFO_READS_PER_HOTKEY`, `staking.rs:59`)
  plus `64` gas per hotkey of input (`STAKE_INFO_INPUT_GAS_PER_HOTKEY`,
  `staking.rs:61`).
- **Reverts on duplicate hotkeys** in the input (`staking.rs:374`).
- **Omits zero-stake hotkeys** from the result (`staking.rs:394`) — the result is
  a subset of the input, in input order.
- Returns `(bytes32,uint256)[]`, i.e. `(hotkey, stake)` pairs.
- Shipped in **V438** (`c1463f2cc`, 2026-07-23); the reference checkout is at
  `v443`, five releases later. Live on mainnet, safe to depend on.
- An input over 64 fails at ABI decode against the `BoundedVec` bound, *before*
  the in-body duplicate check, so it surfaces as a decode failure rather than
  the `"duplicate stake info hotkey"` revert string.

Gas per db read is **625**, traced from source: `record_db_reads` →
`weight_to_gas(RocksDbWeight.reads(1))` = 25,000,000 ref_time ÷ `WeightPerGas`
40,000. The mainnet-measured 4,952 for a `getStake` call is 7 × 625 = 4,375 of
db reads plus ~577 of fixed per-call overhead; dividing 4,952 by 7 to get "707
per read" wrongly folds that fixed cost into the marginal rate.

Marginal cost per hotkey in the batched call is therefore
`7 × 625 + 64 = 4,439`:

| | 64 individual `getStake` | one batched call |
|---|---:|---:|
| per hotkey | 4,952 | 4,439 |
| fixed per-call overhead | (included above) | ~577 |
| **total** | **~316,928** | **~284,673** |

Batching saves ~32k, about 10%. The db reads dominate and are charged per hotkey
either way, so **~285k of reads per hot-path call at N=64 is inherent.**

### 2.2 Why the total cannot be cached or read in O(1)

`getTotalColdkeyStakeOnSubnet(bytes32,uint256)` (`staking.rs:780`) looks like an
O(1) replacement for summing balances. **It is not usable.** Its implementation
(`pallets/subtensor/src/staking/helpers.rs:90-123`) returns a `TaoBalance`: it
runs each position through `SwapInterface::sim_swap` and adds the fee back
(`amount_paid_out + fee × current_alpha_price`), approximating the gross curve
value. The result is TAO-denominated and derived from a full swap simulation
against live pool reserves, so it carries the position's own slippage, not just
spot price.

Using it for share pricing would make share price a function of the AMM curve,
**manipulable within a single block** — a direct oracle-manipulation attack on
mint/burn. Ruled out. Vault accounting stays alpha-denominated.

It is independently unusable for a second reason: the precompile charges a flat
2 db reads (`staking.rs:788`) while the helper iterates every one of the
coldkey's staking hotkeys and runs a `sim_swap` per match. The call is
undercharged and its true cost is unbounded.

`getTotalAlphaStaked(bytes32,uint256)` is alpha-denominated and cheap, but it
aggregates one **hotkey** across all coldkeys, so it is not a per-coldkey total
and cannot substitute either.

Caching the total is equally unsound: nominator alpha accrues emissions through
the share pool on-chain, so a cached total drifts below the true value, and a
depositor pricing against a stale low total mints too many shares and dilutes
existing holders. Reads must be live.

### 2.3 The stake floor still binds

Unchanged from today: a move whose TAO value is below the chain's minimum is
rejected, and a rejected dispatch burns all forwarded gas, so sub-floor moves
must be skipped pre-call rather than attempted. At 64 validators each slot holds
~1/64 of the position, so a vault must hold roughly `64 × floor` before a
uniform spread is movable at all. Below that, alignment moves are skipped and
the position stays legitimately drifted — harmless, because share value depends
on the total, not the split.

---

## 3. ValidatorRegistry changes

### 3.1 Storage and constants

```solidity
uint16 private constant MAX_VALIDATORS = 64;

struct ValidatorSet {
    bytes32[] hotkeys;
    uint16[] weights;
}
mapping(uint256 => ValidatorSet) private _validators;
```

`MAX_SIGNERS`, `threshold`, the signer set, and the whole EIP-712 attestation
flow are unchanged. This change does not touch the quorum model.

### 3.2 Set version — cheap change detection

The vault must answer "did the set change since I last looked?" without reading
64 storage slots. `nonces[netuid]` is already monotonic per netuid and already
bumped on every commit, so it **is** the version. No new registry state.

`getValidators` returns it alongside the set so the vault needs one external
call, not two:

```solidity
function getValidators(uint256 netuid)
    external view returns (bytes32[] memory hotkeys, uint16[] memory weights, uint256 version);
```

A re-attestation of an unchanged set bumps the version and costs the vault one
redundant comparison pass that finds nothing rotated out. Harmless.

### 3.3 Validation and commit

`_validatePayload` keeps every existing check, with the count bound widened to
`1..64`. The duplicate-hotkey check stays the O(n²) nested loop: at 64 that is
2,016 comparisons on `calldata`, a few tens of thousands of gas on a keeper
transaction. Not worth a mapping-based rewrite that would add storage churn.

`_commit` drops today's diff-write and becomes `delete` + push, per locked
decision 2. The trailing-zero sentinel dies with it; a subnet is configured iff
`hotkeys.length > 0`.

Full 64-entry commit cost: 64 hotkey slots plus 4 packed weight slots
(`uint16[]` packs 16 per slot) ≈ 68 cold `SSTORE`s ≈ 1.36M gas. A keeper cost on
a rare operation; acceptable, and not on any user path.

### 3.4 Interface

`IValidatorRegistry.getValidators` changes to the dynamic signature above. The
"first zero weight" count convention is removed from its NatSpec; count is
`hotkeys.length`, and weights still sum to 10,000 across the set.

---

## 4. AlphaVault changes

### 4.1 The unifying idea

Today the vault runs two mechanisms over the validator set:

- `_consolidateRotatedStake`, which rolls the **entire position sequentially
  through every rotated-out hotkey** to defeat the stake floor, and
- `_alignToWeights`, which moves stake from the most-over slot to the most-under
  slot until targets are met.

At 64 the first is 64 chained dispatches for work the second already does. This
design **deletes the roll from the common path** and expresses rotation in the
aligner's own terms:

> A rotated-out validator is a validator whose target weight is zero.

The aligner already drains over-target slots into under-target slots with direct
moves. Giving a dropped hotkey a target of zero makes it the most-over slot, so
it drains first, directly into whichever current validators are most underweight
— no chain of hops, no separate mechanism, one set of invariants to reason about.

**A drain is not an alignment move, and the distinction is load-bearing.**
Alignment moves `min(surplus, deficit)`, so folding rotation into it caps a
drain at the *receiving* slot's deficit rather than the dropped slot's balance.
On a routine 64 → 63 shrink with a 6 TAO position, the dropped validator holds
~0.094 TAO — 47× the floor — but the departing weight spreads over 63 slots, so
each deficit is ~0.0015 TAO, below the floor. The move is skipped, the loop
breaks, and well-above-floor stake stays on an unattested validator. The old
roll never hit this because whole-pile moves are never deficit-capped.

So rotation gets its own move class, run before alignment:

> `_drainRotatedSlots` empties each dropped validator in **one full-balance
> move** into the least-funded current validator, floor-checked against the
> whole balance, never against a deficit.

Alignment then corrects the resulting overshoot. Two passes, but only one of
them is unbounded in N, and the split is what makes the drain correct at all.

A balance too small to move even in full is **left in place, not reverted**.
Reverting would block `unwrap` for the whole position over dust; leaving it is
safe because §4.3's bookkeeping keeps it tracked and §4.2's view rule keeps it
inside the reported backing.

### 4.2 The invariant this preserves

> When any state-mutating call returns, the position holds stake only on
> currently attested validators, distributed to the attested BPS weights up to
> stake-floor granularity.

This is exactly today's invariant, and it holds only *at the boundary of a vault
call*. It emphatically does **not** hold at all times, because the registry is
updated outside the vault: between a set commit and the next vault call, the
whole position sits on hotkeys that are now rotated out.

That distinction decides which paths may read only the current set:

- **State-mutating paths** (`wrap`, `unwrap`, `rebalance`) drain rotated-out
  hotkeys before they compute a total, so after the drain the current set holds
  everything and a single 64-hotkey read is exact.
- **View paths** (`totalStake`, `sharePrice`, `previewWrap`, `previewUnwrap`)
  have no such guarantee and **must keep reading the union** of current and
  last-seen hotkeys. A current-set-only view would report a backing of zero for
  a fully rotated set, driving `sharePrice` to zero and corrupting every quote.

So `_unionStake` survives, for views, and costs up to two batched calls (~642k)
in the worst case. That is acceptable for an `eth_call` and is never charged to
a transaction.

### 4.3 State

```solidity
mapping(uint256 => bytes32[]) private _lastSeenHotkeys;
mapping(uint256 => uint256)   private _lastSeenVersion;
```

`_lastSeenHotkeys` is still needed: when the set changes, it is the only record
of where the vault put stake, and therefore of what must be drained. It is
refreshed only after a clean drain, exactly as today, so a reverted call can
never lose track of stake.

`_lastSeenVersion` is the fast path. When the registry version matches, no
rotation is possible, so the vault skips reading `_lastSeenHotkeys` entirely —
saving 64 cold `SLOAD`s (~134k) on every ordinary call.

### 4.4 Balance reads

`_fetchBalances` becomes one batched call. Three properties of the precompile
drive the implementation and each needs an explicit test:

1. **Duplicates revert.** The current set is duplicate-free by registry
   construction, but `current ∪ lastSeen` is not. The union must be deduplicated
   before the call.
2. **Zero-stake hotkeys are omitted.** The result is a subset in input order, so
   results are mapped back to input indices by a single forward scan, not by
   position.
3. **Input is capped at 64.** A union of 64 current plus up to 64 rotated-out
   exceeds the cap, so the union path issues two batched calls.

### 4.5 Generalized paths

Mechanical, all driven by `count = hotkeys.length`:

| Site | Change |
|---|---|
| `wrap` in-set check | loop to `count`; unchanged semantics |
| `_alignToWeights` | `lastIndex = count - 1`; single-validator shortcut becomes `count == 1`; `targets = new uint256[](count)` |
| `_rebalanceStep` | `i < count` |
| `_deliverAndAlign` gather | scans `count` slots for the largest; hop loop bounded by `count` |
| `_fetchBalances` / `_sumBalances` | dynamic arrays, one batched read |
| `_isRotatedOut` | membership scan over the dynamic current set |
| `_totalStake` | current set only (§4.2), no union |
| `_unionStake`, `[6]` merges | deleted where the invariant makes them redundant; retained only on the `unwrapForTao` sell path, sized `count` |
| `getCurrentValidators`, `lastSeenHotkeys` views | return `bytes32[]` — ABI change |

Both contracts deploy fresh together and the registry reference is immutable, so
the `_lastSeenHotkeys` type change carries **no storage-migration risk**.

---

## 5. Security analysis

### 5.1 Griefing via set churn — accepted, bounded

A compromised or careless attester quorum can rotate the full 64-validator set
every block, forcing the next caller to pay ~4.2M gas each time. This is a
**cost** attack, not a liveness attack: the work fits in a 75M block, so calls
still succeed. It is bounded by the quorum's own honesty assumption — the same
quorum can already point stake at arbitrary hotkeys, which is strictly worse.
No new trust is introduced. Accepted under locked decision 4.

### 5.2 No new oracle surface

Share pricing stays alpha-denominated and reads live per-hotkey balances. The
TAO-denominated total getter is deliberately not used (§2.2), so no AMM spot
price enters mint/burn accounting. This is the single most important security
property of the design and is worth an explicit test that share price is
invariant to pool-price movement.

### 5.3 Dust and floor interactions widen at 64

With 64 slots, per-slot balances are 64× smaller, so far more moves fall below
the floor. Consequences, all pre-existing but amplified:

- Alignment moves get skipped; the position stays drifted. Safe — value tracks
  the total.
- A rotated-out slot holding sub-floor dust cannot be drained directly. The
  sub-floor fallback (§4.1) covers it; if even the combined amount is sub-floor,
  the call must **not** revert the user's operation over dust it cannot move.
  Today's `ConsolidationBelowFloor` revert becomes much easier to trigger at 64
  and must be re-examined so a stuck dust position cannot block all withdrawals.
  This is the sharpest correctness risk in the refactor.

### 5.4 Unbounded loop review

Every loop is bounded by `MAX_VALIDATORS = 64` or by the union bound 128, both
constants. No loop is bounded by user-supplied length. Worst-case gas is
computed in §1.2 and stays under 6% of a block.

---

## 6. Test plan

Per repo standards: `test_`/`testFuzz_`/`test_RevertWhen_`, `bound()` over
`vm.assume`, realistic end-to-end flows over isolated calls.

### 6.1 Registry

- Happy path at both bounds: 1 validator and 64 validators; assert exact array
  lengths, event contents, version advance.
- **`test_UpdateValidators_ShrinkSet`** — commit 64, then 3; assert no stale
  tail. The marquee dynamic-array bug class. Plus grow 3 → 64.
- `test_RevertWhen_ZeroValidators`, `test_RevertWhen_SixtyFiveValidators`.
- `test_RevertWhen_DuplicateHotkey` at the 64 bound.
- Existing suites re-based: stale nonce, expired deadline, unsorted signatures,
  unknown signer, below threshold, batch.

### 6.2 Fuzz

- `testFuzz_UpdateValidators(uint256 seed, uint8 count)` — `count = bound(count, 1, 64)`,
  distinct hotkeys, weights normalized to 10,000; assert round-trip.
- `testFuzz_SequentialCommits(uint8 lenA, uint8 lenB)` — shrink/grow soundness.
- `testFuzz_WrapUnwrapRoundTrip(uint8 count, uint256 assets)` — a user must never
  extract more than deposited across any set size.
- `testFuzz_RotationPreservesTotal(uint8 fromCount, uint8 toCount)` — total alpha
  is conserved across an arbitrary set rotation, modulo chain rounding.

### 6.3 Invariants

- `invariant_NoStakeOnRotatedOutHotkeys` — the §4.2 invariant, directly.
- `invariant_TotalStakeMatchesSumOfSlots`.
- `invariant_SharePriceMonotonic` — share price never falls from a rotation or
  rebalance alone.
- Handler rotates sets of varying sizes (1..64) mid-sequence.

### 6.4 Gas measurement (explicit deliverable)

`snapshots/AlphaVault.json` gains measured 64-validator entries alongside the
existing ones:

- `wrap: 64 validators`
- `unwrap: 64 validators`

Per the known snapshot/coverage interaction, snapshots are regenerated with the
CLI `--threads 4` on forge v1.7.0 and never from a `forge coverage` run, which
poisons them.

### 6.5 Mocks

`MockStaking` gains `getStakeInfoForColdkeyAndNetuid` mirroring **real**
semantics: revert on duplicate input hotkeys, omit zero-stake entries, preserve
input order, cap input at 64. A mock that returns zero entries or reorders would
hide the exact bugs §4.4 exists to prevent.

---

## 7. Out of scope

- On-chain validator-permit verification via the metagraph precompile
  (`validators_cap_research.md` §4). Independent of this change.
- Any change to the signer/quorum model, including `MAX_SIGNERS`.
- The hotkey-swap self-heal work tracked separately.
