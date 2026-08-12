# Backing Tripwire Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Implementer profile:** tasks are sized for Opus 5 at xhigh reasoning effort. Reviews run on Fable. Read the spec first: `docs/superpowers/specs/2026-08-03-backing-tripwire-design.md`.

**Goal:** Make hotkey swaps unable to misprice the vault: a stored per-token high-water mark (`accountedAlpha`) halts every mutating operation and pricing view when the tracked-set total falls below it; a permissionless raise-only `checkpointBacking` keeps the mark fresh so emission growth cannot conceal a substitution beyond a stated, operationally chosen bound; a permissionless move-only `recoverStray` brings re-keyed stake home; and a delayed two-step `proposeBackingLoss`/`acceptBackingLoss` re-anchors after genuine losses only when nobody could cure the shortfall for 72 public hours. Ships with two corrections: a dedicated move floor mirroring the chain's 100k RAO transfer minimum, and exact-or-revert alpha delivery with a per-transfer-leg rounding allowance.

**Architecture:** The vault's existing read model is unchanged — tracked set = `_lastSeenHotkeys` ∪ attested, read via the existing `_unionStake`. Mutating ops check `tracked total >= accountedAlpha[tokenId]` at entry (for `wrap`: before the mailbox flush) and store a freshly re-read tracked total at exit. `accountedAlpha` has exactly three writers — the end-of-op re-baseline, the raise-only `checkpointBacking`, and the delayed `acceptBackingLoss` — all writing freshly read totals, never caller-supplied deltas. No storage is removed; consolidation and tracking keep their current shape.

**Tech Stack:** Solidity ^0.8.20, Foundry (forge 1.7.0), OpenZeppelin, subtensor precompiles (staking V2 `0x…0805`, alpha, subnet, address-mapping). Runtime compatibility pinned to spec v440 semantics.

## Global Constraints

- **Never run `git commit`** — the user commits. Leave changes in the working tree.
- No TDD: implement first, then add focused, non-redundant tests in the same task.
- Zero compiler warnings; `forge fmt` before finishing every task. The pre-existing baseline has 11 unsafe-typecast lint warnings in test files — Task 7 clears them at root cause; any that genuinely needs a lint-disable must be surfaced to the user first, never silently suppressed.
- No non-ASCII characters in any source file.
- Comments: only non-obvious "why"; present-tense invariants; never reference old code, the conversation, or review findings; never name chain-internal identifiers (say "the chain's transfer minimum", never the storage/constant name).
- File headers: plain-language, readable by non-technical people.
- Naming: no abbreviated identifiers; tests are `test_<Scenario>_<Outcome>` (exactly two segments, subject = behavior of the call under test); fuzz `testFuzz_...`; invariant `invariant_...`.
- Fuzz: prefer `bound(x, min, max)` over `vm.assume`.
- Event assertions via `vm.expectEmit` with the specific expected event, never recorded-logs decoding.
- Every vault-side floor pre-check must be traced to the exact v440 chain-side check it mirrors (move/transfer → the 100k transfer minimum, whole-position moves included; unstake sizing → the staking floor family; full drains exempt on unstakes only). Cite the subtensor file:line in the PR description, not in code comments.
- Gas snapshot: regenerate with `forge snapshot --threads 4` (forge 1.7.0); run it **after** `forge coverage` (coverage poisons `snapshots/AlphaVault.json`).
- Size gate: `forge build --sizes` at the end of every task; `AlphaVault` stays under 24,576 bytes with at least 500 bytes of margin (current baseline: 22,293).

---

### Task 1: Move-floor split

**Files:**
- Modify: `src/AlphaVault.sol`
- Test: `test/MinStakeTaoFloor.t.sol` and any other floor-calibrated suites (grep)

**Interfaces:**
- Produces: `uint256 public minMoveTaoFloor` (init `100_000`), `setMinMoveTaoFloor` (owner, capped at `MOVE_FLOOR_CAP = 10_000_000`, `MinMoveTaoFloorTooHigh`), `event MinMoveTaoFloorUpdated(uint256 oldValue, uint256 newValue)`, `_isBelowMoveFloorAtReadPrice` / `_isBelowMoveFloorAtAnyPrice`.

- [ ] **Step 1: Storage + admin + helpers.** Mirror the existing `minStakeTaoFloor` pattern (storage, setter with cap and event, floor-check helpers parameterized on the move floor).

- [ ] **Step 2: Re-point call sites.** Audit every `_isBelowFloorAtReadPrice` / `_isBelowFloorAtAnyPrice` call and re-point moves/transfers to the move floor: the deposit flush gate (`DepositTooSmall` — the flush is a same-subnet transfer), consolidation-roll checks (`ConsolidationBelowFloor`), gather (`GatherBelowFloor`), rebalance-step skip, and the live-unwrap delivery gate (`WithdrawTooSmall` — delivery is a same-subnet transfer). Unstake sizing in `unwrapForTao` / `_sellableChunk` keeps `minStakeTaoFloor`. Record the call-site → chain-check mapping in the PR description.

- [ ] **Step 3: Recalibrate floor-boundary tests.** Existing tests encode a 2e6 move floor (e.g. gather/consolidation boundary cases in `test/MinStakeTaoFloor.t.sol`); retune move-path boundaries to 100k, keep unstake-sizing boundaries at 2e6, and add `test_SetMinMoveTaoFloor_RevertsAboveCap`, `test_Wrap_AcceptsDepositBetweenMoveAndStakeFloors`.

- [ ] **Step 4: Full suite + size + format.** `forge build && forge test && forge build --sizes && forge fmt`

---

### Task 2: Chain-faithful mocks

**Files:**
- Modify: `test/mocks/MockStaking.sol`, `test/AlphaVaultTestBase.sol`

**Interfaces (used by Tasks 3-6):**
- `MockStaking.setHotkeyExists(bytes32, bool)`; `moveStake`/`transferStake` revert `"HotKeyAccountNotExists"` when either endpoint lacks its owner-record flag; `removeStake` reverts when the source lacks it. New hotkeys default to existing when first staked.
- `MockStaking` move floor: same-subnet moves/transfers revert `"AmountTooLow"` below a 100_000 RAO tao value at the mock price, **whole-position moves included**; full-drain `removeStake` exempt from sizing floors.
- `MockStaking.rekeyPositions(bytes32 oldHotkey, bytes32 newHotkey, uint16 netuid)`.
- `MockStaking.setTransferCreditShave(uint256 rao)` — every subsequent move/transfer credits the destination short by `rao` (models rounded share-pool credits per leg).
- `MockStaking.shaveStake(bytes32 hotkey, bytes32 coldkey, uint16 netuid, uint256 rao)` — read-side dip helper.
- `MockStaking.accrueEmission(bytes32 hotkey, uint16 netuid, uint256 rao)` — grows every coldkey position under the hotkey pro-rata (models emission between operations).
- Test-base helpers:
  - `swapHotkeyFull(bytes32 oldHotkey, bytes32 newHotkey, uint16 netuid, bool keepStake)` — rekey iff `!keepStake`; **old hotkey's owner-record flag cleared always** (all-subnets mode).
  - `swapHotkeyOneSubnet(bytes32 oldHotkey, bytes32 newHotkey, uint16 netuid, bool keepStake)` — rekey iff `!keepStake`; old hotkey keeps its flag.
  - `associateHotkey(bytes32 hotkey)` — restores the owner-record flag (models the chain's permissionless association).
  - `pruneNeuron(...)` — a no-op on stake and flags (asserts the design's registration independence in tests that use it).
  - `donateStake(bytes32 hotkey, bytes32 coldkey, uint16 netuid, uint256 amount)`.
  - `raiseNominatorThreshold(uint256 newValue, bool deleteBranch)` — force-converts sub-threshold non-owner nominations (TAO to the staker's account) or deletes the alpha when `deleteBranch`.

- [ ] **Step 1: MockStaking existence, floors, rekey, shaves, emission.** Follow the existing storage layout (read it first). The owner-record flag, the no-exemption move floor, and the four-mode swap asymmetry are the load-bearing fidelity — they are the chain behaviors the tripwire and recovery rest on (spec facts 2-4, 6).

- [ ] **Step 2: Test-base wiring + mock-semantics tests** (new `test/BackingTripwire.t.sol`): `test_MockMove_RevertsForMissingHotkey`, `test_MockMove_RevertsBelowTransferMinimum` (including a whole-position sub-floor move), `test_MockSwapFull_ClearsOldOwnerFlag`, `test_MockSwapOneSubnet_KeepsOldOwnerFlag`, `test_MockAssociate_RestoresOwnerFlag`, `test_MockTransfer_CreditsShortWhenShaveSet`, `test_MockEmission_GrowsPositionsProRata`.

- [ ] **Step 3: Targeted tests + size + format.** `forge build && forge test --match-path "test/BackingTripwire.t.sol" -v && forge build --sizes && forge fmt`

---

### Task 3: Tripwire core + checkpoint

**Files:**
- Modify: `src/AlphaVault.sol`
- Test: `test/BackingTripwire.t.sol`

**Interfaces:**
- Produces: `mapping(uint256 => uint256) public accountedAlpha;`, `error BackingShort(uint256 accounted, uint256 tracked);`, `_checkBacking(uint256 tokenId, uint256 trackedTotal) private view`, `_recordAccountedAlpha(uint256 tokenId, uint16 netuid, address clone) private` (re-reads the tracked union, stores the total), `checkpointBacking(uint256 netuid) external` (raise-only, blackout-guarded, emits `BackingCheckpointed(tokenId, previous, new)` on a raise, no-op otherwise), `trackedBacking(uint256 netuid) external view returns (uint256)`.
- **The only three writers of `accountedAlpha` in the codebase are `_recordAccountedAlpha`, `checkpointBacking` (raise-only), and `acceptBackingLoss` (Task 4), all from freshly read tracked totals.**

- [ ] **Step 1: Storage, error, helpers.** `_recordAccountedAlpha` wraps a `_unionStake` read; `trackedBacking` returns 0 without a clone, else the raw union total for `currentTokenId(netuid)`; `checkpointBacking` computes the union and stores `max(current mark, total)`.

- [ ] **Step 2: Wire the four ops.** After each op's existing guards, compute the tracked union total and `_checkBacking` — in `wrap`, strictly **before** the mailbox flush, so a deposit can never mask a shortfall; `unwrapForTao` already computes the union — reuse it. End every op (all exit paths that mutated stake or shares) with `_recordAccountedAlpha`. Dissolved/dissolving paths are untouched: no check, no write.

- [ ] **Step 3: Wire the views.** `sharePrice`, `previewWrap`, `previewUnwrap`: after their existing guards, `_checkBacking` against a fresh union read before quoting. `totalStake` stays a raw reporter.

- [ ] **Step 4: Tests.**
- `test_Wrap_RevertsWhenTrackedBackingShort` (full-swap `keepStake=false` between ops → `BackingShort`, expect both error args)
- `test_Wrap_ChecksBackingBeforeFlush` (shortfall equal to the pending deposit still trips)
- `test_Unwrap_RevertsWhenTrackedBackingShort` / `test_Rebalance_RevertsWhenTrackedBackingShort` / `test_UnwrapForTao_RevertsWhenTrackedBackingShort` / `test_SharePrice_RevertsWhenTrackedBackingShort`
- `test_AccountedAlpha_TracksOpEndTotal` (grows with deposits, shrinks with exits)
- `test_CheckpointBacking_RaisesToTrackedTotal` (emission via `accrueEmission`, checkpoint, expectEmit both values)
- `test_CheckpointBacking_NeverLowersTheMark` (no-op below the mark; storage assert)
- `test_CheckpointBacking_RevertsDuringDissolution`
- `test_Wrap_RevertsAfterCheckpointedGrowthThenSwap` — the masking regression: `accrueEmission` by X, `checkpointBacking`, swap a position of value ≤ X away → next wrap trips. A sibling test asserts the documented bound: the same sequence **without** the checkpoint does not trip (pinning spec §4's window statement rather than pretending otherwise).
- `test_Wrap_SucceedsThroughStakeKeepingSwap` (one-subnet `keepStake=true`: no trip)
- `test_Rebalance_SucceedsAfterPrune` (prune is a non-event)
- `test_TrackedBacking_MatchesUnionTotal`
- `test_DonationCure_LiftsBackingShort` (read-shave micro-dip → donation under an attested hotkey unfreezes without privileged calls)

- [ ] **Step 5: Full suite + size + format.**

---

### Task 4: recoverStray + delayed loss acceptance

**Files:**
- Modify: `src/AlphaVault.sol`
- Test: `test/RecoverStray.t.sol` (create)

**Interfaces:**
- Produces: `recoverStray(uint256 netuid, bytes32 strayHotkey, uint256 targetSlot) external nonReentrant` (move-only, never writes `accountedAlpha`, no tripwire), `proposeBackingLoss(uint256 tokenId) external onlyOwner`, `acceptBackingLoss(uint256 tokenId) external onlyOwner`, `mapping(uint256 => uint256) public backingLossProposedAt`, `uint256 public constant LOSS_ACCEPTANCE_DELAY = 72 hours`, events `StrayStakeRecovered(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 alpha)`, `BackingLossProposed(uint256 indexed tokenId, uint256 accounted, uint256 tracked)`, `BackingLossAccepted(uint256 indexed tokenId, uint256 previousAccounted, uint256 newAccounted)`, errors `HotkeyNotStray()`, `InvalidTargetSlot()`, `NoBackingShortfall()`, `NoPendingBackingLoss()`, `LossAcceptanceDelayNotMet()`.

- [ ] **Step 1: Implement per spec §5-§6.** `recoverStray`: guards (netuid range, clone exists, blackout, zero hotkey, `targetSlot` bounds + non-zero attested slot, stray not attested), chain-read amount (`ZeroAmount` on zero), full-amount `moveStake` via the clone onto `attested[targetSlot]`, emit. Chain rejections (missing owner record, sub-floor value, dead target) bubble. `proposeBackingLoss`: blackout; fresh union read; require shortfall (`NoBackingShortfall`); record timestamp; emit. `acceptBackingLoss`: require a pending proposal (`NoPendingBackingLoss`) older than the delay (`LossAcceptanceDelayNotMet`); blackout; fresh union read; **require the shortfall still exists** (`NoBackingShortfall` — a recovery during the window voids acceptance); store the fresh total; clear the proposal; emit both values.

- [ ] **Step 2: Tests.** Realistic sequences — wrap first, then break things:
- `test_RecoverStray_RestoresOperationsAfterFullSwap` (swap `keepStake=false` → trip → recover to slot 0 → wrap/unwrap succeed at full backing)
- `test_RecoverStray_RevertsOnAttestedHotkey` / `test_RecoverStray_RevertsOnZeroPosition` / `test_RecoverStray_RevertsOnInvalidTargetSlot`
- `test_RecoverStray_RevertsOnDeadTargetSlot` (target flag cleared → chain error bubbles; retry with another slot succeeds)
- `test_RecoverStray_RevertsOnOwnerlessSource` (all-subnets `keepStake=true` residue)
- `test_RecoverStray_SucceedsAfterOwnerRecordRestored` (`associateHotkey` then recover; ops resume with no owner involvement)
- `test_RecoverStray_RevertsOnSubFloorAmount` (whole-position move below the transfer minimum; mark untouched)
- `test_RecoverStray_RetrievesSubFloorStrayAfterTopUp` (donate into the stray past the transfer minimum, then recover the whole position — the second §7 cure path)
- `test_RecoverStray_NeverWritesAccountedAlpha` (storage assert on success and failure)
- `test_AcceptBackingLoss_ReanchorsAfterDelay` (clearing delete-branch → trip → propose → warp 72h → accept → expectEmit → ops resume at truthful price; a subsequent new disappearance still trips)
- `test_AcceptBackingLoss_RevertsBeforeDelay` / `test_AcceptBackingLoss_RevertsWithoutProposal` / `test_ProposeBackingLoss_RevertsWithoutShortfall` / `test_AcceptBackingLoss_RevertsForNonOwner`
- `test_AcceptBackingLoss_RevertsWhenShortfallCuredDuringDelay` (recovery inside the window voids the pending acceptance)
- `test_ClaimableTao_IncludesClearingSaleProceeds` (clearing sale branch: clone TAO flows through the existing claim index after the re-anchor)
- Fuzz: `testFuzz_RecoverStray_RestoresAnyMovableStrandedAmount(uint256 amount)` (`bound` above the move floor); `testFuzz_DonationCure_CoversAnyMicroDip(uint256 dip)` (`bound` below it).

- [ ] **Step 3: Full suite + size + format.**

---

### Task 5: Exact-or-revert delivery

**Files:**
- Modify: `src/AlphaVault.sol` (`_deliverAndAlign`)
- Test: `test/BackingTripwire.t.sol`

- [ ] **Step 1: Implement.** Count executed transfer legs — gather hops **plus the final delivery transfer** (every leg credits through rounded share-pool arithmetic, spec fact 6); after the gather, revert (`WithdrawTooSmall`) unless the delivery slot covers `assets - gatherHops` RAO; deliver `min(assets, deliverable)` and document that the recipient may receive up to one further RAO short on the delivery leg. The one-RAO-per-leg constant is a documented decision pending Task 8's leg-credit measurement. Update `previewUnwrap` NatSpec to state the per-leg allowance.

- [ ] **Step 2: Tests.** `test_Unwrap_RevertsInsteadOfUnderDelivering` (delivery slot short beyond the allowance), `test_Unwrap_DeliversWithinLegAllowance` (with `setTransferCreditShave(1)`, gather + delivery still succeed and the recipient delta is within legs × 1 RAO of the quote), `testFuzz_Unwrap_DeliversQuoteOrReverts(uint256 shares)`.

- [ ] **Step 3: Full suite + size + format.**

---

### Task 6: Fuzz and invariant hardening

**Files:**
- Test: `test/BackingTripwire.t.sol` (fuzz additions), `test/BackingTripwireInvariant.t.sol` (create)

- [ ] **Step 1: Fuzz suites.**
- `testFuzz_Ops_NeverTripWithoutRekeying(uint8[] memory opSequence)` — interleavings of wrap/unwrap/rebalance/rotation/prune/stake-keeping-swaps/donations/emission/checkpoints: `BackingShort` never fires (re-baseline and checkpoint exactness under leg rounding).
- `testFuzz_Wrap_MintsFairSharesThroughSwap(uint256 depositAmount, uint8 swapPoint, uint8 swapMode)` — all four modes with a checkpoint after every emission step; stake-moving modes end in `BackingShort` before any cheap mint; stake-keeping modes preserve fair pricing throughout.
- `testFuzz_Trip_BoundedByEmissionSinceCheckpoint(uint256 growth, uint256 swapValue)` — grow by `growth`, checkpoint or not (both arms), swap `swapValue` away: trips whenever `swapValue` exceeds growth-since-last-checkpoint; the undetected remainder never exceeds it (the spec §4 bound, encoded).
- `testFuzz_Recovery_NeverMasksSecondHiddenPosition(uint256 a, uint256 b)` — two re-keyed positions; recovering one leaves the vault tripped until the other is recovered or accepted.
- `testFuzz_UnwrapForTao_ExitsFullPositionWithDust(uint256 shares)` — full exits succeed with sub-move-floor residue present.

- [ ] **Step 2: Invariant suite.** Handler drives wrap/unwrap/rebalance/all-four-swap-modes/prune/donate/emission/checkpoint/associate/recoverStray/propose+accept/threshold-clearing against a ground-truth position ledger; hidden states persist until the handler explicitly cures them; the handler checkpoints on a configurable cadence:
- `invariant_VaultNeverMispricesBeyondTheBound`: whenever the vault is live, quoted backing is within emission-accrued-since-last-checkpoint of ledger truth; otherwise every mutating op and pricing view reverts `BackingShort`.
- `invariant_AccountedAlphaIsAlwaysATrackedTotal`: `accountedAlpha` equals a freshly read union total at write time (handler mirrors all three writers); never a caller-adjusted delta; `checkpointBacking` never lowered it.
- `invariant_BurnsDeliverOrRevert`: every alpha-rail burn delivered its quote within the per-leg allowance or the op reverted.

- [ ] **Step 3: Full suite + size + format.**

---

### Task 7: Quality gates

**Files:**
- Modify: test files with pre-existing warnings; `.gas-snapshot` (regenerated)

- [ ] **Step 1: Warning baseline** — fix the 11 pre-existing unsafe-typecast lint warnings in `test/AlphaVaultTestBase.sol` / `test/AlphaVault.t.sol` at root cause; surface any that would need a lint-disable before adding one.
- [ ] **Step 2:** `forge fmt --check`.
- [ ] **Step 3:** `forge build` — zero warnings.
- [ ] **Step 4:** `forge build --sizes` — report the exact margin.
- [ ] **Step 5:** `forge test` — all green.
- [ ] **Step 6:** `forge coverage --report summary` — per-file coverage for changed files; justify any uncovered new branch.
- [ ] **Step 7:** after coverage: `forge snapshot --threads 4` — confirm per-op overhead is in the spec §10 band (~40-55k, plus ~35k per checkpoint call) and record it in the PR description.
- [ ] **Step 8: Self code review** — `code-review` skill on the full diff; verify each finding against the spec before implementing.
- [ ] **Step 9: Security audit** — `security-audit` skill. First-class concerns: tripwire bypass routes, emission-masking sequences included; **any write path to `accountedAlpha` beyond the three sanctioned writers, and any path where `checkpointBacking` could lower it**; ordering of the wrap check vs the flush; `recoverStray` griefing (dead targets, repeated calls, reentrancy on the clone hop); loss-acceptance races (propose → cure → accept must fail; propose → partial cure → accept semantics); donation-driven manipulation vs the virtual-shares guard; floor-mapping correctness (move vs unstake, no full-drain exemption on moves); mark behavior across every op exit path (early returns included). Resolve or explicitly justify every finding.

---

### Task 8: Localnet E2E — MANDATORY before deployment

The mocks encode chain semantics by hand; only a real runtime validates the behaviors the tripwire and recovery rest on. Contract work may merge behind a flag, but deployment is blocked on this task.

**Files:**
- Modify: the pytest e2e suite (see the e2e runbook; `scripts/localnet.sh` lives in the subtensor repo, btcli 9.23.2, 8M deploy gas)

- [ ] **Step 1: Deploy** the updated vault on localnet.
- [ ] **Step 2: Swap matrix** — all four `swap_hotkey_v2` modes against a wrapped position:
  - stake-moving modes: next op reverts `BackingShort`; `recoverStray` → resume at full backing;
  - one-subnet stake-keeping: no trip; next op consolidates;
  - all-subnets stake-keeping: moves revert `HotKeyAccountNotExists`; `try_associate_hotkey(oldHotkey)` from a substrate account; `recoverStray` → resume. No owner action anywhere.
- [ ] **Step 3: Emission + checkpoint** — let real emission accrue on a wrapped position, `checkpointBacking`, then swap: assert the trip; repeat without the checkpoint to observe the documented bound.
- [ ] **Step 4: Prune** — register a newcomer on a full subnet; assert no trip and normal operation.
- [ ] **Step 5: Floors** — boundary the real 100k transfer minimum (move at/below/above, including a whole-position sub-floor rejection and the top-up-then-recover path); raise the nominator threshold via sudo, observe clearing (both branches if reachable), reconcile via propose + accept across the real delay, verify clone TAO flows through the claim index.
- [ ] **Step 6: Rounding** — co-nominator add/remove/emission loops measuring read dips, and per-leg transfer credit across gather chains **and the final delivery transfer**; adjust the Task 5 allowance as a documented decision if any leg credits more than 1 RAO short.

---

### Task 9: Reference watcher

**Files:**
- Create: `e2e/tools/backing_watcher.py` (location per the existing e2e tooling conventions — follow the suite's structure)
- Create: `docs/backing-watcher.md` (plain-language runbook)

The spec names the watcher a production dependency; it ships with the contract change, not after it.

- [ ] **Step 1: Implement** a stateless loop per spec §12: per configured netuid — skip on `isSubnetDissolving`; read `trackedBacking` and `accountedAlpha[currentTokenId]`; call `checkpointBacking` when tracked exceeds the mark (configurable cadence, default hourly); on shortfall, read `StakingHotkeys(cloneColdkey)` via RPC state query (streamed/capped with an alert on abnormal index growth — the index is third-party-growable), diff against the tracked set, and call `recoverStray` per hidden location with target-slot retry; on `HotKeyAccountNotExists`, submit `try_associate_hotkey` from the operator's substrate key, then retry; on sub-floor strays, alert with both cure options rather than auto-spending above a configured value; subscribe to `HotkeySwapped` events for proactive cures; alert on `BackingLossProposed` (public 72-hour challenge window) and on any shortfall persisting past a configured age.
- [ ] **Step 2: Exercise it** against the Task 8 localnet scenarios (swap → auto-recover; emission → auto-checkpoint; ownerless → associate + recover) and record the transcript in the runbook.
- [ ] **Step 3: Runbook** — `docs/backing-watcher.md`: deployment, keys (EVM caller + substrate operator key), cadence-to-blind-spot relationship, alert semantics, and manual fallbacks for every §7 cure row.

---

## Self-review notes (completed)

- Spec coverage: §3 surface → Tasks 1, 3, 4; §4 tripwire + checkpoint + bound → Task 3 (masking regression), Task 6 (bound fuzz + invariant), Task 8 Step 3; §5-§6 recovery/delayed loss → Task 4; §7 cure table → Tasks 3-4, 6, 8-9 (sub-floor both paths tested and in the watcher); §8 floors → Task 1; §9 per-leg delivery → Task 5, Task 8 Step 6; §10 gas band → Task 7 Step 7; §12 runbook → Task 9 + e2e; §13 test plan → Tasks 2-6, 8 (localnet mandatory); §14 exclusions honored.
- Ordering: floors first (Task 1) so every later test runs against chain-faithful move semantics; mocks (Task 2) precede all behavior tasks; the watcher (Task 9) validates against Task 8's localnet.
- No commit steps by design: the user commits (repo policy).
