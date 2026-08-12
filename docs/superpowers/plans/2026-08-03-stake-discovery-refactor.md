# Stake-Discovery Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Implementer profile:** tasks are sized for Opus 5 at xhigh reasoning effort. Reviews run on Fable. Read the spec first: `docs/superpowers/specs/2026-08-03-stake-discovery-refactor-design.md`.

**Goal:** Replace the vault's stored hotkey tracking (`_lastSeenHotkeys` + consolidation roll) with on-chain discovery: metagraph uid enumeration + per-candidate `getStake` reads, guarded by a scalar `accountedAlpha` tripwire, a **move-only** permissionless `recoverStray`, and an owner-gated re-anchoring `acceptBackingLoss`.

**Architecture:** Every mutating op discovers the vault's true positions (enumerate uids 0..getUidCount-1 → hotkeys, union with attested set, read `getStake` per candidate — index-aligned by construction), reverts `BackingShort` if the discovered total dips below the last accounted total, operates on a dynamic in-memory working set, and re-baselines from fresh reads at op end. Move/flush **targets** must be attested ∩ currently-registered (spec §6). Two floors: `minMoveTaoFloor` (init 100k RAO, mirrors the chain's same-subnet transfer minimum) gates moves; `minStakeTaoFloor` (existing, 2e6) keeps gating unstake sizing. Alpha-rail delivery is exact-or-revert with a per-hop 1-RAO rounding allowance. `accountedAlpha` is only ever written from a discovered total — never caller-adjusted.

**Tech Stack:** Solidity ^0.8.20, Foundry (forge 1.7.0), OpenZeppelin, subtensor precompiles (staking V2 `0x…0805` via `getStake`, metagraph `0x…0802`, alpha, subnet, address-mapping). Runtime compatibility pinned to spec v440 semantics.

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
- Precompile interface entries must be validated against the `#[precompile::public(...)]` **fn body** in `~/Projects/subtensor/precompiles/src/` (same-typed param swaps pass unit tests but revert on chain).
- Every vault-side floor pre-check must be traced to the exact v440 chain-side check it mirrors (move/transfer → the 100k transfer minimum; unstake sizing → the staking floor family; full drains exempt). Cite the subtensor file:line in the PR description, not in code comments.
- Gas snapshot: regenerate with `forge snapshot --threads 4` (forge 1.7.0); run it **after** `forge coverage` (coverage poisons `snapshots/AlphaVault.json`).
- **Size gate:** `forge build --sizes` at the end of every task; `AlphaVault` must stay under 24,576 bytes with at least 500 bytes of margin. Current baseline: 22,293. Contingency if exceeded: move discovery/recovery internals to an external library.

---

### Task 1: Metagraph interface

**Files:**
- Create: `src/interfaces/IMetagraph.sol`

**Interfaces:**
- Consumes: `IStaking.getStake` (existing).
- Produces (used by Tasks 2-5):
  - `IMetagraph.getUidCount(uint16 netuid) external view returns (uint16)`
  - `IMetagraph.getHotkey(uint16 netuid, uint16 uid) external view returns (bytes32)`
  - `METAGRAPH_PRECOMPILE = 0x0000000000000000000000000000000000000802`

- [ ] **Step 1: Validate signatures against subtensor source**

Read `~/Projects/subtensor/precompiles/src/metagraph.rs:29-36,163-172` (`getUidCount(uint16)`, `getHotkey(uint16,uint16) -> H256`, both views). Cross-check `precompiles/src/solidity/metagraph.sol`.

- [ ] **Step 2: Create IMetagraph**

Mirror the header style of `src/interfaces/IStaking.sol`; document that `getHotkey` reverts for a uid without a registered hotkey and that enumeration is only safe outside dissolution cleanup.

- [ ] **Step 3: Build + size + format**

Run: `forge build && forge build --sizes && forge fmt && forge fmt --check`

---

### Task 2: Mock infrastructure (chain-faithful)

**Files:**
- Modify: `test/mocks/MockStaking.sol`
- Create: `test/mocks/MockMetagraph.sol`
- Modify: `test/AlphaVaultTestBase.sol`

**Interfaces:**
- Consumes: Task 1 interface.
- Produces (used by Tasks 3-6):
  - `MockStaking` hotkey existence: `setHotkeyExists(bytes32, bool)`; `moveStake`/`transferStake` revert `"HotKeyAccountNotExists"` when either endpoint does not exist; `removeStake` reverts when the source does not exist.
  - `MockStaking` move floor: same-subnet moves/transfers revert `"AmountTooLow"` when the tao value at the mock price is below 100_000 RAO; full-drain `removeStake` exempt from sizing floors.
  - `MockStaking.rekeyPositions(bytes32 oldHotkey, bytes32 newHotkey, uint16 netuid)`.
  - `MockStaking.shaveStake(bytes32 hotkey, bytes32 coldkey, uint16 netuid, uint256 rao)` — simulates share-pool rounding dips (spec fact 9).
  - `MockMetagraph.setNeuron(uint16, uint16, bytes32)`, `getUidCount`, `getHotkey` (revert when unset or `uid >= uidCount`), `zeroUidCount(uint16 netuid)` — models phased dissolution as the chain actually sequences it (spec fact 10: uid count reads zero while keys and stakes still exist).
  - Test-base helpers:
    - `swapHotkeyFull(bytes32 oldHotkey, bytes32 newHotkey, uint16 netuid, bool keepStake)` — uid rebind always; rekey iff `!keepStake`; **owner removal always** (all-subnets mode).
    - `swapHotkeyOneSubnet(bytes32 oldHotkey, bytes32 newHotkey, uint16 netuid, bool keepStake)` — uid rebind always; rekey iff `!keepStake`; old hotkey keeps existing.
    - `pruneNeuron(uint16 netuid, uint16 uid, bytes32 newcomerHotkey)` — uid rebind, stake untouched.
    - `donateStake(bytes32 hotkey, bytes32 coldkey, uint16 netuid, uint256 amount)`.
    - `raiseNominatorThreshold(uint256 newValue, bool deleteBranch)` — force-converts every sub-threshold non-owner nomination (TAO to the staker's coldkey account) or deletes the alpha outright when `deleteBranch`.

- [ ] **Step 1: MockStaking existence, floors, rekey, shave**

Follow the existing storage layout of `MockStaking` (read it first). The four-mode swap behavior and the existence checks are the load-bearing fidelity of these mocks — they are the chain behaviors the design's safety rests on (spec facts 5-7).

- [ ] **Step 2: MockMetagraph** (including `zeroUidCount`)

- [ ] **Step 3: Test-base wiring**

Install `MockMetagraph` at `METAGRAPH_PRECOMPILE`; register default validators as uids 0..2; wire the helpers above. `pruneNeuron` must not touch stake; the two swap helpers must differ exactly in owner removal.

- [ ] **Step 4: Mock-semantics tests** (new `test/StakeDiscovery.t.sol`)

`test_MockMove_RevertsForMissingHotkey`, `test_MockMove_RevertsBelowTransferMinimum`, `test_MockSwapFull_RemovesOldOwner`, `test_MockSwapOneSubnet_KeepsOldOwner`, `test_MockMetagraph_RevertsOnUnsetUid`.

- [ ] **Step 5: Recalibrate floor-boundary tests to the corrected mock floors**

The mock previously rejected moves below 2e6; the chain-faithful floor is 100k, so existing tests calibrated to the old mock behavior break here — e.g. `test/MinStakeTaoFloor.t.sol` `test_RevertWhen_GatherLargestSlotWithinOneQuantumOfFloor` expects `"MockStaking: AmountTooLow"` on a 1.5e6-value gather move that now succeeds. Grep the suite for amounts/expectations that encode the 2e6 move floor and recalibrate each: move-path boundaries retune to 100k; unstake-sizing boundaries keep 2e6. Any failing floor test in later tasks that traces to this recalibration belongs to this step, not to the task that surfaced it.

- [ ] **Step 6: Build + targeted tests + size + format**

Run: `forge build && forge test --match-path "test/StakeDiscovery.t.sol" -v && forge test --match-path "test/MinStakeTaoFloor.t.sol" -v && forge build --sizes && forge fmt`

---

### Task 3: Discovery core and views in AlphaVault

**Files:**
- Modify: `src/AlphaVault.sol`
- Test: `test/StakeDiscovery.t.sol`

**Interfaces:**
- Consumes: Task 1 interface, Task 2 mocks.
- Produces (used by Tasks 4-5):
  - `mapping(uint256 => uint256) public accountedAlpha;`
  - `error BackingShort(uint256 accounted, uint256 discovered);`
  - `_discoverPositions(uint16 netuid, bytes32 coldkey, bytes32[3] memory attested) → (bytes32[] hotkeys, uint256[] stakes, uint256 positionCount, uint256 total, uint256 registeredCount)` — candidates are enumerated uids then deduped non-zero attested slots; `stakes[i]` is the `getStake` read for `hotkeys[i]` (index-aligned); the first `registeredCount` candidates are the enumerated registered set; callers use the boundary for target eligibility.
  - `_checkBacking(uint256 tokenId, uint256 discoveredTotal) private view`
  - `discoveredBacking(uint256 netuid) external view returns (uint256)`

- [ ] **Step 1: Storage, error** — `accountedAlpha`, `BackingShort`, `IMetagraph` import.

- [ ] **Step 2: Discovery** — enumerate `0..getUidCount-1` via `getHotkey`, append non-zero attested slots deduplicated against the full candidate list (an overlapping candidate read twice would double-count), then one `getStake` per candidate; return positions, total, and the `registeredCount` boundary. Callers are responsible for the dissolution blackout (spec §4.4): discovery must never run on a dissolving netuid.

- [ ] **Step 3: Tripwire helper + view rewiring**

- `totalStake(tokenId)`: clone missing → 0; **dissolution blackout first** (revert `SubnetInDissolutionBlackoutPeriod`); then raw discovery total with the raw registry set. No `_checkBacking`.
- `discoveredBacking(netuid)`: `currentTokenId`, clone missing → 0; blackout; raw discovery total.
- `sharePrice`, `previewWrap`, `previewUnwrap`: existing guards (blackout already present), then discovery + `_checkBacking` before quoting.

- [ ] **Step 4: Tests**

- `test_TotalStake_FollowsHotkeySwap` (one-subnet, `keepStake=false`)
- `test_TotalStake_FollowsFullSwap` (all-subnets, `keepStake=false` — old owner gone, total unchanged)
- `test_TotalStake_CountsAttestedUnregisteredValidator` (prune; still attested → counted)
- `test_TotalStake_CountsDonationUnderRegisteredHotkey`
- `test_TotalStake_IgnoresDonationUnderUnregisteredHotkey`
- `test_TotalStake_RevertsDuringDissolutionCleanup` (`zeroUidCount` + dissolving flag; asserts the vault's blackout error fires before any discovery read — unguarded discovery would silently report a near-zero total, not revert)
- `test_TotalStake_CountsOverlappingAttestedValidatorOnce` (attested hotkey also registered — no double count)
- `test_DiscoveredBacking_MatchesTotalStake`
- `test_SharePrice_RevertsWhenBackingShort` (force `accountedAlpha` via `stdstore`)

- [ ] **Step 5: Build + suite + size + format**

---

### Task 4: Mutating-ops rewrite and legacy deletion

**Files:**
- Modify: `src/AlphaVault.sol`
- Delete: `test/RollerConsolidation.t.sol` (scenarios re-homed below)
- Modify: any test referencing `lastSeenHotkeys` / `ConsolidationBelowFloor` (grep)
- Test: `test/StakeDiscovery.t.sol`

**Interfaces:**
- Consumes: Task 3 helpers.
- Produces (used by Tasks 5-6):
  - `uint256 public minMoveTaoFloor` (init `100_000`), `setMinMoveTaoFloor` (owner, capped at `MOVE_FLOOR_CAP = 10_000_000`), `event MinMoveTaoFloorUpdated`, `error MinMoveTaoFloorTooHigh`, `error NoLiveTarget()`.
  - `_buildWorkingSet(...) → (bytes32[] hotkeys, uint256[] balances, uint256 attestedCount, bool[] registered)` — attested slots first (present even at zero balance, each flagged registered/not via the discovery boundary), strays after (all registered).
  - `_firstEligibleTarget(bytes32[] memory hotkeys, bool[] memory registered, uint256 attestedCount) → uint256` — first attested index that is registered; `NoLiveTarget` sentinel otherwise.
  - `_consolidateStrays(...)` — direct move onto the eligible target for every position outside attested ∩ registered (registered strays AND attested-but-unregistered slots) clearing `minMoveTaoFloor`; skipped entirely when no target. Draining attested-but-unregistered slots is load-bearing: it is what stops a swap/prune from ever producing a hidden stray when any op runs before the registry refresh.
  - `_recordAccountedAlpha(uint256 tokenId, uint16 netuid, bytes32 coldkey, bytes32[] memory workingHotkeys)` — one `getStake` re-read per working-set hotkey; stores the summed total. **The only two writers of `accountedAlpha` in the codebase are this helper and `acceptBackingLoss` (Task 5), both from freshly discovered totals.**

- [ ] **Step 1: Floors** — add `minMoveTaoFloor` storage/admin; introduce `_isBelowMoveFloorAtAnyPrice` / `_isBelowMoveFloorAtReadPrice` analogues. Audit every existing floor call-site and re-point it at the correct floor: moves/transfers/flush-delivery → move floor; deposit flush sizing (`DepositTooSmall`) → move floor (the flush is a same-subnet transfer); unstake sizing in `unwrapForTao`/`_sellableChunk` → keep `minStakeTaoFloor`. Record the mapping in the PR description with subtensor cites.

- [ ] **Step 2: Working set + eligible-target consolidation** (spec §5-§6). `_buildWorkingSet` and `_discoverPositions` must skip `bytes32(0)` attested slots (1- and 2-validator registries carry zero slots) and dedup attested appends against the full candidate list. Interim arithmetic is fine — attested balances are re-read before weight moves and the end-of-op baseline re-reads everything.

- [ ] **Step 3: Re-baseline helper** (`_recordAccountedAlpha`).

- [ ] **Step 4: Generalize the fixed-array helpers**

- `_alignToWeights` / `_rebalanceStep`: first `attestedCount` entries; targets computed over registered slots only (an unregistered attested slot is zero-target — consolidation already drained it); skip any move whose destination slot is unregistered.
- `_deliverAndAlign`: gather among attested-and-registered slots plus consolidated balances; count executed hops; **exact-or-revert**: after the gather, revert (`WithdrawTooSmall`) unless the delivery slot covers `assets - executedHops` RAO; deliver `min(assets, deliverable)` only within that allowance (the 1-RAO-per-hop constant is a documented decision pending Task 8's hop-credit measurement). `GatherBelowFloor` pre-check moves to the move floor.
- `_sellRound` / `unwrapForTao`: iterate the whole working set (full drains floor-exempt).

- [ ] **Step 5: Rewire the four ops** (common shape per spec §5; `wrap` prices pre-flush and gates `chosenHotkey` on attested ∩ registered; `unwrapForTao` uses the raw registry set; dissolved paths untouched; every op ends with `_recordAccountedAlpha`).

- [ ] **Step 6: Delete legacy** — `_lastSeenHotkeys`, `lastSeenHotkeys()`, `_unionStake` (both), `_fetchBalances`, `_consolidateRotatedStake`, `_chooseRichestSlot`, `_anyRotatedOut`, `_isRotatedOut`, `ConsolidationBelowFloor`. Update the contract header (plain language). Grep stragglers.

- [ ] **Step 7: Re-home behavior coverage + update stale tests**

Re-express `RollerConsolidation` scenarios: `test_Wrap_ConsolidatesRotatedOutStake`, `test_Rebalance_LeavesSubMoveFloorStrayInPlace`, `test_Wrap_PricesFromPreFlushTotal`, `test_Unwrap_RevertsWhenBackingShort` (prune + rotate → hidden), `test_Wrap_SucceedsThroughHotkeySwap`, `test_AccountedAlpha_TracksOpEndTotal`. Target-gating coverage: `test_Consolidation_SkipsStaleAttestedTarget` (swap before re-attestation; assert no move onto the stale identity, op still completes), `test_Wrap_RevertsWhenChosenHotkeyUnregistered`, `test_Rebalance_SkipsMovesWhenNoLiveTarget`, `test_Unwrap_RevertsInsteadOfUnderDelivering` (immovable dust forces exact-or-revert), `test_UnwrapForTao_ExitsWhenNoLiveTarget`. Registry-shape coverage: `test_Wrap_SucceedsWithSingleValidatorRegistry` (zero attested slots skipped; overlap counted once). Stray-prevention coverage: `test_Rebalance_DrainsAttestedUnregisteredSlot` (one-subnet `keepStake=true` swap; a `rebalance` poke before the registry refresh drains the old slot, and the later refresh causes no `BackingShort`).

- [ ] **Step 8: Full suite + size + format**

---

### Task 5: recoverStray + acceptBackingLoss

**Files:**
- Modify: `src/AlphaVault.sol`
- Test: `test/RecoverStray.t.sol` (create)

**Interfaces:**
- Consumes: Task 3-4 helpers.
- Produces:
  - `function recoverStray(uint256 netuid, bytes32 strayHotkey) external nonReentrant` — **move-only**, never writes `accountedAlpha`.
  - `function acceptBackingLoss(uint256 tokenId) external onlyOwner` — requires a live shortfall; re-anchors `accountedAlpha` to a fresh discovered total; never subtractive.
  - `event StrayStakeRecovered(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 alpha);`
  - `event BackingLossAccepted(uint256 indexed tokenId, uint256 previousAccounted, uint256 newAccounted);`
  - `error HotkeyNotStray();` (plus reuse of `NoLiveTarget`)

- [ ] **Step 1: Implement per spec §7-§8**

`recoverStray`: guards (zero hotkey, blackout, clone exists, attested → `HotkeyNotStray`), chain-read amount (`ZeroAmount` on zero), one discovery for the registered set, `_firstEligibleTarget` (`NoLiveTarget`), full-amount `moveStake`, emit. No baseline write, no sell branch, no tripwire. Chain-rejected moves (sub-move-floor, nonexistent source) bubble.

`acceptBackingLoss`: blackout; fresh discovery; `require discovered < accountedAlpha[tokenId]` (else revert — reuse `ZeroAmount` or add a dedicated error, implementer's judgment with NatSpec); write `accountedAlpha := discovered`; emit with both values.

- [ ] **Step 2: Tests (`test/RecoverStray.t.sol`)** — realistic sequences (wrap first, then break things):

- `test_RecoverStray_RestoresOperationsAfterPrune` (prune + rotate → `BackingShort` → recover → unwrap succeeds with full backing)
- `test_RecoverStray_RestoresAfterOneSubnetKeepStakeSwap` (spec fact 5, third mode)
- `test_RecoverStray_RevertsOnAttestedHotkey` (`HotkeyNotStray`)
- `test_RecoverStray_RevertsOnZeroPosition`
- `test_RecoverStray_RevertsWhenNoLiveTarget`
- `test_RecoverStray_RevertsOnOwnerlessSource` (all-subnets `keepStake=true` residue; mock bubbles the existence error)
- `test_RecoverStray_SucceedsAfterOwnerRecordRestored` (same residue, then the mock's `setHotkeyExists(hotkey, true)` models the substrate-side association; recovery then completes and ops resume — no owner action needed)
- `test_RecoverStray_RevertsOnSubFloorAmount` (chain rejects the sub-move-floor move; call bubbles the rejection, baseline untouched)
- `test_RecoverStray_NeverWritesAccountedAlpha` (before/after storage assert on both success and failure)
- `test_RecoverStray_RegisteredNonAttestedHotkeyConsolidates`
- `test_AcceptBackingLoss_ReanchorsToDiscoveredTotal` (expectEmit both values; ops resume; a subsequent new disappearance still trips — the zero-slack property)
- `test_AcceptBackingLoss_RevertsWithoutShortfall`
- `test_AcceptBackingLoss_RevertsForNonOwner`
- `test_DonationCure_LiftsBackingShort` (micro-shortfall via `shaveStake`; third-party donation unfreezes without any privileged call)
- Fuzz: `testFuzz_RecoverStray_RestoresAnyMovableStrandedAmount(uint256 amount)` (`bound` above the move floor); `testFuzz_DonationCure_CoversAnyMicroDip(uint256 dip)` (`bound` below it).

- [ ] **Step 3: Full suite + size + format**

---

### Task 6: Fuzz and invariant hardening

**Files:**
- Test: `test/StakeDiscovery.t.sol` (fuzz additions)
- Create: `test/StakeDiscoveryInvariant.t.sol`

- [ ] **Step 1: Fuzz suites**

- `testFuzz_Wrap_MintsFairSharesThroughSwap(uint256 depositAmount, uint8 swapPoint, uint8 swapMode)` — all four swap modes; registered-swap modes must keep second-depositor share value within rounding of fair; hidden-making modes must end in `BackingShort`, never a cheap mint.
- `testFuzz_Ops_NeverRevertBackingShortWithoutStranding(uint8[] memory opSequence)` — interleavings of wrap/unwrap/rebalance/registered-swaps/donation: `BackingShort` never fires (re-baseline exactness under move rounding).
- `testFuzz_Recovery_NeverMasksSecondHiddenPosition(uint256 a, uint256 b)` — strand two positions; recovering one must leave the vault tripped until the other is recovered or accepted.
- `testFuzz_DonationThenRecovery_NeverLowersBaseline(uint256 donation)` — post-baseline donation + any recovery sequence: `accountedAlpha` never drops below its pre-donation value.
- `testFuzz_UnwrapForTao_ExitsFullPositionWithStrays(uint256 shares)` — full exits with up to 256 sub-move-floor strays present.

- [ ] **Step 2: Invariant suite** (handler drives wrap/unwrap/rebalance/all-four-swap-modes/prune/donate/recoverStray/acceptBackingLoss/threshold-clearing; hidden states persist across arbitrary sequences — no auto-paired recovery):

- `invariant_VaultNeverSilentlyMisprices`: at every state, either `discoveredBacking` covers `accountedAlpha` and quotes equal the handler's complete ground-truth ledger, or every mutating op and pricing view reverts `BackingShort`.
- `invariant_AccountedAlphaIsAlwaysADiscoveredTotal`: `accountedAlpha` equals a value some discovery actually returned at write time (handler mirrors both writers); it is never a caller-adjusted delta.
- `invariant_StaleIdentityNeverATarget`: no `moveStake`/flush destination outside attested ∩ registered at execution time (handler asserts on the mock's move log).
- `invariant_BurnsDeliverOrRevert`: every share burn on the alpha rail delivered its quoted assets within the executed-hop rounding bound, or the whole op reverted.

- [ ] **Step 3: Full suite + size + format**

---

### Task 7: Quality gates

**Files:**
- Modify: test files with pre-existing warnings; `.gas-snapshot` (regenerated)

- [ ] **Step 1: Warning baseline** — fix the 11 pre-existing unsafe-typecast lint warnings in `test/AlphaVaultTestBase.sol` / `test/AlphaVault.t.sol` at root cause (typed values, bounded casts). If any genuinely requires a lint-disable, stop and surface it to the user first.
- [ ] **Step 2: Format check** — `forge fmt --check`.
- [ ] **Step 3: Build** — `forge build` with zero warnings.
- [ ] **Step 4: Size gate** — `forge build --sizes`: `AlphaVault` < 24,576 with ≥ 500 bytes margin; report the exact number.
- [ ] **Step 5: Full tests** — `forge test`.
- [ ] **Step 6: Coverage** — `forge coverage --report summary`; report per-file coverage for changed files; flag any uncovered new branch with a reason.
- [ ] **Step 7: Gas snapshot** — after coverage: `forge snapshot --threads 4`. Confirm mutating-op magnitudes are consistent with the spec's 256-uid worst-case estimate (~2.5-3M discovery + re-baseline overhead; test-scale far less) and record the worst-case figure in the PR description.
- [ ] **Step 8: Self code review** — `code-review` skill on the full diff; verify each finding against the spec before implementing.
- [ ] **Step 9: Security audit** — `security-audit` skill. First-class concerns: tripwire bypass routes; **any write path to `accountedAlpha` other than the two sanctioned writers**; `recoverStray` griefing; stale-target moves; donation-driven share-price manipulation vs virtual shares; discovery-gas DoS via dust positions under registered hotkeys; double-counting of attested-and-registered candidates; reentrancy on new external call sequences; floor-mapping correctness (move vs unstake). Resolve or explicitly justify every finding.

---

### Task 8: Localnet E2E — MANDATORY before deployment

The mocks encode chain semantics by hand; only a real runtime can validate the behaviors the design's safety rests on (swap modes, existence checks, floors, clearing, phased dissolution). Contract work may merge behind a flag, but **deployment is blocked on this task** (spec §13).

**Files:**
- Modify: the pytest e2e suite (see the e2e runbook; suite landed in PR #32)

- [ ] **Step 1:** Localnet runbook (`scripts/localnet.sh` in the subtensor repo, btcli 9.23.2, 8M deploy gas). Deploy the refactored vault.
- [ ] **Step 2: Migrate e2e assertions off the deleted view** — `e2e/alpha_e2e/environment.py:117` casts `lastSeenHotkeys(uint256)(bytes32[3])`, asserted in `e2e/tests/test_min_stake_floor.py`, `test_hostile_dust.py`, `test_min_stake_liveness.py`. Rewrite the helper and those assertions against discovery-based state (`discoveredBacking`, per-hotkey `getStake`).
- [ ] **Step 3: Swap matrix** — all four `swap_hotkey_v2` modes against a wrapped position, plus a measured per-hop move-credit deficit across gather/consolidation moves (validates the exact-or-revert allowance; if hops can credit more than 1 RAO short, adjust the allowance as a documented decision):
  - registered modes (`keep_stake=false`, one/all subnets): `totalStake` unchanged, next op succeeds without recovery, no move onto the old identity while the registry is stale;
  - one-subnet `keep_stake=true`: post-re-attestation `BackingShort` → `recoverStray` → resume;
  - all-subnets `keep_stake=true`: confirm the position is unmovable on-chain while the old hotkey has no owner record (`HotKeyAccountNotExists`), then send `try_associate_hotkey(oldHotkey)` from a substrate account and assert `recoverStray` now completes and ops resume — the freeze clears without any owner action.
- [ ] **Step 4: Prune** — register a newcomer on a full subnet; walk `BackingShort → recoverStray → resume` on-chain.
- [ ] **Step 5: Floors** — boundary-test the real 100k RAO transfer minimum (move at/below/above) and the nomination threshold: raise it via sudo, observe clearing (and, if reachable, the delete branch), reconcile via `acceptBackingLoss`, verify clone TAO flows through the claim index.
- [ ] **Step 6: Share-pool churn** — co-nominator add/remove/emission loops against the wrapped position; record any getter dips. If dips are observed, decide (with the user) whether the donation cure suffices or an explicit comparison epsilon is added — a documented decision, not a silent tolerance.
- [ ] **Step 7: Dissolution + gating** — start a dissolution, verify views revert with the blackout error during phased cleanup (the uid count reads zero while teardown continues — a silent near-zero total here is a bug) and the dissolved path still pays; toggle `PrecompileEnable` for metagraph off/on and verify the failure is distinguishable from `BackingShort`.

---

## Self-review notes (completed)

- Spec coverage: §3 storage/interfaces → Tasks 1, 3, 4, 5; §4 discovery → Task 3; §5 op skeleton + views → Tasks 3-4; §6 eligible targets → Tasks 4-5 (invariant c); §7 recoverStray + §8 acceptBackingLoss → Task 5 (invariant b enforces the two-writers rule); §9 cures → Tasks 4-6 (drain rule, recovery, donation cure); §10 semantics → tested in Tasks 3-6; §11 terminal states → Tasks 5, 8; §12 operational requirements → e2e Task 8 + size gates throughout; §13 test plan → Tasks 2-6, 8 (localnet mandatory); §14 exclusions honored (no registry changes, no subtensor changes).
- Type consistency: `_discoverPositions` 5-tuple (with `registeredCount`) consumed in Tasks 4-5; the working set carries `registered` flags end-to-end.
- No commit steps by design: the user commits (repo policy).
