# Uid-anchored validator tracking for AlphaVault

Approved design, 2026-08-03. Written against:

- `~/Projects/alpha-wrapper` @ `781b14b` (main)
- `~/Projects/subtensor` @ `e4ffa2e13` (main, runtime v440) — all subtensor
  refs below
- `~/Projects/tao20-contract` (TAO20Index / BuybackTreasury as deployed
  consumers of the vault's views)

## 1. Architecture

The vault holds users' alpha under per-subnet clone coldkeys, delegated to a
small set of attested validators. Today the contract remembers those
validators as raw hotkey bytes. A hotkey is a value the chain is free to
remap: when a validator swaps hotkeys, the chain moves every delegator's
stake — the vault's included — to the new hotkey, and the stored bytes keep
pointing at an account that is now empty. Pricing collapses, deposits mint
against an undercounted total, and integrators that quote the vault's views
inherit the mispricing.

The fix is to remember the validator's **uid** — its registered slot on the
subnet — alongside the hotkey. The chain maintains `slot → current hotkey`
and rewrites that mapping **in the same extrinsic that moves the stake**
(fact 1), so the slot number follows the validator, and therefore the
vault's stake, through any number of key changes. Each tracked validator
becomes a triple:

```solidity
struct TrackedValidator {
    bytes32 hotkey; // key as last observed
    uint16 uid;     // the validator's slot on the subnet
    bytes32 owner;  // validator coldkey, captured when the slot was bound
}
```

and every balance read resolves the slot live:

```solidity
bytes32 resolved = METAGRAPH.getHotkey(netuid, slot.uid); // guarded, §4
uint256 balance  = getStake(slot.hotkey, coldkey, netuid);
if (resolved != slot.hotkey) {
    balance += getStake(resolved, coldkey, netuid);
}
```

Two legs, because the two swap modes strand stake in opposite places: a
stake-moving swap parks it under the *resolved* key (leg two sees it in the
same block the chain moved it), a stake-keeping swap leaves it under the
*stored* key (leg one). Normally the keys are equal and the second read is
skipped. There is no detection, no freezing, and no recovery choreography
for swaps — the read path cannot fall behind, because the thing the vault
remembers is the thing the chain updates atomically with the money.

Prices are always live reads. Events that genuinely destroy value (fact 7)
show up as an immediate, truthful share-price drop — never as a silently
wrong quote.

## 2. Chain facts this design stands on (verified 2026-08-03, runtime v440)

1. **Swaps rebind the uid atomically with the stake move, and move whole
   positions.** `swap_hotkey_v2(hotkey, newHotkey, Option<netuid>,
   keep_stake)` always rewrites `Keys(netuid, uid) → newHotkey` and
   membership for a registered validator (`swap/swap_hotkey.rs:636-645`);
   when `keep_stake == false` (the legacy `swap_hotkey` hardcodes it,
   `macros/dispatches.rs:843-878`) the migration loop reads each delegator
   position in full and moves all of it (`:774+`) — in the same extrinsic.
   There is no partial re-key.
2. **`keep_stake = true` leaves stake on the old key.** One-subnet scope
   keeps the old hotkey's owner record (`:530`); all-subnets scope deletes
   it (`:393`), freezing the positions under an ownerless key until the
   permissionless `try_associate_hotkey(hotkey)` restores the record
   (insert-only — it cannot hijack an owned hotkey;
   `macros/dispatches.rs:1521-1529`, `staking/helpers.rs:127-140`). Moves
   and unstakes require the owner record (`hotkey_account_exists` =
   `Owner.contains_key`, `staking/helpers.rs:207`;
   `stake_utils.rs:1310-1319`, `:1213-1216`).
3. **Pruning recycles the slot and touches no stake.** When a full subnet
   admits a newcomer, `replace_neuron` rebinds the pruned uid to the
   newcomer's hotkey and strips the old key's membership — inside the
   newcomer's registration, third-party-timed — while the pruned hotkey's
   alpha positions persist untouched (`subnets/uids.rs:62`,
   `subnets/registration.rs:27-29`).
4. **Metagraph precompile** at `0x0000000000000000000000000000000000000802`:
   `getUidCount(uint16) → uint16` and `getHotkey(uint16, uint16) → bytes32`
   (1 db read = 625 gas each), `getColdkey(uint16, uint16) → bytes32`
   (2 db reads; returns the owner of the hotkey bound to the uid)
   (`precompiles/src/metagraph.rs:29-36,163-186`). `getHotkey` and
   `getColdkey` revert (`InvalidRange`) on a uid with no key, and failed
   precompile calls consume all forwarded gas with empty returndata —
   `try/catch` cannot recover the gas, so the design never calls them on a
   uid it has not first bounded by a fresh `getUidCount` read (§4).
5. **Uids are contiguous and capped at 256.** `0..getUidCount-1` are
   populated on a live subnet; `sudo_set_max_allowed_uids` rejects values
   above 256 (`pallets/admin-utils/src/lib.rs:566-568`,
   `runtime/src/lib.rs:788`) — raising the cap requires a runtime upgrade,
   which the runbook treats as a compatibility event (§12).
6. **Two distinct chain floors.** Same-subnet moves and transfers require a
   tao value of at least the transfer minimum — **100,000 RAO (0.0001
   TAO)** on v440, whole-position moves included
   (`staking/stake_utils.rs:1035-1048`, `runtime/src/lib.rs:819`). Unstake
   sizing is governed separately (2e6-anchored staking floor family;
   full-balance unstakes are exempt). No precompile exposes the transfer
   minimum, so the vault mirrors it with an owner-tunable value (§9).
7. **Value-destroying events exist and are rare.** Root raising the
   nominator threshold force-clears sub-threshold nominations — sold at min
   price, or the alpha deleted outright if the sale errors
   (`pallets/admin-utils/src/lib.rs:1149-1162`,
   `staking/helpers.rs:227-270`); a root-level coldkey swap of a clone
   removes the vault's control entirely. Live reads price both truthfully
   and immediately.
8. `getStake(hotkey, coldkey, netuid)` on the staking precompile charges a
   flat 7 db reads = 4,375 gas (`precompiles/src/staking.rs:336-356`), and
   reads of absent positions return zero.

## 3. Contract surface

### ValidatorRegistry

The attestation payload and stored set gain uids:

```solidity
struct WeightAttestation {
    uint256 netuid;
    bytes32[] hotkeys;
    uint16[] uids;      // new: each validator's slot
    uint256[] weights;
    uint256 nonce;
    uint256 deadline;
}

struct ValidatorSet {
    bytes32[3] hotkeys;
    uint16[3] uids;
    bytes32[3] owners;  // captured at commit from the metagraph
    uint16[3] weights;
}
```

At commit, for every attested entry the registry verifies
`getHotkey(netuid, uid) == hotkey` (revert `UidHotkeyMismatch` — a stale or
mistyped uid must not enter storage, because the vault's swap-following
depends on the binding being true at attestation time) and captures
`owners[i] = getColdkey(netuid, uid)`. The EIP-712 typehash changes
accordingly (attester tooling update; §12). `getValidators` returns the full
set; existing consumers of the two-field shape get a compatibility overload
or migrate — decided at implementation kickoff with the registry's
consumers enumerated.

### AlphaVault

```solidity
/// Validators the clone's stake was distributed across at the last
/// state-mutating call; refreshed only after a clean consolidation.
mapping(uint256 => TrackedValidator[3]) private _lastSeenValidators;

/// Tao floor mirroring the chain's same-subnet movement minimum. Distinct
/// from minStakeTaoFloor (which mirrors the unstake-sizing floor).
uint256 public minMoveTaoFloor; // init 100_000; owner-tunable up to MOVE_FLOOR_CAP = 10_000_000

error HotkeyNotStray();
error InvalidTargetSlot();
error MinMoveTaoFloorTooHigh();

event StrayStakeRecovered(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 alpha);
event MinMoveTaoFloorUpdated(uint256 oldValue, uint256 newValue);

function recoverStray(uint256 netuid, bytes32 strayHotkey, uint256 targetSlot) external nonReentrant;
function setMinMoveTaoFloor(uint256 newValue) external onlyOwner;
function lastSeenValidators(uint256 tokenId) external view returns (TrackedValidator[3] memory);
```

`_lastSeenHotkeys` (bare `bytes32[3]`) is replaced by the triple form; the
old external getter is replaced by `lastSeenValidators`. No other storage
changes. Pricing views keep their exact signatures, gas class, and revert
surface (§8).

## 4. Read path

`_unionStake` (pricing and exits) and `_fetchBalances` (operation working
sets) generalize from "read each stored hotkey" to "read each slot's legs":

1. Read `uidCount = getUidCount(netuid)` once per call.
2. Candidate keys = for each slot in `_lastSeenValidators[tokenId]` and each
   slot in the current attested set: the stored `hotkey`, plus
   `getHotkey(netuid, uid)` **only when `uid < uidCount`** (fact 4: an
   unguarded resolution on a stale uid is an all-gas revert; out-of-range
   slots simply contribute their stored-hotkey leg).
3. Deduplicate candidates (up to 12 legs collapse to at most 12 unique
   keys, typically 3) and read `getStake` once per unique key. Every unique
   key's balance counts once toward the total.
4. Zero slots (`hotkey == 0`) are skipped throughout.

Resolution answers "where is this validator now"; the stored leg answers
"where was the stake last put". Between them, every swap mode is covered on
the read path in the block it happens (§7).

## 5. Move targets and consolidation

Reading a stranger's key is harmless (the vault's stake under it is zero);
**moving stake toward one is not**. A slot's resolved hotkey qualifies as a
move/flush destination only when it passes the owner check:

```solidity
resolved is a valid target iff uid < uidCount
    && getColdkey(netuid, uid) == slot.owner
```

— a recycled slot (pruning replaced the validator) fails the check and the
slot's stored hotkey is used instead; a swapped slot passes it (the owner
coldkey is unchanged by a hotkey swap) and consolidation follows the
validator to the new key. `wrap`'s `chosenHotkey` must match a stored or
resolved attested key (`ChosenHotkeyNotInSet` otherwise), and its flush
destination is the slot's valid target. The existing consolidation roll,
weight alignment, gather, and sell logic are unchanged except that every
destination goes through the target rule and every floor pre-check on a
move uses the move floor (§9). At operation end, after a clean
consolidation, `_lastSeenValidators[tokenId]` is refreshed to the current
attested triples with each slot's *resolved* hotkey — the stored leg always
names the key the vault last actually used.

## 6. recoverStray — permissionless, move-only

```solidity
function recoverStray(uint256 netuid, bytes32 strayHotkey, uint256 targetSlot) external nonReentrant
```

Covers the one sequence the read path cannot follow (§7 last row): stake
parked under a key that is neither any slot's stored hotkey nor any live
slot's resolved hotkey.

1. Guards: netuid in range, clone exists, subnet not dissolving, non-zero
   `strayHotkey`, `strayHotkey` not among the current union keys
   (`HotkeyNotStray`), `targetSlot` indexes an attested slot with a valid
   target per §5 (`InvalidTargetSlot`).
2. `amount = getStake(strayHotkey, cloneColdkey, netuid)`; zero → `ZeroAmount`.
3. Move the full amount onto the slot's target through the clone; emit
   `StrayStakeRecovered`.

The caller supplies only a location. The amount is read from the chain, the
destination is registry-attested and owner-checked, and the chain rejects a
move whose source lacks an owner record or whose value is below the
transfer minimum — a wrong call reverts and changes nothing. No accounting
attaches to this function; the moved stake reappears in the union on the
next read.

## 7. Chain events and vault behavior (complete)

| Event | Read path | Action needed |
|---|---|---|
| Swap, stake follows (`keep_stake=false`, either scope) — the common mode | Resolved leg picks up the new key **in the block the chain moved the stake**; pricing never skips a beat | none; next op's consolidation re-points the stored leg |
| Swap, one subnet, stake stays (`keep_stake=true`) | Stored leg keeps counting the old key | none; consolidation moves it to the slot's valid target on the next op |
| Swap, all subnets, stake stays (old key ownerless) | Stored leg keeps counting (the stake is recoverable, so counting it is honest); moves from the key revert until the owner record is restored | anyone: substrate `try_associate_hotkey(old)`, then any op consolidates (operator preferred, §12) |
| Validator pruned (slot recycled to a stranger) | Stored leg keeps counting the pruned key; resolved leg reads the stranger's key (zero); owner check blocks the stranger as a target | none; consolidation moves the stake to healthy slots on the next op |
| Pruned validator later swaps with `keep_stake=false` **before any op ran** | Stake moves to a key no leg covers — the union undercounts until cured | anyone: `recoverStray(newKey, slot)`; §11 sizes this window, §12 watches for it |
| Governance clearing (sale or delete branch) | Balance drops; live reads reprice shares truthfully at once (sale proceeds reach holders through the existing clone-TAO claim index) | none on the vault; §12 alerting |
| Root coldkey swap of the clone | All reads drop to zero; shares reprice to the clone's remaining TAO | none possible by design; §12 alerting |

## 8. Consumer guarantees (TAO20Index, BuybackTreasury)

The vault's views are called in loops inside consumers' transactions
(`TAO20Index._quoteMint` and its NAV functions call `previewUnwrap` once
per basket vault — roughly forty calls per mint; `BuybackTreasury` calls
`unwrap` under an immutable 2.5M gas stipend). This design therefore treats
the view surface as a contract:

- **Signatures and revert surface unchanged.** `previewUnwrap`,
  `sharePrice`, `totalStake`, `getCurrentValidators` keep their exact ABI
  and revert only in their existing cases (dissolution blackout, dissolved,
  no-validators). No new revert types are introduced on any view.
- **Gas class O(tracked slots), independent of subnet size.** A view costs
  one `getUidCount` + up to six guarded `getHotkey` resolutions + one
  `getStake` per unique key: ~40k typical (~37k today). Forty calls inside
  a TAO20 mint ≈ 1.6M gas. `unwrap` stays ~250-350k — 7x headroom under the
  buyback stipend.
- **Views follow swaps in the same block**, so a consumer computing NAV
  from `previewUnwrap` can never be fed a stale-location undercount by a
  validator timing a swap.

## 9. Floors

`minMoveTaoFloor` (init 100,000 RAO, capped at 10,000,000, owner-tunable,
`MinMoveTaoFloorTooHigh` above the cap) gates every pre-check on a move or
transfer: consolidation moves, rebalance moves, gather hops, the deposit
flush, and delivery. `minStakeTaoFloor` (existing, init 2e6) keeps gating
unstake sizing in the sell paths. Each vault-side pre-check mirrors exactly
one chain-side check; the implementation records that mapping with
subtensor citations in the PR description. Residue below the move floor
(< 0.0001 TAO per slot) stays where it is and stays counted — it is
rediscovered by the stored leg every operation.

## 10. Gas (live-priced 2026-08-03: 10 gwei, TAO $188)

| Operation | Today | This design | Delta |
|---|---|---|---|
| View (`previewUnwrap`/`sharePrice`) | ~33k | ~40k | +7k (~$0.013) |
| `wrap` | ~250k | ~265k | +15k (~$0.03) |
| TAO20 mint NAV legs (~40 views) | ~1.3M | ~1.6M | +0.3M (~$0.56) |
| `recoverStray` (rare) | — | ~60k | — |
| Registry commit (per attestation) | ~90k | ~110k | +3 verifications + owner captures |

All costs are independent of subnet occupancy; a uid-cap raise (runtime
upgrade, §12) changes nothing in this table.

## 11. Residual risks (explicit)

1. **The prune-then-swap window.** If an attested validator is pruned
   (slot recycled) and then swaps its old key with `keep_stake=false`
   before any vault operation has consolidated the stranded stake, the
   moved stake is invisible to the union until `recoverStray`. Both steps
   are observable on-chain (registration and swap extrinsics), the first is
   not under the validator's control, any operation between them closes the
   window, and consumer traffic (TAO20 mints trigger user wraps; buybacks
   trigger unwraps) keeps operations frequent. During an open window the
   union undercounts, which favors depositors over holders — bounded by the
   stranded slot's share of the position and by the window's length. The
   runbook watches both trigger events (§12).
2. **Ownerless stake (all-subnets `keep_stake=true` swap).** Counted
   honestly, unmovable until the permissionless substrate association
   restores the owner record. The operator should be the one to associate
   (a stranger who associates first controls the key's future swaps — they
   still cannot take the stake, only relocate it again).
3. **Value-destroying chain events** (clearing branches, root coldkey
   swap) reprice shares downward immediately and truthfully. There is no
   freeze and no discretionary write-down anywhere in the design; holders
   eat real losses at the moment they occur, which is the honest outcome.
4. **Registry compromise is unchanged**: a malicious attester quorum could
   always rotate weights; with uids it could also attest a mismatched pair
   — rejected at commit by the on-chain `getHotkey` verification, which is
   why that check is load-bearing and not cosmetic.

## 12. Operational runbook

1. **Attester payload v2**: attestations carry uids; the EIP-712 typehash
   changes; attester tooling signs the new shape. A stale-uid attestation
   reverts at commit (`UidHotkeyMismatch`) — re-read the metagraph and
   re-sign.
2. **Event watch** (existing attester infrastructure): on a swap extrinsic
   touching an attested validator — no action needed for pricing; poke the
   permissionless `rebalance(netuid)` at convenience so consolidation
   re-points the stored leg. On a *registration* to a full subnet that
   recycles an attested validator's slot: poke `rebalance(netuid)` promptly
   (closes §11.1's window), and re-attest the replacement validator.
3. **Ownerless key**: if consolidation or `recoverStray` reverts because
   the source key lost its owner record, send `try_associate_hotkey(key)`
   from the operator's substrate account, then retry.
4. **Runtime upgrades**: verify the transfer minimum (mirrored as
   `minMoveTaoFloor`), the metagraph and staking precompile behavior, and
   the uid cap against the new runtime before resuming normal operations.
5. **Loss alerting**: clearing events and any clone-coldkey anomaly alert
   immediately — prices are already truthful, but holders should learn of
   real losses from the operator, not from the chart.

## 13. Test plan

### Mocks

- `MockMetagraph` (new, installed at the metagraph precompile address):
  uid-indexed hotkeys and owners, `getUidCount`, `getHotkey`, `getColdkey`
  reverting on unset/out-of-range uids (modeling the all-gas behavior as a
  plain revert), `setNeuron(netuid, uid, hotkey, owner)`.
- `MockStaking`: hotkey existence flag (moves/unstakes revert without it),
  the 100k move floor on moves/transfers (whole-position moves included),
  full-drain exemption on unstakes only, whole-position re-keying.
- Test-base helpers wiring both mocks:
  `swapHotkeyFull(old, new, netuid, keepStake)` (uid rebind + owner-record
  clear always; whole-position re-key iff stake follows),
  `swapHotkeyOneSubnet(old, new, netuid, keepStake)` (uid rebind; owner
  record kept), `pruneNeuron(netuid, uid, newcomerHotkey, newcomerOwner)`
  (uid + owner rebind, stake untouched), `associateHotkey(key)`,
  `donateStake(...)`.

### Unit (repo naming: `test_<Scenario>_<Outcome>`)

- `test_TotalStake_FollowsStakeMovingSwap` — swap between ops; total
  unchanged with **no** intervening call of any kind.
- `test_PreviewUnwrap_FollowsStakeMovingSwap` — the TAO20-facing guarantee.
- `test_TotalStake_CountsStakeKeepingSwapOnStoredLeg`
- `test_TotalStake_CountsPrunedSlotOnStoredLeg`
- `test_Wrap_ConsolidatesToResolvedKeyAfterSwap` — owner check passes,
  stored leg re-points at op end.
- `test_Rebalance_RefusesRecycledSlotAsTarget` — pruned slot fails the
  owner check; stake lands on healthy slots.
- `test_Wrap_AcceptsResolvedHotkeyAsChosen` / `test_Wrap_RevertsOnForeignChosenHotkey`
- `test_UnionStake_SkipsResolutionForOutOfRangeUid` — subnet shrunk below a
  stored uid; no metagraph revert reaches the op.
- `test_RegistryCommit_RevertsOnUidHotkeyMismatch` /
  `test_RegistryCommit_CapturesOwners`
- `test_RecoverStray_MovesOrphanedStake` (prune-then-swap sequence) /
  `test_RecoverStray_RevertsOnUnionMemberHotkey` /
  `test_RecoverStray_RevertsOnRecycledTargetSlot` /
  `test_RecoverStray_RevertsOnZeroPosition`
- `test_Unwrap_SucceedsAfterOwnerRecordRestored` (ownerless key:
  `associateHotkey` then consolidation drains it)
- Floor split: move-path boundaries at 100k (deposit flush, gather,
  consolidation, rebalance, delivery), unstake boundaries kept at 2e6,
  `test_SetMinMoveTaoFloor_RevertsAboveCap`.

### Fuzz / invariant

- `testFuzz_Ops_PriceTrueTotalThroughSwaps(uint8[] memory opSequence, uint8 swapMode, uint8 swapPoint)`
  — random op interleavings with swaps of every mode injected at random
  points: quoted totals always equal the mock ledger's truth for
  union-visible stake; stake-moving swaps never produce a stale-location
  undercount.
- `testFuzz_Consolidation_NeverTargetsForeignOwner(uint8 pruneSlot)` — no
  move destination ever fails the owner check, across prune/swap
  interleavings.
- `invariant_UnionCountsEveryLegExactlyOnce` — dedup correctness: per-key
  balances counted once regardless of how many slots resolve to the key.
- `invariant_NoMoveBelowChainFloors` — every mock-observed move satisfies
  the move floor; every unstake satisfies its sizing rules.

### Localnet e2e — mandatory before deployment

Real-runtime validation on a local subtensor node (per the e2e runbook:
`scripts/localnet.sh` from the subtensor checkout, btcli 9.23.2, 8M deploy
gas), extending the existing pytest suite:

1. **Stake-moving swap (the headline case)**: wrap a position, execute a
   real `swap_hotkey_v2(keep_stake=false)` for an attested validator, and
   assert — in the first block after the swap, with no other calls —
   `totalStake` and `previewUnwrap` unchanged; then a `wrap` and an
   `unwrap` succeed end-to-end and the stored leg re-points (visible via
   `lastSeenValidators`). Repeat for the all-subnets scope.
2. **Stake-keeping swap**: `keep_stake=true` on one subnet; totals
   unchanged via the stored leg; next `rebalance` consolidates to the
   resolved key.
3. **Ownerless key**: all-subnets `keep_stake=true`; totals unchanged;
   consolidation reverts with the chain's missing-owner error;
   `try_associate_hotkey` from a substrate account; consolidation then
   drains the key.
4. **Prune**: register a newcomer onto a full subnet so an attested
   validator's slot recycles; totals unchanged via the stored leg; the
   newcomer never appears as a move target; `rebalance` consolidates away.
5. **Prune-then-swap**: after the prune, swap the pruned key with
   `keep_stake=false`; observe the undercount; `recoverStray` restores it;
   totals recover exactly.
6. **Registry round-trip**: attest a set with uids against the live
   metagraph (commit verification passes; a deliberately stale uid
   reverts).
7. **Floors**: a whole-position move at/below/above the real 100k transfer
   minimum; sub-floor residue stays counted.
8. **Consumer profile**: measure `previewUnwrap` gas on the live node and
   project the forty-call TAO20 mint pattern; assert `unwrap` fits a 2.5M
   stipend with margin.

## 14. Out of scope

- Validator-cap expansion (the registry keeps three slots; the triple form
  and dynamic-friendly internals leave it a registry-only change later).
- Subtensor-side changes.
- Mailbox flows: deposits are user-directed per hotkey and recoverable via
  the existing `reclaimAlphaFromMailbox`; a depositor whose chosen
  validator swaps between staking and wrapping passes the resolved key to
  `wrap` (§5) or reclaims.
- TAO20-side changes: none required; §8 is a guarantee, not a migration.
