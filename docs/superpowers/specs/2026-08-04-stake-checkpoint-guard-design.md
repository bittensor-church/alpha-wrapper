# Stake Checkpoint Guard

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
- `unwrap` pays exiting holders a fraction of what their shares are worth.

The stake is not lost - it sits under the vault clone's coldkey on a hotkey the vault
does not know about - but every flow misprices until the vault finds it.

## Chain facts this design rests on

Verified in subtensor source (`~/Projects/subtensor`, main @ 2026-08-04) and against
live mainnet (spec 440):

1. **Nobody but the vault's coldkey can reduce a (hotkey, vault-coldkey) stake entry**,
   with exactly three exceptions: a hotkey swap by the validator operator, subnet
   dissolution (already gated by `isSubnetDissolving`), and a governance dust sweep
   (below). Emissions only ever increase the entry. Verified by enumerating every
   caller of the stake-reduction paths (`staking/remove_stake.rs`,
   `staking/helpers.rs:228-283`, `coinbase/block_step.rs`).
2. **A hotkey swap moves the entire per-subnet stake, always** - partial drops from
   swaps are impossible (`swap/swap_hotkey.rs`). The moved stake always lands on a
   hotkey that is readable via `getStake(newHotkey, ourColdkey, netuid)`.
3. **A swap may merge into a hotkey the vault already tracks.** The destination may be
   an existing hotkey account when the same operator coldkey owns both and the
   destination is not currently registered on the subnet (`swap_hotkey.rs:96-146`).
   Since stake survives deregistration, a deregistered-but-still-staked tracked hotkey
   is a legal merge destination. Recovery must therefore accept a candidate the vault
   already tracks, not only unknown hotkeys.
4. **The `keep_stake=true` swap variant leaves stake on the old hotkey.** Nothing drops,
   pricing stays correct; the stake just stops earning until rotated. No action needed.
5. **The only unsigned reduction is a governance dust sweep**: when the chain admin
   raises the nominator minimum (currently 0.02 TAO), a global batch force-sells any
   stake entry whose spot value is below that minimum. The sale is all-or-nothing (the
   entry zeroes) and its TAO proceeds, minus the chain's swap fee, arrive on the vault
   clone as native balance - which the existing claimable-TAO index already captures
   for holders.
6. **Read-path rounding**: stake values are computed from share-pool fixed-point math,
   so a passive entry's readable value can jitter downward by a few RAO when other
   nominators move in or out of the same pool.

## Design

Three pieces: a checkpoint per tracked validator, a verification rule that halts on an
unexplained drop, and a permissionless repair function. Plus a one-way owner escape
hatch for the unrecoverable case.

### Storage

```solidity
/// Alpha the vault held on each _lastSeenHotkeys slot after the last state-mutating call.
mapping(uint256 tokenId => uint256[3]) private _stakeCheckpoints;

/// One-way per-token switch: exits continue against live backing, deposits stop forever.
mapping(uint256 tokenId => bool) public emergencyMode;
```

Checkpoints are slot-aligned with `_lastSeenHotkeys[tokenId]`. Every state-mutating
flow (`wrap`, `unwrap`, `unwrapForTao`, `rebalance`) already ends with the backing
consolidated onto the current validator set and `_lastSeenHotkeys` updated; it now also
stores the freshly read balances of those slots as checkpoints. Because checkpoints are
re-read from chain after the flow's own staking calls, the vault's own floor and sweep
effects on its remainders are recorded automatically and can never look like a deficit.

### Verification

At the start of every state-mutating flow and inside every alpha-pricing view
(`totalStake`, `sharePrice`, `previewWrap`, `previewUnwrap` live path - all of which
funnel through `_unionStake`, which is the single verification point), each tracked
slot with hotkey `H`, checkpoint `C`, and live stake `L = getStake(H, coldkey, netuid)`
is classified:

| Case | Meaning | Action |
|---|---|---|
| `L + TOLERANCE >= C` | emissions, or share-pool rounding jitter | pass |
| `L == 0` and `C` spot-valued below `2 * getNominatorMinRequiredStake()` | governance dust sweep; proceeds already back as claimable TAO | pass |
| anything else | hotkey swap (or unknown chain behavior) | revert `StakeDeficit(H, C, L)` |

`TOLERANCE` is a constant 1,000 RAO of alpha per slot - three orders of magnitude above
observed rounding jitter, three orders below economic relevance. The sweep test
converts `C` to TAO at the current `getAlphaPrice`; the 2x slack absorbs price movement
between the sweep and its detection. Both chain minima are read live from the staking
precompile, not hardcoded.

There is no stored pause flag. "Halted" simply means verification reverts, and the halt
clears the moment the deficit is repaired. No unpause call, no flag to get out of sync.

Views never write; a within-tolerance or swept slot is simply treated as passing, and
the next state-mutating flow rewrites checkpoints from live reads anyway.

`claimTao` and the mailbox reclaim functions stay outside the guard: they move native
TAO or pre-wrap mailbox stake and never price shares. The dissolved-subnet exit path
also stays outside: dissolution refunds are native TAO, checkpoints are meaningless
there.

### Recovery (permissionless)

```solidity
function recoverSwappedStake(uint256 tokenId, bytes32 missingHotkey, bytes32 candidateHotkey)
    external nonReentrant;
```

Requirements, checked against live chain reads:

1. `missingHotkey` occupies a `_lastSeenHotkeys` slot that fails the classification
   table above (otherwise `NoDeficitToRecover`). Recovery evaluates the table
   directly, so it keeps working in emergency mode, where flow gating no longer
   does.
2. The candidate covers the deficit **from our coldkey's stake only**:

   ```
   getStake(candidate, coldkey, netuid) - checkpointOf(candidate) >= C_missing - L_missing
   ```

   where `checkpointOf(candidate)` is the candidate's own checkpoint when it already
   occupies a tracked slot (the merge case, chain fact 3) and zero otherwise. A
   candidate sitting below its own checkpoint is itself missing stake and reverts
   `RecoveryShortfall`. The
   condition must never be evaluated against the candidate hotkey's total stake -
   counting stake the vault does not own would let anyone point at a large validator
   and reopen the mispricing this design exists to prevent.

Effect: the missing slot is retargeted to the candidate (or cleared, when the candidate
already holds another slot), the candidate's checkpoint is refreshed to its live
balance, and `StakeRecovered(tokenId, missingHotkey, candidateHotkey, deficit)` is
emitted. Verification now passes, so all flows resume immediately. The next
state-mutating call rolls the recovered stake onto the current registry set through the
existing `_consolidateRotatedStake` machinery - recovery only makes the stake visible;
it does not move it.

Two simultaneous swaps mean two failing slots and two recovery calls; flows resume when
no slot fails. Because folding in stake under our own coldkey can only increase visible
backing, a wrong-but-condition-satisfying candidate (e.g. a third party gifted stake
via `transfer_stake`) is safe: backing rises, and the genuinely moved stake remains
recoverable the same way whenever a slot is in deficit, or claimable through emergency
mode otherwise.

### Emergency mode (owner, one-way)

```solidity
function enterEmergencyMode(uint256 tokenId) external onlyOwner;
```

For the case no valid candidate exists - which, per the chain facts above, means
subtensor behaved in a way it verifiably cannot today. Per token, irreversible:

- `wrap` reverts `EmergencyModeActive` forever. Nobody can mint at a written-down
  price, so the cheap-mint attack stays closed.
- Verification is skipped everywhere; `unwrap`, `unwrapForTao`, and all views price
  against live visible backing. Holders exit pro-rata at whatever is really there.
  No separate emergency-exit function is needed - the existing exits are it.
- `recoverSwappedStake` stays callable; folding a stray back in raises everyone's
  exit value.

The owner cannot steal through this switch: stake stays under the vault clone's
coldkey, reachable only by vault logic. A wrong flip strands upside (holders exit at
the written-down price), nothing more.

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
   the halt window is real and integrators calling `previewUnwrap` revert during it.
   That is deliberate: a quote that ignores missing backing would be wrong.
2. **Small losses are absorbed silently instead of halting.** Up to 1,000 RAO of alpha
   per validator per operation (rounding jitter), and a governance dust sweep of an
   entry worth under about twice the 0.02 TAO nominator minimum - whose sale proceeds
   come back to holders as claimable TAO minus the chain's swap fee. Both are
   economically negligible and bounded.
3. **Emergency mode trusts the owner with liveness, not with funds.** A wrong flip
   permanently disables deposits for that token and lets holders exit at the
   written-down live backing; it cannot redirect stake anywhere.
4. **Recovery soundness rests on verified chain behavior** (facts 1-5 above). If a
   future subtensor upgrade adds a new unsigned way for stake to shrink, the tripwire
   still halts everything - safety degrades to a halt plus emergency exit, never to
   silent mispricing.
5. **A `keep_stake=true` swap is not detected, by design.** Backing and price stay
   correct; the stake merely stops earning until the registry rotates it out and the
   vault consolidates. Forgone yield, never principal.
6. **Gas: roughly +15-30k per wrap/unwrap** (three checkpoint loads, up to three
   stores, and stake reads where a flow does not already perform them), on flows that
   cost several hundred thousand today. Views gain only warm storage loads and
   comparisons.

## Testing

Unit and fuzz (mocked staking precompile, `bound()` over amounts):

- fuzz drops across the `TOLERANCE` boundary: pass at `C - L <= 1000`, `StakeDeficit`
  above,
- fuzz the sweep-forgiveness predicate across stake size and alpha price, including
  the zeroed-entry-just-above-threshold case that must halt,
- recovery: exact cover, shortfall reverts, candidate already tracked (merge case),
  candidate equals missing reverts, two simultaneous deficits need two calls,
  recovery against our-coldkey stake only (candidate with large third-party stake and
  zero vault stake must revert),
- emergency mode: one-way, wrap blocked, exits and views price live, recovery still
  works,
- every alpha-pricing view reverts while a slot is in deficit; `claimTao` and mailbox
  reclaims still work during a halt,
- invariant: after every successful state-mutating call, stored checkpoints equal the
  live balances of `_lastSeenHotkeys`.

Localnet e2e (mandatory, extends `e2e/` pytest suite against
`~/Projects/subtensor/scripts/localnet.sh`):

1. bootstrap, wrap, record `sharePrice`,
2. operator submits `swap_hotkey(old, new, netuid, keep_stake=false)`,
3. assert `wrap`, `unwrapForTao`, and `previewUnwrap` revert with `StakeDeficit`,
4. anyone calls `recoverSwappedStake(tokenId, old, new)`; assert `StakeRecovered`,
   `sharePrice` unchanged within a few RAO, and a subsequent wrap and unwrap succeed,
5. `keep_stake=true` variant: assert nothing halts and pricing is unchanged.

The merge-destination recovery (chain fact 3) is covered in unit tests; staging a
deregistration on localnet is not worth the machinery.

## Out of scope

- No automatic swap-following: the vault never guesses where stake went; a human or
  bot proves it.
- No changes to `ValidatorRegistry`, the mailbox flow, dissolution handling, or the
  claimable-TAO index.
- No subtensor-side changes: everything here works against the chain as deployed.
