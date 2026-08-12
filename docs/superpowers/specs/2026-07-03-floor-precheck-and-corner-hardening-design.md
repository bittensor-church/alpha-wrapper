# Floor Pre-Check and Corner Hardening (fixes for PR #15 review findings)

**Status:** approved design (user delegated the approach choice; Approach A selected).
**Baseline:** branch `pg/fix_unwrap_bug` at commit 690c5be (the PR #15 head).
**Amends:** `docs/superpowers/plans/2026-07-02-roller-consolidation-final.md` design rule 1.

## Context: what the review established (verified against ~/Projects/subtensor, v3.4.9-424-5-g14bc6f9f9)

1. **A chain-rejected precompile call consumes all forwarded gas.** Subtensor maps dispatch
   failures to `PrecompileFailure::Error` (`precompiles/src/extensions.rs:106-118`), and the
   `evm-0.43.4` executor discards the failed frame without refunding its gas
   (`swallow_discard`). Through two 63/64 call frames, `_rebalanceStep`'s `catch` resumes with
   roughly 3% of the gas the transaction had at the `try`. The rationale recorded in design
   rule 1 ("a failed split-optimization loses nothing") is therefore false on cost: each caught
   failure burns ~97% of remaining gas, recurring on every wrap/unwrap while sub-floor drift
   persists, and OOMs outright at the e2e suite's own 1.5M reference limit. Mocks cannot see
   this (Solidity `revert` refunds gas); the e2e scripts never drive a failing move.
2. **The roll's floor guarantee has a hole at the seed.** Same-subnet moves/transfers are
   floor-checked per move with no full-balance exemption. Hops are pile-sized and
   non-decreasing, so the seed (largest reachable slot) is the binding check. When every slot
   is individually sub-floor but the total/request clears the floor, the first hop reverts with
   a raw chain error: in `_deliverAndAlign` (fragmented withdrawal band, untested — the fuzz
   bounds deliberately steer around it) and in `_sweepRotatedStake` (dust-orphan vaults; pinned
   as accepted for `rebalance()` but uncovered for `unwrap()`). Both bands are pigeonhole-bound
   to positions worth under ~0.006-0.012 TAO and `unwrapForTao` remains as the exit.
3. **Price facts.** The oracle quantizes downward in 1e-9 steps (`floor(p*1e9)*1e9`), so the
   vault's valuation never exceeds the chain's. A zero read implies price < 1e-9, where the
   chain's sell price-limit (1e-6) refuses every unstake anyway. Nothing on the alpha rail
   swaps, so the spot price is constant for the duration of a wrap/unwrap/rebalance
   transaction.
4. Smaller confirmed items: `previewUnwrap` performs a duplicated registry read; `unwrapForTao`
   NatSpec promises zero-price full-slot exits the chain contradicts; `_rollStep` NatSpec
   overclaims; five new test names break the two-segment convention and use invented subjects;
   the 16e6 cap and the quantization comment lack one line of rationale each.

## Decision

**Approach A: predictive pre-checks, zero try/catch in AlphaVault.** Rejected alternatives:

- **Gas-capped catch** (`try ... moveStake{gas: CAP}`): CAP is pinned to runtime weights; a
  chain upgrade that raises `move_stake`'s weight past CAP silently disables all rebalancing
  (legitimate moves OOG inside the capped frame and get caught). Still pays CAP per doomed
  attempt; does not fix the raw-error corners.
- **Accept + document**: permanent recurring gas tax (2-4x per affected call, or OOG at sane
  fixed limits) on ordinary users to avoid a small provably-safe fix.

### The invariant that makes pre-checks sound (goes into code comments)

Within one alpha-rail transaction the pool is untouched (moves and transfers are swap-less),
so one `getAlphaPrice` read at entry is exact for every floor decision in that transaction.
The EVM read only rounds down, so `vault floor-check passes => chain accepts` (one-sided).
Consequences:

- A move attempted after a passed pre-check cannot fail the chain's floor. `AmountTooLow` is
  the only expected failure of a registry-attested move, so no catch is needed; anything else
  is exceptional and must revert loudly (matches the strict-revert philosophy already in
  force everywhere else).
- A skipped rebalance move gates no value (share value depends on the total, not the split),
  so design rule 2 ("the oracle never gates value") survives: pre-checks only skip value-free
  optimizations or convert guaranteed chain reverts into typed errors. Zero-price reads fall
  through exactly as today.
- The residual imprecision is the sub-quantum band (< 0.004 TAO absolute): the vault may skip
  or friendly-revert what the chain would accept, never the reverse.

### Amended design rule

Rule 1 becomes: **no try/catch anywhere in AlphaVault.** Consolidation and delivery stay
strict-revert; rebalance moves are pre-checked and bare.

## Changes

### src/AlphaVault.sol

1. **Price threading.** `wrap`, `_redeem`, and `rebalance` read `getAlphaPrice` once at entry
   (`wrap` already does; `_redeem` moves its existing read above the sweep; `rebalance` adds
   one). `_sweepRotatedStake`, `_alignToWeights`, `_rebalanceStep`, and `_deliverAndAlign`
   take `uint256 alphaPriceE18` as a parameter.
2. **`_rebalanceStep`**: replace the try/catch with
   `if (alphaPriceE18 == 0 || _isBelowMinStakeTaoFloor(moveAmt, alphaPriceE18)) return false;`
   then a bare `moveStake`. Correctness note: `moveAmt = min(maxOver, maxUnder)` is maximal
   over candidate pairs, so `return false` cannot skip a different above-floor pair. This
   changes zero-price behavior deliberately: today the move is attempted (and burns gas when
   rejected); a split optimization on a sub-1e-9-price subnet is worthless, so skipping is
   strictly better. Rewrite
   the surrounding comment: state the frozen-price invariant and that rejected precompile
   calls consume all forwarded gas (why attempting doomed moves is the expensive path); delete
   the "do not migrate to the pre-check pattern" guidance it falsifies.
3. **`_sweepRotatedStake`**: when a roll is pending (any rotated-out slot with balance > 0)
   and the price is readable, revert `ConsolidationBelowFloor()` if the roller seed cannot
   clear the floor **even at the next price quantum** (`alphaPriceE18 + 1e9`): the read only
   rounds down, so this rejects exactly what the chain would reject, while the one-quantum
   uncertainty band falls through bare to the chain's full-precision check (the oracle never
   gates value). Zero price keeps today's bare fall-through. `wrap` cannot trip it: the
   flushed deposit seeds the richest slot and already passed the same floor label.
4. **`_deliverAndAlign`**: when gathering is needed (`balances[gatherIndex] < assets`) and the
   price is readable, revert `WithdrawTooSmall()` under the same next-quantum test on the
   gather seed. NatSpec points dust positions at `unwrapForTao`.
5. **New errors** `ConsolidationBelowFloor()` and `MinStakeTaoFloorTooLow()`; `setMinStakeTaoFloor`
   gains a lower bound `MIN_MIN_STAKE_TAO_FLOOR = 2e6` (the chain's floor at deployment) because
   the skip pre-checks are sound only while the vault's floor sits at or above the chain's; a
   chain-side increase the owner lags behind remains a documented operational risk.
6. **`previewUnwrap` / `_totalStake`**: add a `_totalStake(tokenId, netuid, currentSet)`
   overload consuming the set `previewUnwrap` already gets from `_resolveValidators`; the
   2-arg version remains a thin wrapper for `totalStake()` and `unwrapForTao`. The
   `NoValidatorFound` gate stays in `previewUnwrap` (moving it into `_totalStake` would break
   `totalStake()`'s return-0 contract and `unwrapForTao`'s no-gate exit).
7. **NatSpec/comment fixes** (stale docs are bugs):
   - `_rollStep`: hops are pile-sized and non-decreasing, so the seed is the binding floor
     check; callers guarantee the seed (pre-check or deposit seeding) or accept the chain's
     rejection at zero price.
   - `unwrapForTao`: full-balance sells are exempt from the chain's amount floor only; the
     chain can still refuse when the pool cannot absorb the sell (drained liquidity, price
     below the chain's sell limit). The vault adds no gate of its own.
   - `_isBelowMinStakeTaoFloor`: the downward quantum means up to 2x relative under-read at
     prices just under 2e-9; always under 0.004 TAO absolute.
   - `MAX_MIN_STAKE_TAO_FLOOR`: 8x headroom over the chain's 2e6 default; small enough that
     misconfiguration can only ever mislabel dust.
   - Architecture paragraph: rebalance is best-effort via pre-check (not catch).

### Tests

1. **Renames** (restore `test_<Scenario>_<Outcome>`, real subjects):
   - `WithdrawForTaoTest` -> `UnwrapForTaoTest` (matches file `UnwrapForTao.t.sol`).
   - `test_ProcessDeposit_*` -> `test_Wrap_*`; `test_Withdraw_*` -> `test_Unwrap_*`
     (`test_Withdraw_TailWaitsWhenPriceReadsZero` -> `test_UnwrapForTao_...` — it calls
     `unwrapForTao`); collapse the five 3-segment names to two segments, e.g.
     `test_Wrap_RevertsDepositTooSmallBelowTaoFloor`,
     `test_Unwrap_RevertsWithdrawTooSmallWhenRequestBelowFloor`,
     `test_RevertWhen_AllSellsFail`, `test_RevertWhen_OneFullSliceSellFails`.
   - `testFuzz_Withdraw_DeliversExactlyPreview` -> `testFuzz_Unwrap_DeliversExactlyPreview`.
2. **MockStaking faithfulness knob**: opt-in `setConsumeAllGasOnFailure(bool)` switching
   failure paths to `assembly { invalid() }` (models `PrecompileFailure::Error`). Default off
   so existing `expectRevert(reason)` tests are untouched.
3. **New unit tests**:
   - Gas-budget regression: sub-floor rebalance residue, consume-all-gas mode on, call
     `wrap{gas: 1_500_000}` — succeeds with no `Rebalanced` event (fails OOG if anyone
     reintroduces attempt-and-catch).
   - Fragmented band: three slots individually sub-floor, request above floor ->
     `WithdrawTooSmall` (the band all current fuzz bounds avoid).
   - Dust-only vault: `unwrap()` -> `ConsolidationBelowFloor` (the corner was pinned only for
     `rebalance()`); update `test_RevertWhen_ConsolidatingDustOnlyVault` to expect
     `ConsolidationBelowFloor` (readable price) and add a price-reads-zero variant expecting
     the raw mock error (bare fall-through still covered).
   - Rebalance skip: existing `test_RebalanceSkipsMoveBelowMinStakeTaoFloor` must stay green
     with unchanged assertions (skip now happens pre-call).
4. **e2e** (`scripts/localnet-e2e-min-stake-floor.sh` + `e2e_lib.sh` helper if needed):
   new phase — two-validator 50/50 set, deposit with tao value in [floor, 2x floor), `wrap`
   at the standard fixed gas limit; assert success, `gasUsed` under a bound derived from
   Phase 6's healthy first-wrap baseline (+25%), and the split left drifted; then a larger
   deposit and assert the drift clears. `vault_send` records `VAULT_SEND_GAS_USED`, with a
   parse failure setting a high sentinel so the budget assertion fails loudly rather than
   passing vacuously. Pre-fix this phase fails OOG, which is the regression proof the suite
   was missing. The phase has not yet run against a live localnet.

### Explicit non-goals

- `unwrapForTao` loop semantics (full sells bare, partial pre-checked with fresh price, zero
  read skips the tail) — unchanged, per design rule 4.
- The roller architecture, atomic sweep + refresh-after-clean-roll, `minStakeTaoFloor` knob,
  cap value, and the owner-mirror design (the chain floor is a runtime constant; not readable
  on-chain) — unchanged.
- No `git commit` — the user commits.

## Acceptance criteria

1. `grep -cw "try" src/AlphaVault.sol` returns 0; every skip/floor decision is a pre-call
   check; all stake-moving calls are bare.
2. Frozen-price invariant documented once (at `_isBelowMinStakeTaoFloor` or the price-threading
   site) and referenced where relied upon.
3. New typed errors fire in the two seed corners at readable price; zero-price behavior at
   the seed corners is today's bare fall-through; zero-price rebalance moves are skipped.
4. `previewUnwrap` makes exactly one registry call.
5. Test names: no 3+ segment names, no `Withdraw`/`ProcessDeposit` subjects; contract/file
   names agree.
6. New unit tests + e2e phase pass; `forge fmt --check`, `forge build` (zero warnings),
   `forge test`, `forge snapshot --check --tolerance 1`, coverage reported; code-review and
   security-audit skills run on the final diff. Snapshots must be regenerated under
   `FOUNDRY_PROFILE=ci` and AFTER any coverage run — `forge coverage`'s instrumented run
   rewrites `snapshots/AlphaVault.json` with inflated values.
