# Uid tracking: swap-resistant validator accounting for AlphaVault

Approved design, 2026-08-03. Written against:

- `~/Projects/alpha-wrapper` @ `781b14b` (main)
- `~/Projects/subtensor` @ `e4ffa2e13` (main, runtime v440) — all subtensor
  refs below
- `~/Projects/tao20-contract` (TAO20Index / BuybackTreasury as consumers of
  the vault's views)

Nothing is deployed yet, so this is a pre-deployment design: storage
layouts and the registry ABI are free to change, and no migration is
involved.

## 1. Problem and approach

The vault holds users' alpha under per-subnet clone coldkeys, delegated to
at most three attested validators per subnet, and remembers those
validators by hotkey. A hotkey is a value the chain reassigns: when a
validator swaps hotkeys, the chain migrates every delegator's position —
the vault's included — to the new hotkey, and the vault's stored bytes keep
pointing at an account that is now empty. Share pricing collapses, deposits
mint against an undercounted total, and integrators quoting the vault's
views inherit the error.

The chain publishes a stable handle for the same validator: its **uid**,
the numbered slot it occupies on the subnet. The chain rewrites
`uid -> hotkey` in the same extrinsic that migrates the stake (fact 1), so
a contract that remembers the uid alongside the hotkey can ask, at read
time, where that validator's stake lives now.

This design does exactly that:

- each tracked validator is stored as `(hotkey, uid)`;
- every balance read sums the position under the **stored** hotkey and
  under the **uid-resolved** hotkey;
- a permissionless `recoverStray` moves stake home in the rare cases the
  chain permits a position to land outside both.

One narrow sequence remains that uid resolution cannot follow (fact 4): a
validator can detach a key and swap it again, parking the position where
neither leg looks. That does not let anyone take the stake, but while it is
uncounted the vault prices shares too low, and **minting against a
too-low price is how the loss is realised** (§8 quantifies it). So the
design adds one guard, and only on that path:

- an **expected-backing figure** per token, moved only by amounts the
  vault itself knows — up by deposits, down by exactly the alpha paid out,
  and ratcheted up to whatever the chain reports when that is higher. New
  deposits are refused while observed backing sits below it (§7).

Exits, transfers, rebalancing and every pricing view are untouched by that
guard: the vault never pauses, and prices remain live chain reads. The
change is which keys get read, plus a mint-time check that the numbers add
up.

## 1a. Trade-offs in plain English

Everything this design gives up, stated without jargon. Nothing here is a
surprise to be discovered later; each item is deliberate.

**1. A validator we selected can temporarily hide some of our stake for
about 0.1 TAO, and new deposits stop until it is undone.**
A validator can perform two hotkey changes in a row that leave our stake
under a name nothing on the chain points to. The stake never leaves our
control — it cannot be stolen, only hidden — and anyone can bring it back
with a single public call. While it is hidden the vault notices that its
books no longer add up and refuses new deposits for that subnet.
Withdrawals, transfers and price reads keep working normally. So the cost
of this attack to us is an interruption in taking new money, not a loss of
existing money.

**2. Without that deposit guard, a validator could take a real slice of the
vault — which is why the guard exists.**
If deposits were allowed while stake is hidden, the attacker would deposit
at the artificially low price, let the stake reappear, and walk away with
part of everyone else's money. The size is not trivial: with three
validators, one of them hiding their share and depositing a tenth of the
vault's value takes roughly 4% of the vault, at about a 43% return on the
money they put in, for a ~$19 fee. Depositing more takes more, up to the
whole hidden amount. Watching for it does not help, because the attacker
can hide and deposit within a block or two, and because the recovery step
they need is one anyone can perform. This is the one place where a
monitoring-only answer genuinely fails, so the contract blocks it instead.

**3. That guard is deliberately the only thing the contract blocks.**
It stops new deposits on the affected subnet and nothing else — money can
always leave, prices always read live, TAO20 is never halted. We did not
add contract machinery for anything else on this list, because the
alternative was several hundred lines of accounting in a contract with
about 2,000 bytes of room left, plus a freeze that would spread into
TAO20's minting. More code is more bugs, and a freeze is its own way to
lose money.

**3a. A genuine loss leaves deposits blocked until the owner acknowledges
it.**
If the chain really destroys stake (item 5), the books legitimately no
longer add up, and the same guard keeps refusing deposits. The owner then
records the loss on-chain, which only re-enables deposits — it cannot
change any price, and it is publicly visible. Until they do, the vault
takes no new money.

**4. Some chain events can freeze one subnet's operations until someone
sends a substrate transaction.**
One specific hotkey change (an all-subnets swap that leaves stake behind)
deletes the chain's record of who owns that name. The chain then refuses to
let anyone move that stake — us or anybody else. Deposits and withdrawals
for that subnet stop working until someone (anyone, ~free) sends one
substrate transaction that restores the record. Our own vault cannot send
that transaction; only a substrate account can, so the operator must be
watching. Money is not lost, only stuck.

**5. Real losses show up immediately as a lower share price, with no
warning and no cushion.**
If the chain destroys stake — a governance action that clears small
positions, or a root-level takeover of our account — the vault reprices
downward straight away, because prices are always read live. There is no
pause, no reserve, and no admin switch to soften it. Holders see the truth
at once. We consider that better than pretending, but it means a bad chain
event is visible to users before anyone can explain it.

**6. Attesters must do more work, and the vault trusts them slightly more.**
Attestations now include each validator's slot number, so attester software
must be updated and must re-attest after routine chain events (validator
changes keys, gets pruned, subnet renumbering, validator changes their
coldkey). If they are slow, the vault keeps counting every balance
correctly, but it temporarily loses the ability to follow that validator's
next key change automatically.

**7. Everything costs slightly more gas.**
Reading prices goes from about 33k to about 42k gas — roughly a cent per
call at current prices. A deposit goes up ~10%. For TAO20, whose mint reads
these prices about forty times, the increase is about $0.70 per mint. Small,
but it is charged on every operation forever.

## 2. Chain facts this design stands on (verified 2026-08-03, runtime v440)

1. **A registered validator's swap rebinds the uid atomically with a
   whole-position stake migration.** `swap_hotkey_v2(hotkey, newHotkey,
   Option<netuid>, keep_stake)` rewrites `Keys(netuid, uid) -> newHotkey`
   and membership for a registered validator
   (`swap/swap_hotkey.rs:626-646`, executed per subnet in the all-subnets
   loop); when `keep_stake == false` — which the legacy `swap_hotkey`
   hardcodes (`macros/dispatches.rs:843-850`) — the migration reads each
   delegator position in full and moves all of it in the same extrinsic
   (`:774+`). There is no partial re-key.
2. **`keep_stake = true` leaves the stake on the old hotkey**, which stays
   readable under the stored leg. One-subnet scope keeps the old key's
   owner record (`swap_hotkey.rs:530`); all-subnets scope deletes it
   (`:393`).
3. **Owner records gate stake operations.** Moves and unstakes require an
   owner record on the keys involved (`hotkey_account_exists` =
   `Owner.contains_key`, `staking/helpers.rs:207`;
   `stake_utils.rs:1309-1319`, `:1213-1216`). Stake under an ownerless key
   is frozen for everyone until the permissionless, insert-only
   `try_associate_hotkey(hotkey)` restores a record
   (`macros/dispatches.rs:1523-1529`, `staking/account.rs:4-12` — it cannot
   hijack an owned key). While a tracked key is ownerless, vault paths that
   would move or sell that position revert at full gas.
4. **A detached key can be swapped without moving any uid.** The uid rebind
   is conditional on membership (`swap_hotkey.rs:626`); the stake migration
   is not, and the caller need only own the old key (`:86`), not have it
   registered. So `A->B keep_stake=true` followed by `A->C
   keep_stake=false` moves the stake to `C` while the uid still points at
   `B`: the position lands outside both legs. §8 states the exposure this
   creates and why it is accepted; `recoverStray` (§6) is its cure.
5. **Pruning recycles a slot and touches no stake.** On a full subnet a
   newcomer's registration rebinds the pruned uid to the newcomer
   (`subnets/registration.rs:27-29`, `subnets/uids.rs:62-116`) while the
   pruned key's positions persist untouched. The vault keeps reading them
   through the stored leg.
6. **Uids can be renumbered.** `trim_to_max_allowed_uids` compacts
   survivors onto new uids (`subnets/uids.rs:151`, `Keys::swap` at `:322`)
   and lowers the count (`:379`), callable via
   `sudo_trim_to_max_allowed_uids` (`pallets/admin-utils/src/lib.rs:1927`).
   A stored uid is therefore a refreshable pointer, not a permanent
   identity; the registry rebinds it at every attestation, and balances
   stay visible through the stored leg meanwhile.
7. **A validator's coldkey can change**, rewriting `Owner` for all its
   hotkeys (`swap/swap_coldkey.rs:168-186`); any owner value captured
   earlier goes stale, and re-attestation is the remedy.
8. **Metagraph precompile** (`0x0000000000000000000000000000000000000802`):
   `getUidCount(uint16)` (1 db read), `getHotkey(uint16,uint16)` (1 db
   read), `getColdkey(uint16,uint16)` (2 db reads — the owner of the key
   currently at that uid) (`precompiles/src/metagraph.rs:29-36,163-186`).
   `getHotkey`/`getColdkey` revert `InvalidRange` on an unbound uid, and a
   failed precompile call consumes all forwarded gas with empty returndata
   — so **no code path may resolve a uid without first bounding it against
   a fresh `getUidCount`**. With that guard in place, in-range uids are
   always bound: live subnets keep uids contiguous, trims compact and lower
   the count in one extrinsic, and dissolution zeroes the count before
   clearing keys. The uid cap is 256 (`runtime/src/lib.rs:788`; the admin
   setter rejects larger values, `pallets/admin-utils/src/lib.rs:566-568`).
9. **Two distinct chain floors.** Same-subnet moves and transfers require a
   tao value of at least the transfer minimum — 100,000 RAO (0.0001 TAO),
   whole-position moves included (`staking/stake_utils.rs:1035-1048`,
   `runtime/src/lib.rs:819`). Unstake sizing is governed separately
   (2e6-anchored family; full-balance unstakes exempt). No precompile
   exposes the transfer minimum, so the vault mirrors it (§7).
10. `getStake(hotkey, coldkey, netuid)` charges a flat 7 db reads = 4,375
    gas (`precompiles/src/staking.rs:336-356`); absent positions read zero.
    `transferStake` moves a position between coldkeys under a single hotkey
    (`precompiles/src/staking.rs:263-272`, `CloneBase.flush`): a flush
    cannot change the hotkey — only `moveStake` can.

## 3. Contract surface

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
whole transaction's gas, fact 8), then require `getHotkey(netuid, uid) ==
hotkey` (`UidHotkeyMismatch` — swap-following depends on the binding being
true when it enters storage), then capture `owners[i] = getColdkey(netuid,
uid)`. The EIP-712 typehash changes with the payload (attester tooling
update, §9).

Solidity cannot overload on return type, so the wider `getValidators`
replaces the old signature. Complete consumer list to migrate:
`AlphaVault._resolveValidators`, `AlphaVault._unionStake`,
`src/interfaces/IValidatorRegistry.sol`,
`test/mocks/MockValidatorRegistry.sol`, the registry and vault test suites,
and `scripts/get_vault_state.py`. TAO20 and BuybackTreasury do not call the
registry (the buyback uses the vault's `getCurrentValidators(uint256) ->
bytes32[3]`, which is unchanged).

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

error HotkeyNotStray();
error NoLiveTarget();
error BackingUnaccounted(uint256 expected, uint256 observed);
error NoBackingShortfall();
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
`trackedSlots`. Every view keeps its exact signature, semantics, and revert
surface (§5). Internal union arrays widen from 6 to 12 candidate legs, and
`unwrapForTao`'s sell loop iterates the widened set.

## 4. Read path

Pricing views and operation working sets share one construction:

1. Read `uidCount = getUidCount(netuid)` once per call.
2. **Slot legs** — for each of the three tracked slots: the stored
   `hotkey`, plus `getHotkey(netuid, uid)` when `uid < uidCount` (an
   out-of-range anchor contributes its stored leg only).
3. **Attested legs** — for each registry slot: its hotkey, plus its
   uid-resolution under the same guard, so a freshly attested validator is
   visible before the next consolidation re-points the tracked slots.
4. **Deduplicate** the resulting keys and read `getStake` once per unique
   key; each unique key's balance counts exactly once. Assign each key to
   the first tracked slot that names it (stored leg before resolved leg)
   for the per-slot balances the working set needs; keys named only by
   attested legs count toward the total but belong to no slot.

Zero hotkeys are skipped. Since the total is a sum over unique keys, it is
independent of which slot claims a key.

## 5. Behavior under chain events

| Event | What the read path sees | Follow-up |
|---|---|---|
| Swap, stake follows (`keep_stake=false`, either scope) — the common mode | The resolved leg picks up the new key in the block the stake moved; totals unchanged | none; the next operation consolidates and re-points the stored leg |
| Swap, stake stays (`keep_stake=true`, one subnet) | The stored leg keeps counting the old key | none; consolidation moves it to a valid target |
| Swap, stake stays, all subnets (old key ownerless) | The stored leg keeps counting; the stake is recoverable, so counting it is honest. Vault paths that would move or sell that position revert at full gas until an owner record exists (fact 3) | anyone sends the substrate `try_associate_hotkey(old)`; operator preferred (§9) |
| Validator pruned (slot recycled) | The stored leg keeps counting the pruned key; the newcomer at that uid holds none of the vault's stake and fails the target check (§6) | none; consolidation moves the stake to healthy slots; re-attest at convenience |
| Uid trim (anchors renumbered) | Stored legs keep counting; resolutions may point at other validators until re-attestation, and are never used as move targets | re-attest promptly (§9) |
| Validator coldkey swap | No balance change; the captured owner is stale, so that slot has no valid target until re-attestation | re-attest |
| Detached-key double swap (fact 4) | The position lands outside both legs and stops being counted until recovered | anyone calls `recoverStray`; §8 states the accepted exposure |
| Forced clearing of sub-threshold nominations, or a root-level coldkey swap of the clone | Balances drop; live reads reprice shares truthfully and immediately | none available on-chain; §9 alerting |

Views (`totalStake`, `sharePrice`, `previewWrap`, `previewUnwrap`,
`getCurrentValidators`) gain no new revert conditions: they revert exactly
where they do today (dissolution blackout, dissolved position, no attested
validators). Nothing in this design can pause the vault.

## 6. Targets, consolidation, and recovery

**Valid target.** Stake may only be moved or routed to an attested slot
whose anchor passes all three checks: `uid < uidCount`,
`getHotkey(netuid, uid) == candidate`, and `getColdkey(netuid, uid) ==
owners[slot]` from the registry. The owner check establishes custody
continuity — the slot is still operated by the coldkey that was attested —
so a recycled or renumbered slot is never a destination. Reading a
stranger's key stays harmless (the vault's balance under it is zero);
moving stake toward one is what the check prevents. If no attested slot has
a valid target, moves are skipped and `wrap` reverts `NoLiveTarget`, since
a deposit must not land on an unverifiable destination; exits that need no
target (`unwrapForTao`) still work. Re-attestation restores targets.

**Deposits.** `wrap`'s `chosenHotkey` must be an attested stored key or a
valid-target resolved key. The mailbox flush lands the deposit under
`chosenHotkey` itself (a flush changes only the coldkey — fact 10); the
same call's consolidation then moves it onto the slot's valid target when
the value clears the move floor.

**Consolidation and refresh.** The existing rotated-stake consolidation
keeps its shape, with every destination passing the valid-target rule and
every move pre-check using `minMoveTaoFloor` (§7). At the end of a
mutating operation each tracked slot is refreshed to **the key the vault
confirmed holds that slot's stake** — the valid target it moved the stake
to, or the key the stake verifiably remained on — with the uid of the
attested slot it was consolidated onto. A slot is never re-pointed away
from a key that still holds its stake: if consolidation could not complete
for a slot, that slot's entry is left untouched.

**recoverStray.**

```solidity
function recoverStray(uint256 netuid, bytes32 strayHotkey, uint256 targetSlot) external nonReentrant
```

Permissionless, move-only, and the whole cure surface. Guards: netuid in
range, clone exists, subnet not dissolving, non-zero `strayHotkey`, the key
is not already among the candidate legs (`HotkeyNotStray` — a key the union
already reads needs no recovery), and `targetSlot` indexes an attested slot
with a valid target (`NoLiveTarget`). Then read
`amount = getStake(strayHotkey, cloneColdkey, netuid)` (`ZeroAmount` if
none), move the full amount onto that target through the clone, and emit
`StrayStakeRecovered`.

The caller supplies a location and nothing else: the amount comes from the
chain, the destination is attested and owner-checked, and the chain rejects
a move whose source lacks an owner record or whose value is below the
transfer minimum. A wrong call reverts and changes nothing. The recovered
stake is counted again at the next read, with no accounting to reconcile.

## 7. The deposit guard

Minting is the only path where an undercount transfers value between users
(§8 derives the size), so it is the only path this design gates.

**The figure.** `expectedBacking[tokenId]` is the backing the vault's own
flows account for. It moves in exactly four ways, all from amounts the
vault already knows:

| When | Change |
|---|---|
| End of any mutating operation | `expected = max(expected, observed)` — chain-side growth (emission, donations, recovered stake) is absorbed as soon as it is seen |
| Deposit (`wrap`) | `expected += depositedAlpha` (the amount flushed in) |
| Alpha paid out (`unwrap` delivery) | `expected -= alphaOut` (the exact amount transferred to the user) |
| Alpha sold (`unwrapForTao` legs) | `expected -= alphaSold` (the exact amount unstaked) |
| Owner records a loss (below) | `expected = observed` |

Nothing else writes it, and no caller-supplied number ever reaches it.
Because it only falls by amounts the vault itself paid out, no operation
can be used to walk it down: calling `rebalance` after hiding stake leaves
it untouched, so the guard cannot be cleared by poking the contract.

**The check.** `wrap` computes observed backing (§4) after its existing
guards and before the mailbox flush, and reverts
`BackingUnaccounted(expected, observed)` when `observed < expected`. That
is the entire enforcement surface: `unwrap`, `unwrapForTao`, `rebalance`,
`recoverStray`, share transfers, and every view are unaffected and never
revert on this condition. Money can always leave; only new money is
refused. TAO20's NAV reads and the buyback's unwraps are untouched (§11).

**Clearing the block.** Whoever hid the stake needs it counted again to
profit, and so does everyone else: one `recoverStray` call restores
observed backing above the figure and deposits resume automatically, with
no further action. Nothing privileged is involved.

**Genuine losses.** When stake is truly destroyed (§5's clearing and
takeover rows) the shortfall is permanent, so deposits would stay blocked
forever. `recordBackingLoss(tokenId)` — owner-only, requires a live
shortfall (`NoBackingShortfall`) — sets the figure to observed backing and
emits `BackingLossRecorded` with both values. It re-enables deposits and
does nothing else: it touches no price, no share, and no stake, so the
worst an owner can do with it is admit a loss that has already repriced
holders' shares, in public. There is deliberately no delay: the call cannot
move value, and the alternative (deposits frozen pending a timer) only
punishes users for a loss they have already taken.

**Residual.** A hide smaller than the backing growth absorbed since the
last operation slips under the figure, because that growth has already
been folded in. Bounding it is emission over the gap between operations —
dust at any realistic cadence, and worth less than the ~0.1 TAO of swap
fees the attempt costs. §8 states the arithmetic.

## 7a. Floors

`minMoveTaoFloor` (init 100,000 RAO; owner-tunable, capped at 10,000,000,
`MinMoveTaoFloorTooHigh`) gates every pre-check on a move or transfer:
consolidation, rebalance steps, gather hops, the deposit flush, delivery,
and `recoverStray`. `minStakeTaoFloor` (existing, init 2e6) keeps gating
unstake sizing in the sell paths. Each vault-side pre-check mirrors exactly
one chain-side check; the implementation records that mapping with
subtensor citations in the PR description. Residue below the move floor
stays where it sits and stays counted through the stored leg.

## 8. The detached-key sequence, and why minting is gated

Fact 4 permits a validator to park the vault's position under a key that no
uid resolves to: swap `A->B` with `keep_stake=true`, then swap `A->C` with
`keep_stake=false`. The vault stops counting that position until someone
calls `recoverStray(netuid, C, slot)`.

**Cost to the attacker.** Two swap fees. The per-subnet second step is
cooldown-gated for a day (`swap_hotkey.rs:491`, keyed by coldkey and
checked unconditionally), so a same-block sequence uses the all-subnets
scope for the second step (~0.1 TAO); the cooldown there binds only
subnets where the old key is still a member (`:253-260`), which after step
one it is not.

**What an ungated mint would be worth.** With backing `T`, supply `S`, a
hidden amount `H` and a deposit `D` made while hidden, the attacker
receives `D·S/(T-H)` shares instead of `D·S/T`. After the stake is
recovered, backing is `T+D` over the inflated supply, so:

```
attacker profit = holders' loss = D·H / (T - H + D)
```

Writing `H = w·T` (the attacker's attested weight) and `d = D/T`, the loss
as a fraction of the vault is `w·d / (1 - w + d)`. At three equal-weighted
validators (`w = 1/3`):

| Deposit | Holders lose | Attacker's return on deposit |
|---|---|---|
| 10% of vault | 4.3% of vault | 43% |
| 50% | 14.3% | 29% |
| 100% | 20% | 20% |
| unbounded | 33% (the whole hidden amount) | -> 0 |

Two properties decide the design. Small deposits have the **highest**
return, so this is not a whale-only attack. And monitoring cannot prevent
it: the attacker can hide and deposit in adjacent blocks, and the recovery
step they depend on is one anyone will happily perform — a watcher racing
to recover *completes* the attack rather than stopping it.

**Therefore minting is gated (§7) and nothing else is.** The guard makes
the profitable branch unreachable: with deposits refused while the books
are short, hiding stake buys the attacker an interruption in the vault's
deposit flow and a ~0.1 TAO bill, with no path to holders' value. What
remains is a griefing cost, bounded by how long recovery takes — and
recovery is permissionless, single-call, and something the attacker's own
victims, the operator, and any bystander can each perform.

**Residual, quantified.** The guard absorbs chain-side growth (§7), so a
hide smaller than the growth since the last operation stays under it. That
bound is emission accrued over the gap between operations — a fraction of
a percent per hour on a live subnet — and it is worth less than the swap
fees required to attempt it.

**Related, smaller exposures**, all reversible: stake under an ownerless
key halts operations on that subnet until a substrate association (fact 3);
the owner check binds custody rather than validator identity, so another
hotkey of the same operator landing on the anchored uid would pass it; and
anchors go stale between attestations after a trim or coldkey swap, costing
swap-following on that slot until re-attestation while every balance stays
counted through the stored leg.

Operational response remains part of shipping this design (§9) — recover
promptly to restore deposits, and evict a validator that does this — but
it is now a liveness measure, not the thing standing between an attacker
and holders' money.

## 9. Operational runbook

1. **Attester payload**: attestations carry uids; the typehash changes;
   stale or out-of-range uids revert at commit — re-read the metagraph and
   re-sign. Re-attest promptly after any swap, prune, uid trim, or
   validator coldkey swap touching an attested validator.
2. **Swap monitoring** (liveness, not safety — §8): watch swap extrinsics
   for attested validators. On a stake-moving swap no action is needed for
   pricing; poke the permissionless `rebalance(netuid)` at convenience so
   consolidation re-points the stored leg. On a `keep_stake=true` swap,
   treat it as a warning sign: re-attest away from that validator, and
   watch for a second swap on the detached key. If the
   detached-key sequence completes, read the clone coldkey's staking index
   from a single RPC state query to locate the position and call
   `recoverStray`.
3. **Ownerless key**: if a move or sale reverts because a key lost its
   owner record, send `try_associate_hotkey(key)` from the operator's own
   substrate account (keeping the key out of a stranger's hands — a
   stranger who associates first can relocate the position again, though
   never take it), then retry.
4. **Loss alerting and acknowledgement**: forced clearing of sub-threshold
   nominations and any clone-coldkey anomaly reprice shares immediately and
   truthfully; holders should hear it from the operator rather than from the
   chart. Because the shortfall is permanent, deposits stay blocked until
   the owner calls `recordBackingLoss(tokenId)` — verify the loss is real
   and unrecoverable (a `recoverStray` would restore deposits by itself)
   before acknowledging it.
5. **Runtime upgrades**: re-verify the transfer minimum (mirrored as
   `minMoveTaoFloor`), the metagraph and staking precompile ABIs, and the
   uid cap before resuming normal operations.

## 10. Gas and size (live-priced 2026-08-03: 10 gwei, TAO $188.48)

| Operation | Today | This design |
|---|---|---|
| View (`previewUnwrap` / `sharePrice`) | ~33k | ~42k typical, ~75k worst (~$0.008-0.014) |
| `wrap` | ~250k | ~283k (~$0.053) — includes the guard read and update |
| `unwrap` | ~175-250k | ~205-305k |
| `unwrapForTao` | ~170k | up to ~2x the sell loop at the 12-leg worst case |
| TAO20 mint NAV legs (~40 views) | ~1.3M | ~1.7M typical (~$3.2 total transaction) |
| `recoverStray` (rare) | — | ~90k |
| `recordBackingLoss` (rare, owner) | — | ~50k |
| Registry commit | ~90k | ~130k |

Costs do not scale with subnet occupancy. Deployed size is the binding
budget: AlphaVault is 22,293 of 24,576 bytes today, and `forge build
--sizes` is a hard gate after every implementation step.

## 11. Consumer guarantees (TAO20Index, BuybackTreasury)

TAO20 calls `previewUnwrap` inside its mint and salvage transactions —
twice per on-index vault plus once per held off-index vault — and the
buyback calls `unwrap` under an immutable 2.5M gas stipend inside
`try/catch`.

- **No new revert conditions on any view** (§5), and the deposit guard
  (§7) touches no view and no exit: TAO20's mint, salvage and redeem, and
  the buyback's unwraps, cannot be halted by anything this design
  introduces. The guard reverts only inside the vault's own `wrap`, which
  TAO20 does not call.
- **Gas class O(tracked slots), independent of subnet size**: a 40-call
  mint budgets ~1.7M for its NAV legs; `unwrap` stays far under the buyback
  stipend.
- **Views follow swaps in the same block**, so a validator cannot feed
  TAO20's NAV a stale-location undercount by timing a single swap. The
  detached-key sequence (§8) is the exception: while it is open, the vault
  and the index alike read low, so TAO20 mints against a depressed NAV for
  that vault until recovery. TAO20's own users are protected the same way
  vault depositors are — by how briefly the state can persist, since anyone
  can end it with one call — but unlike the vault's `wrap`, TAO20's mint is
  not gated by the vault. If TAO20 wants the same protection it must gate
  on its own side; this design does not impose that.

## 12. Test plan

### Mocks

- `MockMetagraph` (installed at the metagraph precompile address):
  uid-indexed hotkeys and owners; `getUidCount`; `getHotkey`/`getColdkey`
  reverting on unbound uids; `setNeuron(netuid, uid, hotkey, owner)`;
  `trimUids(netuid, newCount, mapping)`.
- `MockStaking`: per-hotkey owner-record flag (moves and unstakes revert
  without it), the 100k move floor on moves and transfers with whole
  positions included, full-drain exemption on unstakes only, whole-position
  re-keying, and `transferStake` that keeps the hotkey fixed.
- Test-base helpers: `swapHotkeyOneSubnet(old, new, netuid, keepStake)`
  (uid rebind only when `old` is a member; owner record kept),
  `swapHotkeyFull(old, new, netuid, keepStake)` (same, old owner record
  cleared), `pruneNeuron(netuid, uid, newcomer, newcomerOwner)`,
  `associateHotkey(key, owner)`, `donateStake(...)`.

### Unit (repo naming)

- `test_TotalStake_FollowsStakeMovingSwap` — same block, no intervening
  calls; `test_PreviewUnwrap_FollowsStakeMovingSwap` (the TAO20 guarantee);
  both scopes.
- `test_TotalStake_CountsStakeKeepingSwapOnStoredLeg`,
  `test_TotalStake_CountsPrunedSlotOnStoredLeg`,
  `test_TotalStake_SurvivesUidTrim`,
  `test_TotalStake_CountsCollidingLegOnce` (one key named by two legs).
- `test_UnionStake_SkipsResolutionForOutOfRangeUid` (subnet shrank below a
  stored uid; no metagraph revert reaches the caller).
- `test_Wrap_ConsolidatesToResolvedKeyAfterSwap`,
  `test_Rebalance_RefusesRecycledSlotAsTarget`,
  `test_Wrap_RevertsOnForeignResolvedChosenHotkey`,
  `test_Wrap_RevertsWithoutLiveTarget`,
  `test_Consolidation_RepointsSlotToConfirmedKeyOnly` (a slot is never
  re-pointed away from a key still holding its stake — recycled-slot and
  `keep_stake=true` cases).
- `test_RecoverStray_MovesDetachedPosition` (the fact-4 sequence),
  `test_RecoverStray_RevertsOnUnionMemberHotkey`,
  `test_RecoverStray_RevertsWithoutLiveTarget`,
  `test_RecoverStray_RevertsOnZeroPosition`,
  `test_RecoverStray_RevertsOnOwnerlessSource` then
  `test_RecoverStray_SucceedsAfterAssociation`.
- Deposit guard: `test_Wrap_RevertsWhenBackingUnaccounted` (the fact-4
  sequence blocks the next deposit, both error arguments asserted);
  `test_Wrap_ResumesAfterRecovery` (one `recoverStray` restores deposits
  with no privileged call); `test_Unwrap_SucceedsWhileBackingUnaccounted`
  and `test_UnwrapForTao_SucceedsWhileBackingUnaccounted` (money can always
  leave); `test_PreviewUnwrap_QuotesWhileBackingUnaccounted` (views never
  gain the revert); `test_Rebalance_CannotLowerExpectedBacking` (the
  no-bypass property — poking the contract never clears the guard);
  `test_ExpectedBacking_FallsByExactAlphaPaidOut` (withdrawal accounting,
  both rails); `test_ExpectedBacking_AbsorbsEmissionAndDonations` (growth
  ratchets the figure up, deposits keep working);
  `test_Wrap_SucceedsAfterLossRecorded` and
  `test_RecordBackingLoss_RevertsWithoutShortfall` /
  `test_RecordBackingLoss_RevertsForNonOwner`.
- `test_Unwrap_SucceedsAfterOwnerRecordRestored`.
- Registry: `test_RegistryCommit_RevertsOnOutOfRangeUid` (clean revert, and
  inside `updateValidatorsBatch`), `test_RegistryCommit_RevertsOnUidHotkeyMismatch`,
  `test_RegistryCommit_CapturesOwners`.
- Floors: move-path boundaries at 100k (flush gate, gather, consolidation,
  rebalance, delivery, recovery), unstake boundaries at 2e6, cap
  enforcement.

### Fuzz and invariant

- `testFuzz_Ops_PriceTrueBackingThroughChainEvents(uint8[] ops, uint8 eventKind, uint8 eventPoint)`
  — random operation interleavings with swaps (all four modes), prunes,
  trims and donations injected at random points; the quoted total always
  equals the mock ledger's total over every key the vault holds, except
  during an open detached-key sequence, which the handler cures with
  `recoverStray` and then re-asserts equality.
- `testFuzz_Consolidation_NeverTargetsInvalidSlot` — no move destination
  ever fails the valid-target rule.
- `invariant_EveryKeyCountedOnce` — pricing equals the ledger under
  arbitrary leg collisions.
- `invariant_TrackedSlotHoldsItsStake` — after any operation sequence, each
  tracked slot's stored key is a key the vault confirmed holds that slot's
  stake, or the slot is empty.

### Localnet e2e — mandatory before deployment

Real-runtime validation on a local subtensor node (per the e2e runbook:
`scripts/localnet.sh` from the subtensor checkout, btcli 9.23.2, 8M deploy
gas), extending the existing pytest suite. The mocks encode chain semantics
by hand; only a real node validates them:

1. **Hotkey swap, headline**: wrap a position; execute a real
   `swap_hotkey_v2(keep_stake=false)` on an attested validator; assert in
   the first block after inclusion, with no other calls, that `totalStake`
   and `previewUnwrap` are unchanged; then `wrap` and `unwrap` succeed and
   `trackedSlots` shows the re-pointed key. Repeat for the all-subnets
   scope.
2. **Stake-keeping swap** (`keep_stake=true`, one subnet): totals unchanged
   through the stored leg; the next `rebalance` consolidates onto the valid
   target.
3. **Ownerless key**: all-subnets `keep_stake=true`; totals unchanged;
   `rebalance` reverts with the chain's missing-owner error;
   `try_associate_hotkey` from a substrate account; the next operation
   drains the key.
4. **Detached-key sequence**: `A->B keep_stake=true`, then `A->C
   keep_stake=false`; observe the undercount; `recoverStray` restores it
   and totals return exactly.
5. **Prune**: register a newcomer onto a full subnet recycling an attested
   slot; totals unchanged; the newcomer never becomes a move target;
   `rebalance` consolidates away.
6. **Trim**: `sudo_trim_to_max_allowed_uids`; totals unchanged; re-attest;
   swap-following works again.
7. **Registry round-trip**: attest with uids against the live metagraph; a
   stale uid reverts on the binding check; an out-of-range uid reverts
   cleanly without burning the batch.
8. **Floors**: a whole-position move at, below, and above the real 100k
   transfer minimum; sub-floor residue stays counted.
9. **Consumer profile**: measure `previewUnwrap` gas on the live node,
   project the TAO20 mint call pattern, and assert `unwrap` fits the 2.5M
   stipend with margin.

## 13. Changes outside `src/`

- `e2e/alpha_e2e/environment.py` (reads the old `lastSeenHotkeys` view) and
  the three e2e tests asserting on it — migrate to `trackedSlots`.
- `scripts/get_vault_state.py` — new `getValidators` tuple shape.
- `test/mocks/MockValidatorRegistry.sol` — carries uids and owners.
- `src/interfaces/IValidatorRegistry.sol` — new signature;
  `src/interfaces/IMetagraph.sol` — new file for the metagraph precompile.

## 14. Out of scope

- Validator-cap expansion (three slots; the widened internals leave it a
  registry-shape change later).
- Subtensor-side changes.
- On-chain prevention of the detached-key sequence (§8 states the accepted
  exposure and the operational control that covers it).
- TAO20-side changes: none required; §11 states the guarantees.
