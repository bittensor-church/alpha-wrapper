# Dynamic validator set (1..64) — continuation handoff

State as of 2026-08-12 on branch `pg/dynamic-validator-set`. Design and
rationale live in `docs/superpowers/specs/2026-08-12-dynamic-validator-set-design.md`;
this file covers only what a fresh session needs to resume.

## Current state

Commits: `f01c7fd` (refactor), `7339082` (drain fixes). Branched from `main` @ `c6533a5`.

- `forge build` — clean.
- `forge fmt` — applied.
- `forge test` — **340 passed, 12 failed, 352 total.**
- `forge coverage` — not run.

Reproduce the failures with `forge test`; they are deterministic apart from the
one fuzz case noted below.

## What the change does

`ValidatorRegistry` stores a dynamic 1..64 validator set per subnet instead of a
fixed 3, and `AlphaVault` stakes across all of it. **Three validators remains the
expected set size** — 64 is the ceiling the contract must survive, not the case
to tune for.

Landed:

- Registry: `MAX_VALIDATORS = 64`, dynamic `bytes32[]`/`uint16[]`, `delete`+push
  commit, `getValidators` returns `(hotkeys, weights, version)`. The version is
  `nonces[netuid]`, which was already monotonic per commit — no new storage.
- Vault: batched balance reads chunked at the chain's 64-per-call bound; a
  set-version fast path that skips all history reads when membership has not
  moved; `_drainRotatedSlots` as a move class distinct from alignment; unified
  target-zero alignment; union reads on views and on `unwrapForTao`.

## Failing tests, triaged

**Mechanical (8).** Stale expectations, no design question.

- Array out-of-bounds (`0x32`) — tests index `[1]`/`[2]` on now-dynamic arrays:
  `test_RebalanceNoOpWhenCloneNotDeployed`, `test_RebalanceRecycledSubnetSilentNoop`,
  `test_Rebalance_ConsolidatesMultipleRotatedOutSlots`,
  `test_Update_FirstAttestationWithNonceWinsRace`,
  `test_Update_NetuidsHaveIndependentState`, `test_Update_PersistsTwoValidators`,
  `test_Update_ZeroesTrailingSlotsAfterShrink`.
- `test_RevertWhen_UpdateTooManyHotkeys` — still asserts the old cap of 3; the
  cap is now 64, so the test needs 65 hotkeys.

`test_Update_ZeroesTrailingSlotsAfterShrink` should be rewritten rather than
patched: the trailing-zero sentinel it tests no longer exists, and the property
worth keeping is that a 64 -> 3 shrink returns a length-3 array with no stale
tail.

**Deliberate behaviour changes (3).** These fail because the contract changed on
purpose. Rewrite once the open question below is answered.

- `test_RevertWhen_ConsolidatingDustOnlyVault` — no longer reverts.
- `test_RevertWhen_UnwrappingDustOnlyVault` — now `WithdrawTooSmall()` instead of
  `ConsolidationBelowFloor()`.
- `test_RotationSweptOnRebalance` — expects 1 `Rebalanced` event, sees 0, because
  the drain now completes the work that alignment used to finish.

**Needs investigation (1).**

- `testFuzz_Rebalance_ConsolidationMatchesChainFloor` — leaves 3 RAO of
  rotated-out stake. Probably wants a rounding tolerance, since the chain credits
  moves a RAO short, but this is unconfirmed. Do not add a tolerance without
  first confirming the residue is bounded by hop count rather than growing.

## Open question — answer before rewriting the dust tests

Dust-only positions used to revert `ConsolidationBelowFloor` and route the holder
to `unwrapForTao`. They now succeed, leaving the dust in place and tracked.

Leave-behind looks right at 64: reverting lets a few RAO of unmovable dust block
every withdrawal from the position, and the residue stays inside the reported
backing either way (the remembered set keeps it, and views read the union). But
it is a real behaviour change and the call is the repo owner's. The three
deliberate-change tests above encode whichever answer is chosen.

## Remaining work

1. Fix the 8 mechanical tests.
2. Resolve the dust question, rewrite the 3 behaviour tests.
3. Investigate the fuzz residue.
4. New tests: 1-validator and 64-validator happy paths; 64 -> 3 shrink and
   3 -> 64 grow with no stale tail; partial rotation where the dropped balance
   sits in `[floor, 64 x floor)` — the case that broke the first drain design;
   a `>64` union forcing two batched reads, with a hotkey present in both chunks
   to pin cross-chunk dedup; `unwrapForTao` exiting a fully-rotated, undrained
   position; zero-price rotation.
5. Fuzz: `testFuzz_UpdateValidators(seed, count)` with `count = bound(count, 1, 64)`;
   `testFuzz_SequentialCommits(lenA, lenB)` for shrink/grow soundness;
   `testFuzz_WrapUnwrapRoundTrip` across set sizes;
   `testFuzz_RotationPreservesTotal(fromCount, toCount)`.
6. Gas snapshot: add `wrap`, `unwrap`, and `previewUnwrap` at **both 3 and 64**
   validators to `snapshots/AlphaVault.json`. Keep the existing 3-validator
   entries so a regression at the common size stays visible in CI. Regenerate
   with the CLI `--threads 4` on forge v1.7.0, never from a `forge coverage` run.
7. `forge coverage`, `/simplify`, re-review, push, open PR.

## Review findings not yet acted on

- `updateValidatorsBatch` costs ~1.36M per full 64-validator commit, so a batch
  approaches the 75M block limit near ~50 subnets. Document a batch-size bound.
- ABI break: `getCurrentValidators` and `lastSeenHotkeys` changed from
  `bytes32[3]` to `bytes32[]`, and `IValidatorRegistry.getValidators` gained a
  third return value. The tao20 contract consumes vault views and must be
  checked.
- Weights of 1 bps are legal. At 64 validators a 1-bps slot needs a position of
  roughly 10,000 x floor before any stake can land on it, so the spread is
  silently unmet on small vaults. Either enforce a minimum weight or document
  the acceptance.
- No e2e/localnet item exists for `getStakeInfoForColdkeyAndNetuid`. Its
  parameter order is `(coldkey, netuid, hotkeys)` — this project has previously
  shipped a precompile parameter-order bug that unit tests could not catch,
  because a faithful mock passes while the chain reverts.
- `invariant_SharePriceMonotonic` as specified will be flaky: the chain credits
  moves a RAO short, so rotations legitimately drop share price by dust. It needs
  a tolerance.

## Facts worth not re-deriving

- Gas per db read is **625** (`RocksDbWeight` 25,000,000 ref_time / `WeightPerGas`
  40,000). The mainnet-measured 4,952 for `getStake` is 7 x 625 = 4,375 of reads
  plus ~577 fixed per-call overhead. Dividing 4,952 by 7 to get "707 per read"
  is wrong and inflates every estimate.
- `getStakeInfoForColdkeyAndNetuid` caps input at 64, reverts on a duplicate
  hotkey, omits zero-stake hotkeys, and preserves input order. All four are
  mirrored in `MockStaking`; the vault's index mapping depends on the last two.
- `getTotalColdkeyStakeOnSubnet` is TAO-denominated via `sim_swap` and therefore
  unusable for share pricing. Do not revisit it.
- A drain must move a dropped validator's **whole balance**. Capping it at the
  receiving slot's deficit — which is what folding it into `_rebalanceStep`
  does — strands stake many times the floor on a routine 64 -> 63 shrink.
- The on-weight invariant holds only at the boundary of a vault call. The
  registry commits outside the vault, so views must read the union or they report
  zero backing for a freshly rotated set.
