# AlphaVault validator accounting

Design, 2026-08-03. Written against:

- `~/Projects/alpha-wrapper` @ `781b14b` (main)
- `~/Projects/subtensor` @ `e4ffa2e13` (main, runtime v440) — every
  subtensor reference below
- `~/Projects/tao20-contract` (TAO20Index, BuybackTreasury — consumers of
  the vault's views)

Nothing is deployed yet: storage layouts and interfaces are free to change,
and no migration is involved.

---

## 1. Trade-offs in plain English

What this design gives up, stated without jargon. Every item is deliberate.

**1. A validator we picked can stop our deposits for about 0.1 TAO.**
A validator can perform two hotkey changes in a row that leave our stake
under a name nothing on the chain points to. The stake is never at risk —
it stays in our account and cannot be taken, only hidden — but the vault
notices its books no longer add up and refuses new deposits for that subnet
until someone brings it back. Anyone can do that with a single public call,
including us and including the attacker. So what they buy for ~0.1 TAO is
an interruption in taking new money, not any of the money already there.

**2. That deposit block is the thing standing between an attacker and real
money.**
If deposits were allowed while stake is hidden, an attacker would deposit
at the artificially low price, let the stake reappear, and walk off with
part of everyone else's value. With three validators, one of them hiding
their share and depositing a tenth of the vault takes about 4% of the whole
vault, at roughly a 43% return on what they put in, for a ~$19 fee.
Depositing more takes more. Watching for it does not help — the attacker
can hide and deposit in the same block or the next, and the recovery step
they need is one anyone will happily perform. This is the single place
where monitoring genuinely cannot substitute for a contract rule.

**3. Deposits are the only thing the contract ever blocks.**
Withdrawals, transfers, rebalancing and every price read keep working in
all circumstances, including while deposits are blocked. Money can always
leave. TAO20 is never halted by anything here.

**4. A genuine loss keeps deposits blocked until the owner acknowledges
it.**
If the chain really destroys stake (item 6), the books legitimately will
not add up again, so the block would last forever. The owner records the
loss on-chain to clear it. That call re-enables deposits and does nothing
else — it cannot move stake, change a price, or touch a share — and it is
publicly visible. Until they make it, the vault takes no new money.

**5. One chain event can stop a subnet's operations until someone sends a
substrate transaction.**
A particular hotkey change (an all-subnets swap that leaves stake behind)
deletes the chain's record of who owns that name. The chain then refuses to
let anyone move that stake — us or anybody else. Deposits and withdrawals
for that subnet stop until someone sends one nearly-free substrate
transaction restoring the record. Our contract cannot send it; only a
substrate account can, so an operator must be watching. Money is stuck, not
lost.

**6. Real losses show up immediately as a lower share price, with no
cushion.**
If a governance action clears small positions or a root-level takeover
seizes our account, the share price drops the moment it happens, because
prices are always read live from the chain. There is no pause, no reserve,
and no admin switch to soften it. Holders see the truth before anyone can
explain it. We consider that better than pretending.

**7. Attesters do more work.**
Attestations now carry each validator's slot number, so attester software
must be updated, and must re-attest after routine chain events (a validator
changes keys, gets pruned, the subnet renumbers slots, a validator changes
its coldkey). If they are slow, every balance still counts correctly — the
vault just temporarily loses the ability to follow that validator's next
key change automatically.

**8. Everything costs slightly more gas.**
A price read goes from about 33k to about 42k gas, roughly a cent. A
deposit goes up about 13%. TAO20's mint, which reads prices about forty
times, pays about $0.40 more.

---

## 2. Problem

The vault holds users' alpha under per-subnet clone coldkeys, delegated to
at most three attested validators, and remembers those validators by
hotkey. A hotkey is not a stable identifier: when a validator swaps hotkeys
the chain migrates every delegator position — the vault's included — to the
new key, leaving the vault's stored bytes pointing at an empty account.
Backing appears to vanish, share prices collapse, deposits mint against an
undercounted total, and integrators quoting the vault's views inherit the
error.

Two properties of the chain shape the solution:

- The chain **does** publish a stable handle for the same validator: its
  **uid**, the numbered slot it occupies on the subnet, rewritten to the new
  hotkey in the same extrinsic that migrates the stake.
- That handle has **one gap**: a validator can detach a key from its uid and
  then swap the detached key, landing the position where no uid points.

So the design follows the chain where the chain makes that possible, and
refuses to mint where it does not.

## 3. Design

**Anchor validators by uid, read both legs.** Each tracked validator is
stored as `(hotkey, uid)`. Every balance read sums the position under the
stored hotkey and under the hotkey the uid currently resolves to. A swap in
either mode is then invisible to users: the stake is found in the block it
moved, with no freeze, no operator action, and no change to how prices are
computed.

**Gate minting on the vault's own books.** One figure per token —
`expectedBacking` — records the backing the vault's own flows account for.
It rises by deposits, falls by exactly the alpha paid out, and ratchets up
to whatever the chain reports when that is higher. `wrap` refuses to mint
while observed backing is below it. Nothing else consults it.

**Recover permissionlessly.** `recoverStray` moves a position found outside
both legs back onto an attested validator, verifying the amount on-chain
and the destination against the registry. It restores both the count and
the ability to deposit, and anyone can call it.

**Acknowledge real losses.** When stake is genuinely destroyed, the owner
records the loss, which re-enables deposits and changes nothing else.

Prices are live chain reads throughout. The only state this design adds is
one uid per tracked slot and one figure per token.

## 4. Chain facts this stands on (verified 2026-08-03, runtime v440)

1. **A registered validator's swap rebinds the uid atomically with a
   whole-position stake migration.** `swap_hotkey_v2(hotkey, newHotkey,
   Option<netuid>, keep_stake)` rewrites `Keys(netuid, uid) -> newHotkey`
   and membership for a registered validator
   (`swap/swap_hotkey.rs:626-646`, per subnet in the all-subnets loop);
   when `keep_stake == false` — which the legacy `swap_hotkey` hardcodes
   (`macros/dispatches.rs:843-850`) — the migration reads each delegator
   position in full and moves all of it in the same extrinsic (`:774+`).
   There is no partial re-key.
2. **`keep_stake = true` leaves the stake on the old hotkey**, where the
   stored leg keeps reading it. One-subnet scope keeps the old key's owner
   record (`swap_hotkey.rs:530`); all-subnets scope deletes it (`:393`).
3. **Owner records gate stake operations.** Moves and unstakes require an
   owner record on the keys involved (`hotkey_account_exists` =
   `Owner.contains_key`, `staking/helpers.rs:207`;
   `stake_utils.rs:1309-1319`, `:1213-1216`). Stake under an ownerless key
   is frozen for everyone until the permissionless, insert-only
   `try_associate_hotkey(hotkey)` restores a record
   (`macros/dispatches.rs:1523-1529`, `staking/account.rs:4-12`; it cannot
   hijack an owned key). While a tracked key is ownerless, vault paths that
   would move or sell that position revert at full gas.
4. **A detached key can be swapped with no uid following it.** The uid
   rebind is conditional on membership (`swap_hotkey.rs:626`); the stake
   migration is not, and the caller need only own the old key (`:86`), not
   have it registered. So `A->B keep_stake=true` followed by `A->C
   keep_stake=false` moves the position to `C` while the uid still points
   at `B`: the stake lands outside both legs. §8 quantifies this and §7 is
   the response.
5. **Pruning recycles a slot and touches no stake.** A newcomer's
   registration on a full subnet rebinds the pruned uid to the newcomer
   (`subnets/registration.rs:27-29`, `subnets/uids.rs:62-116`); the pruned
   key's positions persist untouched and stay readable through the stored
   leg.
6. **Uids can be renumbered.** `trim_to_max_allowed_uids` compacts
   survivors onto new uids (`subnets/uids.rs:151`, `Keys::swap` at `:322`)
   and lowers the count (`:379`), callable via
   `sudo_trim_to_max_allowed_uids` (`pallets/admin-utils/src/lib.rs:1927`).
   A stored uid is a refreshable pointer, not a permanent identity; the
   registry rebinds it at every attestation and balances stay visible
   through the stored leg meanwhile.
7. **A validator's coldkey can change**, rewriting `Owner` for all its
   hotkeys (`swap/swap_coldkey.rs:168-186`), so any captured owner value
   goes stale; re-attestation is the remedy.
8. **Metagraph precompile** at `0x0000000000000000000000000000000000000802`:
   `getUidCount(uint16)` (1 db read), `getHotkey(uint16,uint16)` (1 db
   read), `getColdkey(uint16,uint16)` (2 db reads — the owner of the key
   currently at that uid) (`precompiles/src/metagraph.rs:29-36,163-186`).
   `getHotkey`/`getColdkey` revert `InvalidRange` on an unbound uid, and a
   failed precompile call consumes all forwarded gas with empty returndata,
   so **no path may resolve a uid without first bounding it against a fresh
   `getUidCount`**. With that guard, in-range uids are always bound: live
   subnets keep uids contiguous, trims compact and lower the count in one
   extrinsic, and dissolution zeroes the count before clearing keys. The
   uid cap is 256 (`runtime/src/lib.rs:788`; the admin setter rejects
   larger, `pallets/admin-utils/src/lib.rs:566-568`).
9. **Two distinct chain floors.** Same-subnet moves and transfers require a
   tao value of at least the transfer minimum — 100,000 RAO (0.0001 TAO) —
   whole-position moves included (`staking/stake_utils.rs:1035-1048`,
   `runtime/src/lib.rs:819`). Unstake sizing is governed separately
   (2e6-anchored family; full-balance unstakes exempt). No precompile
   exposes the transfer minimum, so the vault mirrors it (§9).
10. **Stake reads and transfers.** `getStake(hotkey, coldkey, netuid)`
    charges a flat 7 db reads = 4,375 gas
    (`precompiles/src/staking.rs:336-356`); absent positions read zero.
    `transferStake` moves a position between coldkeys under a single hotkey
    (`precompiles/src/staking.rs:263-272`, `CloneBase.flush`): a flush
    cannot change the hotkey — only `moveStake` can.
11. **Forced clearing and takeover destroy value.** Root raising the
    nominator threshold force-clears sub-threshold nominations — sold at
    min price, or the alpha deleted outright if the sale errors
    (`pallets/admin-utils/src/lib.rs:1149-1162`,
    `staking/helpers.rs:227-270`). A root-level coldkey swap of a clone
    removes the vault's control entirely.

## 5. Contract surface

### ValidatorRegistry

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
transaction's gas, fact 8), then require `getHotkey(netuid, uid) == hotkey`
(`UidHotkeyMismatch` — swap-following depends on the binding being true
when it enters storage), then capture `owners[i] = getColdkey(netuid, uid)`.
The EIP-712 typehash changes with the payload (attester tooling update,
§10).

`getValidators` returns the wider tuple; Solidity cannot overload on return
type, so the old signature is replaced. Call sites to update:
`AlphaVault._resolveValidators`, `AlphaVault._unionStake`,
`src/interfaces/IValidatorRegistry.sol`,
`test/mocks/MockValidatorRegistry.sol`, the registry and vault test suites,
and `scripts/get_vault_state.py`. TAO20 and BuybackTreasury do not call the
registry (the buyback uses the vault's `getCurrentValidators(uint256) ->
bytes32[3]`, unchanged).

### AlphaVault

```solidity
struct TrackedSlot {
    bytes32 hotkey; // key the vault last confirmed holds this slot's stake
    uint16  uid;    // anchor for live resolution
}

/// Where the clone's stake was left at the last state-mutating call.
mapping(uint256 => TrackedSlot[3]) private _trackedSlots;

/// Backing the vault's own flows account for. Gates minting only; never an
/// input to any price.
mapping(uint256 => uint256) public expectedBacking;

/// Tao floor mirroring the chain's same-subnet movement minimum. Distinct
/// from minStakeTaoFloor (which mirrors the unstake-sizing floor).
uint256 public minMoveTaoFloor; // init 100_000; owner-tunable up to MOVE_FLOOR_CAP = 10_000_000

error BackingUnaccounted(uint256 expected, uint256 observed);
error NoBackingShortfall();
error HotkeyNotStray();
error NoLiveTarget();
error MinMoveTaoFloorTooHigh();

event StrayStakeRecovered(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 alpha);
event BackingLossRecorded(uint256 indexed tokenId, uint256 previousExpected, uint256 newExpected);
event MinMoveTaoFloorUpdated(uint256 oldValue, uint256 newValue);

function recoverStray(uint256 netuid, bytes32 strayHotkey, uint256 targetSlot) external nonReentrant;
function recordBackingLoss(uint256 tokenId) external onlyOwner;
function setMinMoveTaoFloor(uint256 newValue) external onlyOwner;
function trackedSlots(uint256 tokenId) external view returns (TrackedSlot[3] memory);
```

`_lastSeenHotkeys` and its getter are replaced by `_trackedSlots` /
`trackedSlots`. Every view keeps its signature, semantics and revert
surface. Internal union arrays widen from 6 to 12 candidate legs, and
`unwrapForTao`'s sell loop iterates the widened set.

## 6. Read path

Pricing views and operation working sets share one construction:

1. Read `uidCount = getUidCount(netuid)` once per call.
2. **Slot legs** — for each tracked slot: the stored `hotkey`, plus
   `getHotkey(netuid, uid)` when `uid < uidCount` (an out-of-range anchor
   contributes its stored leg only).
3. **Attested legs** — for each registry slot: its hotkey, plus its
   uid-resolution under the same guard, so a freshly attested validator is
   visible before the next consolidation re-points the tracked slots.
4. **Deduplicate** and read `getStake` once per unique key; each unique key
   counts exactly once. For the per-slot balances a working set needs,
   assign each key to the first tracked slot naming it (stored leg before
   resolved leg); keys named only by attested legs count toward the total
   and belong to no slot.

Zero hotkeys are skipped. The total is a sum over unique keys, so it does
not depend on which slot claims a key.

## 7. The deposit guard

Minting is the only path where an undercount moves value between users
(§8), so it is the only path gated.

**The figure.** `expectedBacking[tokenId]` moves in exactly these ways, all
from amounts the vault already knows:

| When | Change |
|---|---|
| End of any mutating operation | `expected = max(expected, observed)` — chain-side growth (emission, donations, recovered stake) folds in as soon as it is seen |
| Deposit (`wrap`) | `expected += flushedAlpha` |
| Alpha delivered (`unwrap`) | `expected -= alphaOut` |
| Alpha sold (`unwrapForTao`) | `expected -= alphaSold` |
| Owner records a loss | `expected = observed` |

No caller-supplied number reaches it. Because it falls only by amounts the
vault itself paid out, no operation can walk it down: calling `rebalance`
after hiding stake leaves it untouched, so the guard cannot be cleared by
poking the contract.

**The check.** `wrap` computes observed backing (§6) after its existing
guards and **before the mailbox flush**, and reverts
`BackingUnaccounted(expected, observed)` when `observed < expected`. That
is the entire enforcement surface: `unwrap`, `unwrapForTao`, `rebalance`,
`recoverStray`, share transfers and every view are unaffected and never
revert on this condition.

**Clearing the block.** The attacker needs the stake counted again to
profit, and so does everyone else: one `recoverStray` call restores
observed backing and deposits resume automatically. Nothing privileged is
involved.

**Genuine losses.** When stake is truly destroyed (fact 11) the shortfall
is permanent and deposits would stay blocked forever.
`recordBackingLoss(tokenId)` — owner-only, requires a live shortfall
(`NoBackingShortfall`) — sets the figure to observed backing and emits
`BackingLossRecorded` with both values. It re-enables deposits and does
nothing else: it touches no price, no share and no stake, so the worst an
owner can do with it is publicly admit a loss that has already repriced
holders' shares. There is deliberately no timelock — the call cannot move
value, and delaying it only keeps users from depositing after a loss they
have already taken.

**Residual.** A hide smaller than the growth absorbed since the last
operation stays under the figure. That bound is emission over the gap
between operations — a fraction of a percent per hour on a live subnet —
and it is worth less than the swap fees an attempt costs.

## 8. The detached-key sequence, quantified

Fact 4 lets a validator park the vault's position under a key no uid
resolves to: `A->B keep_stake=true`, then `A->C keep_stake=false`. The
vault stops counting that position until someone calls
`recoverStray(netuid, C, slot)`.

**Cost to the attacker.** Two swap fees. The per-subnet second step is
cooldown-gated for a day (`swap_hotkey.rs:491`, keyed by coldkey and
checked unconditionally), so a same-block sequence uses the all-subnets
scope for the second step (~0.1 TAO); the cooldown there binds only subnets
where the old key is still a member (`:253-260`), which after step one it
is not.

**What an ungated mint would be worth.** With backing `T`, supply `S`,
hidden amount `H`, and deposit `D` made while hidden, the attacker receives
`D·S/(T-H)` shares instead of the fair `D·S/T`. After recovery, backing is
`T+D` over the inflated supply, so:

```
attacker profit = holders' loss = D·H / (T - H + D)
```

With `H = w·T` (the attacker's attested weight) and `d = D/T`, the loss as
a fraction of the vault is `w·d / (1 - w + d)`. At three equal-weighted
validators (`w = 1/3`):

| Deposit | Holders lose | Return on the attacker's deposit |
|---|---|---|
| 10% of vault | 4.3% of vault | 43% |
| 50% | 14.3% | 29% |
| 100% | 20% | 20% |
| unbounded | 33% (the whole hidden amount) | -> 0 |

Two properties decide the design. Small deposits earn the **highest**
return, so this is not a whale-only attack. And monitoring cannot prevent
it: hide and deposit fit in adjacent blocks, and the recovery the attacker
depends on is something anyone will perform — a watcher racing to recover
*completes* the attack rather than stopping it.

**With the guard (§7) the profitable branch is unreachable.** Deposits are
refused while the books are short, so hiding stake buys an interruption in
deposit flow and a ~0.1 TAO bill, with no path to holders' value. What
remains is griefing, bounded by how quickly any party calls `recoverStray`.

**Related, smaller exposures**, all reversible: stake under an ownerless
key halts that subnet's operations until a substrate association (fact 3);
the owner check binds custody rather than validator identity, so another
hotkey of the same operator landing on the anchored uid would pass it; and
anchors go stale between attestations after a trim or coldkey swap, costing
swap-following on that slot until re-attestation while every balance stays
counted through the stored leg.

## 9. Targets, consolidation, floors

**Valid target.** Stake may only be moved or routed to an attested slot
whose anchor passes: `uid < uidCount`, `getHotkey(netuid, uid) ==
candidate`, and `getColdkey(netuid, uid) == owners[slot]` from the
registry. The owner check establishes custody continuity — the slot is
still operated by the attested coldkey — so a recycled or renumbered slot
is never a destination. Reading a stranger's key stays harmless (the
vault's balance under it is zero); moving stake toward one is what the
check prevents. If no attested slot has a valid target, moves are skipped
and `wrap` reverts `NoLiveTarget`; exits needing no target still work.

**Deposits.** `wrap`'s `chosenHotkey` must be an attested stored key or a
valid-target resolved key. The mailbox flush lands the deposit under
`chosenHotkey` itself (a flush cannot change the hotkey — fact 10); the
same call's consolidation then moves it onto the slot's valid target when
the value clears the move floor.

**Consolidation and refresh.** The existing rotated-stake consolidation
keeps its shape, with every destination passing the valid-target rule. At
the end of a mutating operation each tracked slot is refreshed to **the key
the vault confirmed holds that slot's stake** — the valid target it moved
the stake to, or the key the stake verifiably remained on — with the uid of
the attested slot it consolidated onto. A slot is never re-pointed away
from a key that still holds its stake: if consolidation could not complete
for a slot, that slot's entry is left untouched.

**recoverStray.**

```solidity
function recoverStray(uint256 netuid, bytes32 strayHotkey, uint256 targetSlot) external nonReentrant
```

Permissionless and move-only. Guards: netuid in range, clone exists, subnet
not dissolving, non-zero `strayHotkey`, the key is not already among the
candidate legs (`HotkeyNotStray`), and `targetSlot` indexes an attested
slot with a valid target (`NoLiveTarget`). Then read `amount =
getStake(strayHotkey, cloneColdkey, netuid)` (`ZeroAmount` if none), move
the full amount onto that target through the clone, and emit
`StrayStakeRecovered`. The caller supplies a location and nothing else: the
amount comes from the chain, the destination is attested and owner-checked,
and the chain rejects a move whose source lacks an owner record or whose
value is below the transfer minimum. A wrong call reverts and changes
nothing.

**Floors.** `minMoveTaoFloor` (init 100,000 RAO; owner-tunable, capped at
10,000,000, `MinMoveTaoFloorTooHigh`) gates every pre-check on a move or
transfer: consolidation, rebalance steps, gather hops, the deposit flush,
delivery, and `recoverStray`. `minStakeTaoFloor` (existing, init 2e6) keeps
gating unstake sizing in the sell paths. Each vault-side pre-check mirrors
exactly one chain-side check; the implementation records that mapping with
subtensor citations in the PR description. Residue below the move floor
stays where it sits and stays counted through the stored leg.

## 10. Behavior under chain events

| Event | What the vault does | Follow-up |
|---|---|---|
| Swap, stake follows (`keep_stake=false`, either scope) | The resolved leg picks up the new key in the block the stake moved; totals unchanged; deposits unaffected | none; the next operation re-points the stored leg |
| Swap, stake stays (`keep_stake=true`, one subnet) | The stored leg keeps counting the old key | none; consolidation moves it to a valid target |
| Swap, stake stays, all subnets (old key ownerless) | The stored leg keeps counting; operations touching that position revert at full gas until an owner record exists (fact 3) | anyone sends substrate `try_associate_hotkey(old)`; operator preferred (§11) |
| Detached-key double swap (fact 4) | The position leaves both legs; deposits are refused for that subnet | anyone calls `recoverStray`; deposits resume automatically |
| Validator pruned (slot recycled) | The stored leg keeps counting the pruned key; the newcomer fails the target check | none; consolidation moves the stake; re-attest at convenience |
| Uid trim (anchors renumbered) | Stored legs keep counting; resolutions may point elsewhere until re-attestation, never used as targets | re-attest promptly |
| Validator coldkey swap | No balance change; the captured owner is stale, so that slot has no valid target | re-attest |
| Forced clearing, or root coldkey swap of the clone | Balances drop; prices reprice truthfully and immediately; deposits are refused | owner calls `recordBackingLoss` once the loss is confirmed unrecoverable |

## 11. Operational runbook

1. **Attester payload**: attestations carry uids; the typehash changes;
   stale or out-of-range uids revert at commit — re-read the metagraph and
   re-sign. Re-attest promptly after any swap, prune, uid trim, or
   validator coldkey swap touching an attested validator.
2. **Swap monitoring** (liveness, not safety — the guard is safety): watch
   swap extrinsics for attested validators. On a stake-moving swap nothing
   is required; poke the permissionless `rebalance(netuid)` at convenience
   so consolidation re-points the stored leg. On a `keep_stake=true` swap,
   treat it as a warning: re-attest away from that validator and watch for
   a second swap on the detached key. If the detached-key sequence
   completes, deposits stop — read the clone coldkey's staking index from a
   single RPC state query to locate the position, and call `recoverStray`.
3. **Ownerless key**: if a move or sale reverts because a key lost its
   owner record, send `try_associate_hotkey(key)` from the operator's own
   substrate account (keeping the key out of a stranger's hands — a
   stranger who associates first can relocate the position again, though
   never take it), then retry.
4. **Loss acknowledgement**: forced clearing and clone-coldkey anomalies
   reprice shares immediately; holders should hear it from the operator
   rather than from the chart. Deposits stay blocked until
   `recordBackingLoss` — verify the loss is genuinely unrecoverable (a
   `recoverStray` would restore deposits by itself) before acknowledging.
5. **Runtime upgrades**: re-verify the transfer minimum (mirrored as
   `minMoveTaoFloor`), the metagraph and staking precompile ABIs, and the
   uid cap before resuming normal operations.

## 12. Gas and size (live-priced 2026-08-03: 10 gwei, TAO $188.48)

| Operation | Today | This design |
|---|---|---|
| View (`previewUnwrap` / `sharePrice`) | ~33k | ~42k typical, ~75k worst (~$0.008-0.014) |
| `wrap` | ~250k | ~283k (~$0.053) |
| `unwrap` | ~175-250k | ~205-305k |
| `unwrapForTao` | ~170k | up to ~2x the sell loop at the 12-leg worst case |
| TAO20 mint NAV legs (~40 views) | ~1.3M | ~1.7M typical (~$3.2 total transaction) |
| `recoverStray` (rare) | — | ~90k |
| `recordBackingLoss` (rare, owner) | — | ~50k |
| Registry commit | ~90k | ~130k |

Costs do not scale with subnet occupancy. Deployed size is the binding
budget: AlphaVault is 22,293 of 24,576 bytes today, and `forge build
--sizes` is a hard gate after every implementation step.

## 13. Consumer guarantees (TAO20Index, BuybackTreasury)

TAO20 calls `previewUnwrap` inside its mint and salvage transactions —
twice per on-index vault plus once per held off-index vault — and the
buyback calls `unwrap` under an immutable 2.5M gas stipend inside
`try/catch`.

- **No new revert conditions on any view or exit.** The deposit guard
  reverts only inside the vault's own `wrap`, which TAO20 does not call.
  TAO20's mint, salvage and redeem, and the buyback's unwraps, cannot be
  halted by anything here.
- **Gas class O(tracked slots), independent of subnet size.** A 40-call
  mint budgets ~1.7M for its NAV legs; `unwrap` stays far under the
  stipend.
- **Views follow swaps in the same block**, so no single swap can feed
  TAO20's NAV a stale-location undercount. The detached-key sequence is the
  exception: while open, the vault and the index alike read low for that
  vault. The vault refuses its own deposits during it; TAO20's mint is not
  gated by the vault, so if TAO20 wants equivalent protection it must gate
  on its own side. This design does not impose that.

## 14. Test plan

### Mocks

- `MockMetagraph` (installed at the metagraph precompile address):
  uid-indexed hotkeys and owners; `getUidCount`; `getHotkey`/`getColdkey`
  reverting on unbound uids; `setNeuron(netuid, uid, hotkey, owner)`;
  `trimUids(netuid, newCount, mapping)`.
- `MockStaking`: per-hotkey owner-record flag (moves and unstakes revert
  without it), the 100k move floor on moves and transfers with whole
  positions included, full-drain exemption on unstakes only, whole-position
  re-keying, `transferStake` that keeps the hotkey fixed, and an emission
  helper that grows positions.
- Test-base helpers: `swapHotkeyOneSubnet(old, new, netuid, keepStake)`
  (uid rebind only when `old` is a member; owner record kept),
  `swapHotkeyFull(old, new, netuid, keepStake)` (same, old owner record
  cleared), `pruneNeuron(netuid, uid, newcomer, newcomerOwner)`,
  `associateHotkey(key, owner)`, `donateStake(...)`, clearing helpers for
  both the sale and delete branches.

### Unit (repo naming: `test_<Scenario>_<Outcome>`)

Swap following:
- `test_TotalStake_FollowsStakeMovingSwap` (same block, no intervening
  calls) and `test_PreviewUnwrap_FollowsStakeMovingSwap`, both scopes.
- `test_TotalStake_CountsStakeKeepingSwapOnStoredLeg`,
  `test_TotalStake_CountsPrunedSlotOnStoredLeg`,
  `test_TotalStake_SurvivesUidTrim`,
  `test_TotalStake_CountsCollidingLegOnce`,
  `test_UnionStake_SkipsResolutionForOutOfRangeUid`.

Deposit guard:
- `test_Wrap_RevertsWhenBackingUnaccounted` — the fact-4 sequence blocks
  the next deposit; both error arguments asserted.
- `test_Wrap_ResumesAfterRecovery` — one `recoverStray` restores deposits
  with no privileged call.
- `test_Unwrap_SucceedsWhileBackingUnaccounted`,
  `test_UnwrapForTao_SucceedsWhileBackingUnaccounted`,
  `test_PreviewUnwrap_QuotesWhileBackingUnaccounted`,
  `test_Rebalance_SucceedsWhileBackingUnaccounted` — money always leaves,
  views never gain the revert.
- `test_Rebalance_CannotLowerExpectedBacking` — the no-bypass property.
- `test_ExpectedBacking_FallsByExactAlphaPaidOut` (both exit rails),
  `test_ExpectedBacking_AbsorbsEmissionAndDonations`.
- `test_Wrap_SucceedsAfterLossRecorded`,
  `test_RecordBackingLoss_RevertsWithoutShortfall`,
  `test_RecordBackingLoss_RevertsForNonOwner`,
  `test_RecordBackingLoss_ChangesNoPrice`.

Targets, recovery, floors:
- `test_Wrap_ConsolidatesToResolvedKeyAfterSwap`,
  `test_Rebalance_RefusesRecycledSlotAsTarget`,
  `test_Wrap_RevertsOnForeignResolvedChosenHotkey`,
  `test_Wrap_RevertsWithoutLiveTarget`,
  `test_Consolidation_RepointsSlotToConfirmedKeyOnly`.
- `test_RecoverStray_MovesDetachedPosition`,
  `test_RecoverStray_RevertsOnUnionMemberHotkey`,
  `test_RecoverStray_RevertsWithoutLiveTarget`,
  `test_RecoverStray_RevertsOnZeroPosition`,
  `test_RecoverStray_RevertsOnOwnerlessSource`,
  `test_RecoverStray_SucceedsAfterAssociation`.
- `test_Unwrap_SucceedsAfterOwnerRecordRestored`.
- Registry: `test_RegistryCommit_RevertsOnOutOfRangeUid` (cleanly, and
  inside `updateValidatorsBatch`),
  `test_RegistryCommit_RevertsOnUidHotkeyMismatch`,
  `test_RegistryCommit_CapturesOwners`.
- Floors: move-path boundaries at 100k (flush gate, gather, consolidation,
  rebalance, delivery, recovery), unstake boundaries at 2e6, cap
  enforcement.

### Fuzz and invariant

- `testFuzz_Ops_PriceTrueBackingThroughChainEvents(uint8[] ops, uint8 eventKind, uint8 eventPoint)`
  — random operation interleavings with swaps (all four modes), prunes,
  trims, donations and emission at random points: quoted totals always
  equal the mock ledger over every key the vault holds, except while a
  detached-key sequence is open, which the handler cures and re-asserts.
- `testFuzz_Wrap_NeverMintsAgainstHiddenStake(uint256 hidden, uint256 deposit)`
  — after any hide, `wrap` either reverts or mints at a price consistent
  with the full ledger; a depositor can never obtain shares below fair
  value beyond the §7 residual bound.
- `testFuzz_ExpectedBacking_TracksVaultFlows(uint8[] ops)` — the figure
  never exceeds what the chain reported at write time, and falls only by
  amounts the vault paid out.
- `invariant_EveryKeyCountedOnce` — pricing equals the ledger under
  arbitrary leg collisions.
- `invariant_ExitsAlwaysAvailable` — no reachable state makes `unwrap` or
  `unwrapForTao` revert for backing reasons.
- `invariant_TrackedSlotHoldsItsStake` — each tracked slot's stored key is
  one the vault confirmed holds that slot's stake, or the slot is empty.

### Localnet e2e — mandatory before deployment

On a local subtensor node (per the e2e runbook: `scripts/localnet.sh` from
the subtensor checkout, btcli 9.23.2, 8M deploy gas), extending the pytest
suite. The mocks encode chain semantics by hand; only a real node validates
them:

1. **Hotkey swap, headline**: wrap a position; execute a real
   `swap_hotkey_v2(keep_stake=false)` on an attested validator; assert in
   the first block after inclusion, with no other calls, that `totalStake`
   and `previewUnwrap` are unchanged and a deposit still works; then
   `wrap` and `unwrap` succeed and `trackedSlots` shows the re-pointed key.
   Repeat for the all-subnets scope.
2. **Stake-keeping swap** (`keep_stake=true`, one subnet): totals unchanged
   through the stored leg; the next `rebalance` consolidates onto the valid
   target.
3. **Detached-key sequence**: `A->B keep_stake=true`, then `A->C
   keep_stake=false`; assert `wrap` reverts `BackingUnaccounted` while
   `unwrap`, `unwrapForTao` and `previewUnwrap` all still work;
   `recoverStray` restores totals exactly and deposits resume.
4. **Ownerless key**: all-subnets `keep_stake=true`; totals unchanged;
   `rebalance` reverts with the chain's missing-owner error;
   `try_associate_hotkey` from a substrate account; the next operation
   drains the key.
5. **Prune**: register a newcomer onto a full subnet recycling an attested
   slot; totals unchanged; the newcomer never becomes a move target;
   `rebalance` consolidates away.
6. **Trim**: `sudo_trim_to_max_allowed_uids`; totals unchanged; re-attest;
   swap-following works again.
7. **Clearing**: raise the nominator threshold via sudo; observe the
   repricing and the deposit block; `recordBackingLoss` restores deposits;
   verify sale proceeds reach holders through the existing claim index.
8. **Registry round-trip**: attest with uids against the live metagraph; a
   stale uid reverts on the binding check; an out-of-range uid reverts
   cleanly without burning the batch.
9. **Floors**: a whole-position move at, below and above the real 100k
   transfer minimum; sub-floor residue stays counted.
10. **Consumer profile**: measure `previewUnwrap` gas on the live node,
    project the TAO20 mint call pattern, and assert `unwrap` fits the 2.5M
    stipend with margin.

## 15. Changes outside `src/`

- `e2e/alpha_e2e/environment.py` (reads the old `lastSeenHotkeys` view) and
  the three e2e tests asserting on it — migrate to `trackedSlots`.
- `scripts/get_vault_state.py` — new `getValidators` tuple shape.
- `test/mocks/MockValidatorRegistry.sol` — carries uids and owners.
- `src/interfaces/IValidatorRegistry.sol` — new signature;
  `src/interfaces/IMetagraph.sol` — new file for the metagraph precompile.

## 16. Out of scope

- Validator-cap expansion (three slots; the widened internals leave it a
  registry-shape change later).
- Subtensor-side changes.
- TAO20-side changes: §13 states the guarantees and the one asymmetry
  (TAO20's mint is not gated by the vault's deposit guard).
