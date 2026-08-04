# Backing Checkpoint Guard

Protects AlphaVault holders when a validator changes its hotkey on chain. The vault
remembers how much stake it holds on each validator; if that stake ever drops without
the vault's own doing, every deposit, exit, and price quote halts until someone shows
the chain address the stake moved to. Anyone can do that with one transaction. If the
stake is genuinely unrecoverable, the owner can switch the affected subnet token into a
one-way exit-only mode.

## Problem

The vault's backing is alpha staked on up to three validator hotkeys per subnet
(`_lastSeenHotkeys` union the current `ValidatorRegistry` set, read via `_unionStake`).
Subtensor lets a validator operator swap its hotkey: `swap_hotkey(old, new, netuid,
keep_stake=false)` re-keys the entire per-subnet stake pool, including the vault's
nomination, onto the new hotkey. The vault has no way to learn the new hotkey on its
own, so after a swap:

- `totalStake` no longer sees the moved stake and the share price collapses,
- `wrap` mints shares against the collapsed price (attacker mints cheap),
- `unwrap` and `unwrapForTao` pay exiting holders a fraction of what their shares are
  worth.

The stake is not lost - it sits under the vault clone's coldkey on a hotkey the vault
does not know about - but every flow misprices until the vault finds it.

## Chain facts this design rests on

Verified in subtensor source (`~/Projects/subtensor`, main @ 2026-08-04) and against
live mainnet (spec 440):

1. **Nobody but the vault's coldkey can reduce a (hotkey, vault-coldkey) stake entry**,
   with exactly three exceptions: a hotkey swap by the validator operator, subnet
   dissolution (already gated by `isSubnetDissolving`), and a governance dust sweep
   (fact 5). Emissions only ever increase the entry. Verified by enumerating every
   caller of the stake-reduction paths (`staking/remove_stake.rs`,
   `staking/helpers.rs:228-283`, `coinbase/block_step.rs`).
2. **A hotkey swap moves the entire per-subnet stake, always** - partial drops from
   swaps are impossible (`swap/swap_hotkey.rs`). The moved stake always lands on a
   hotkey readable via `getStake(newHotkey, ourColdkey, netuid)`.
3. **A swap may merge into a hotkey the vault already tracks.** The destination may be
   an existing hotkey account when the same operator coldkey owns both and the
   destination is not currently registered on the subnet (`swap_hotkey.rs:96-146`).
   Since stake survives deregistration, a deregistered-but-still-staked tracked hotkey
   is a legal merge destination. Two tracked hotkeys of one operator can even merge
   into the same destination, one after the other. Recovery must handle both.
4. **The `keep_stake=true` swap variant leaves stake on the old hotkey.** Nothing
   drops, pricing stays correct; the stake just stops earning until rotated. No action
   needed.
5. **The only unsigned reduction is a governance dust sweep**: when the chain admin
   raises the nominator minimum (currently 0.02 TAO), a global batch force-sells any
   stake entry whose spot value is below the new minimum. The entry zeroes; the sale's
   TAO proceeds, minus the chain's swap fee, arrive on the vault clone as native
   balance, which the existing claimable-TAO index captures for holders. There is no
   on-chain way to prove after the fact that a zeroed entry was swept rather than
   swapped, so this design does not try to tell them apart.
6. **Anyone can place alpha under the vault's coldkey** via `transfer_stake`
   (minimum 0.0001 TAO worth). Third parties can only ever add to the vault's
   backing, never subtract - which is why donations are safe and useful (fact 5's
   freeze can be cured with one).
7. **Same-subnet `moveStake` has no chain minimum** (`stake_utils.rs`, the minimum
   check is skipped when origin and destination netuid match), so the vault can move
   arbitrarily small remainders between hotkeys. `_consolidateRotatedStake` already
   relies on this.
8. **Read-path rounding**: stake values are computed from share-pool fixed-point math,
   so a passive entry's readable value can jitter downward by a few RAO when other
   nominators move in or out of the same pool.

## Design

Three pieces: a checkpoint per tracked validator, one verification rule that halts
everything on an unexplained drop, and a permissionless repair function. Plus a one-way
owner escape hatch for the unrecoverable case.

### Storage

```solidity
/// Alpha the vault held on each _lastSeenHotkeys slot after the last state-mutating call.
mapping(uint256 tokenId => uint256[3]) private _stakeCheckpoints;

/// One-way per-token switch: exits continue against live backing, deposits stop forever.
mapping(uint256 tokenId => bool) public emergencyMode;
```

Checkpoints are slot-aligned with `_lastSeenHotkeys[tokenId]`.

### Verification: one rule

For each tracked slot with hotkey `H`, checkpoint `C`, and live stake
`L = getStake(H, coldkey, netuid)`:

```
pass  when L + TOLERANCE >= C
halt  otherwise: revert StakeDeficit(H, C, L)
```

`TOLERANCE` is a constant 1,000 RAO of alpha per slot - three orders of magnitude above
observed share-pool rounding jitter (fact 8), three orders below economic relevance.
There is no other exception. A governance dust sweep (fact 5) therefore halts the vault
too; that is deliberate, because sweep and swap are indistinguishable on chain, and the
cure is cheap (see Recovery).

There is no stored pause flag. "Halted" simply means verification reverts, and the halt
clears the moment the deficit is repaired. No unpause call, no flag to get out of sync.

Where verification runs:

- inside `_unionStake`, which every alpha-pricing view funnels through (`totalStake`,
  `sharePrice`, `previewWrap`, `previewUnwrap` live path) - a quote that ignores
  missing backing would be wrong, so quotes revert too;
- at the start of every state-mutating flow: `wrap`, `unwrap`, `unwrapForTao`,
  `rebalance`. In `wrap` the check MUST run before the mailbox flush: the flush lands
  the user's deposit on a tracked hotkey, and a deposit arriving on the deficient
  hotkey would otherwise mask the deficit within the same transaction.

Views never write. State-mutating flows rewrite checkpoints at the end (below), so a
within-tolerance jitter is absorbed at the next successful mutation.

Out of the guard's scope: `claimTao` and the mailbox reclaim functions (they move
native TAO or pre-wrap mailbox stake and never price shares), and the
dissolved-subnet exit path (dissolution refunds are native TAO; checkpoints are
meaningless there).

### Checkpoint refresh: explicit on every successful mutating path

Checkpoints are rewritten from live post-operation reads of the `_lastSeenHotkeys`
slots - never computed - so the chain's own floor and remainder behavior on the vault's
withdrawals is recorded as-is and can never look like a deficit later.

The refresh is an explicit final step on each path; no path may rely on another
function having done it:

- `wrap` completion (after `_rebalance`),
- `unwrap` live-path completion (after `_deliverAndAlign`) and its zero-backing early
  return,
- `unwrapForTao` completion - this flow sells from the union without consolidating or
  touching `_lastSeenHotkeys`, so it must re-read the slot balances after its sell
  rounds and checkpoint them explicitly,
- `rebalance` completion, including its single-validator and zero-total early returns.

### Recovery (permissionless)

```solidity
function recoverSwappedStake(uint256 tokenId, bytes32 missingHotkey, bytes32 candidateHotkey)
    external nonReentrant;
```

Let `C_m`/`L_m` be the missing slot's checkpoint and live stake, `C_c` the candidate's
checkpoint when it already occupies a tracked slot and zero otherwise, and
`L_c = getStake(candidate, coldkey, netuid)`.

1. `missingHotkey` must occupy a `_lastSeenHotkeys` slot that fails verification
   (otherwise `NoDeficitToRecover`). Recovery evaluates the rule directly, so it keeps
   working in emergency mode, where flow gating no longer does. The deficit is
   `D = C_m - L_m`.
2. The candidate must cover the deficit **from the vault coldkey's stake only**:

   ```
   L_c >= C_c  and  L_c - C_c + TOLERANCE >= D
   ```

   The tolerance slack absorbs share-pool rounding on the moved amount (fact 8). The
   condition must never be evaluated against the candidate hotkey's total stake -
   counting stake the vault does not own would let anyone point at a large validator
   and reopen the exact mispricing this design exists to prevent. A candidate sitting
   below its own checkpoint is itself missing stake: `RecoveryShortfall`.
3. **Recovery is total.** If the missing hotkey still holds anything (`L_m > 0`), the
   clone moves it onto the candidate via same-subnet `moveStake` (no chain minimum,
   fact 7). Nothing is ever left behind on a forgotten hotkey, and nobody can block
   recovery by planting dust on the old hotkey.
4. The missing slot is then retargeted to the candidate; when the candidate already
   holds another slot (merge, fact 3), the missing slot is cleared instead. In both
   cases the candidate's new checkpoint is **`C_c + C_m`** - its previous obligation
   plus the missing slot's, never a reset to its live balance: the untouched
   remainder of the candidate's live excess stays available as cover for other slots
   still in deficit, so two positions merged into one candidate are repaired by two
   calls.
5. Emit `StakeRecovered(tokenId, missingHotkey, candidateHotkey, D)`.

Verification passes once no slot fails, and all flows resume in the same block. The
next state-mutating call rolls the recovered stake onto the current registry set
through the existing `_consolidateRotatedStake` machinery - recovery makes stake
visible and safe; rebalancing stays where it always lived.

**Curing a governance-sweep freeze.** A swept entry has no swap destination, so no
candidate exists naturally. Anyone - typically the owner - stakes the deficit amount
(worth less than whatever nominator minimum triggered the sweep; 0.02 TAO today) on a
fresh hotkey
and `transfer_stake`s it under the vault coldkey (fact 6), then calls
`recoverSwappedStake` with that hotkey. One donation, one call, fully permissionless,
and the swept value itself already came back to holders as claimable TAO.

### Emergency mode (owner, instant, one-way)

```solidity
function enterEmergencyMode(uint256 tokenId) external onlyOwner;
```

For the case no candidate can be produced - which, per the chain facts above, means
subtensor behaved in a way it verifiably cannot today. Per token, irreversible,
effective immediately:

- `wrap` reverts `EmergencyModeActive` forever. Nobody can mint at a written-down
  price, so the cheap-mint attack stays closed.
- Verification is skipped everywhere; `unwrap`, `unwrapForTao`, and all views price
  against live visible backing. Holders exit pro-rata at whatever is really there. No
  separate emergency-exit function is needed - the existing exits are it.
- `recoverSwappedStake` stays callable; folding a stray back in raises everyone's exit
  value.

The owner cannot redirect stake through this switch - stake stays under the vault
clone's coldkey, reachable only by vault logic. What the owner CAN do is time it: see
the trade-offs.

### Errors and events

```solidity
error StakeDeficit(bytes32 hotkey, uint256 expected, uint256 actual);
error NoDeficitToRecover();
error RecoveryShortfall(uint256 available, uint256 required);
error EmergencyModeActive();

event StakeRecovered(uint256 indexed tokenId, bytes32 indexed missingHotkey,
                     bytes32 indexed candidateHotkey, uint256 deficit);
event EmergencyModeEntered(uint256 indexed tokenId);
```

## Trade-offs, in plain English

1. **A hotkey swap halts that subnet's vault until one repair transaction lands.**
   Deposits, exits, and price quotes all revert in the meantime. Swaps are rare, cost
   the validator a chain fee, and the repair is permissionless and bot-friendly - but
   the halt window is real, and integrators calling `previewUnwrap` revert during it.
   That is deliberate: a quote that ignores missing backing would be wrong.
2. **A governance dust sweep also halts the vault, and un-halting it costs somebody
   roughly the swept amount** - below the nominator minimum that triggered the sweep
   (0.02 TAO today). The guard cannot tell a sweep from a swap, so it refuses to
   guess. The cure is a dust-sized donation plus one recovery call; the swept value
   itself already returned to holders as claimable TAO. Rare (requires the chain
   admin raising the nominator minimum), cheap, but it does need a human or bot to
   act.
3. **Losses up to 1,000 RAO of alpha per validator per operation are absorbed
   silently** to keep share-pool rounding jitter from halting the vault. Economically
   nothing.
4. **Emergency mode is instant and trusts the owner.** The owner can flip it while a
   deficit is still recoverable; holders who exit before someone recovers the stray
   realize the written-down price, and a later recovery enriches only those who
   stayed. An owner holding shares could profit from that timing. Accepted: the owner
   already operates the validator registry, the switch cannot move stake anywhere,
   recovery stays open to everyone before and after the flip, and the alternative -
   no escape hatch in a non-upgradeable contract - would brick funds forever on any
   unforeseen chain behavior.
5. **Recovery soundness rests on verified chain behavior** (facts 1-5). If a future
   subtensor upgrade adds a new unsigned way for stake to shrink, the tripwire still
   halts everything - safety degrades to a halt plus emergency exit, never to silent
   mispricing.
6. **A `keep_stake=true` swap is not detected, by design.** Backing and price stay
   correct; the stake merely stops earning until the registry rotates it out and the
   vault consolidates. Forgone yield, never principal.
7. **Gas: +17-37k per state-mutating flow, about $0.07 at current prices** (three
   checkpoint loads, up to three stores, and stake reads where a flow cannot reuse
   ones it already performs - `wrap` guards before the flush, `unwrapForTao`
   re-reads after its sells), on flows that cost 120-490k today. Views add ~8k of
   storage loads and comparisons on ~33k. A token's first wrap pays a one-time ~60k
   for checkpoint initialization. Every figure is a constant: cost does not grow
   with the subnet's validator count.

## Testing

Unit and fuzz (mocked staking precompile, `bound()` over amounts):

- fuzz drops across the `TOLERANCE` boundary: pass at `C - L <= 1000`, `StakeDeficit`
  above, on views and on every mutating flow,
- `wrap` masking: with a deficit on the chosen hotkey and a mailbox deposit large
  enough to cover it, `wrap` must revert `StakeDeficit` - the guard runs before the
  flush,
- recovery: exact cover, cover short by more than `TOLERANCE` reverts, cover short by
  less than `TOLERANCE` passes, candidate already tracked (merge), two deficits
  swapped into one candidate repaired by two calls (checkpoint increments, never
  live-resets), remainder on the missing hotkey is moved into the candidate and the
  union total is conserved, candidate below its own checkpoint reverts, candidate
  equal to missing or zero reverts, condition evaluated against vault-coldkey stake
  only (candidate with large third-party stake and zero vault stake must revert),
- sweep freeze and cure: zero a small tracked entry (mock), assert halt, place the
  deficit on a fresh hotkey, recover, assert resume,
- checkpoint refresh on every successful path: after `wrap`, `unwrap` (including the
  zero-backing early return), `unwrapForTao`, and `rebalance` (including
  single-validator and zero-total early returns), stored checkpoints equal live
  `_lastSeenHotkeys` balances,
- emergency mode: one-way, wrap blocked, exits and views price live backing, recovery
  still works inside it,
- `claimTao` and mailbox reclaims work during a halt,
- invariant: after every successful state-mutating call, stored checkpoints equal the
  live balances of `_lastSeenHotkeys`.

Localnet e2e (mandatory, extends `e2e/` pytest suite against
`~/Projects/subtensor/scripts/localnet.sh`):

1. bootstrap, wrap, record `sharePrice`,
2. operator submits `swap_hotkey(old, new, netuid, keep_stake=false)`,
3. assert `wrap`, `unwrapForTao`, and `previewUnwrap` all revert with `StakeDeficit`,
4. anyone calls `recoverSwappedStake(tokenId, old, new)`; assert `StakeRecovered`,
   `sharePrice` unchanged within a few RAO, and a subsequent wrap and unwrap succeed,
5. `keep_stake=true` variant: assert nothing halts and pricing is unchanged.

The merge-destination recovery (fact 3) and the sweep cure (fact 5) are covered in
unit tests; staging a deregistration or a governance threshold raise on localnet is
not worth the machinery.

## Out of scope

- No automatic swap-following: the vault never guesses where stake went; a human or
  bot proves it.
- No sweep-versus-swap classification: indistinguishable on chain, so the guard halts
  and lets recovery settle it.
- No changes to `ValidatorRegistry`, the mailbox flow, dissolution handling, or the
  claimable-TAO index.
- No subtensor-side changes: everything here works against the chain as deployed.
