# Hotkey-Swap Self-Heal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `AlphaVault` detect and self-recover when a validator's coldkey renames its hotkey with `swap_hotkey`, so the vault's alpha backing never silently undercounts (which today over-mints on `wrap` and underpays on `unwrap`).

**Architecture:** Give each per-netuid validator position a durable `{hotkey, tracked}` slot in the vault, where `tracked` is the expected alpha backing under that hotkey. Every mutating path runs a fail-closed health check (`getStake(hotkey, vaultColdkey, netuid) >= tracked`); on a miss it walks the chain's hotkey-successor edges to follow the moved stake and auto-heals the slot. A permissionless `heal()` covers longer chains and cross-subnet cases via hotkey-lineage roots. When no on-chain lineage evidence exists, the op stays reverted until the existing threshold-signed attesters re-attest the registry (the L0 path already in production) — no new privileged role, because the vault is ownerless.

**Tech Stack:** Solidity ^0.8.20, Foundry (`forge`), OpenZeppelin, Bittensor EVM precompiles (staking at `0x…0805`), subtensor `release-444` lineage getters.

## Global Constraints

- Solidity `^0.8.20`; Foundry layout (`src/`, `test/`, `script/`).
- **Spec-444 assumption:** `getHotkeySuccessor(bytes32,uint16)` and `getHotkeyRoot(bytes32,uint16)` are assumed to ship on the live chain (`main`/`release-444`). No other lineage getters are used. Detection (`getStake`) already works on 443.
- **Only two new precompile getters.** Owner-coldkey, coldkey-root, coldkey-successor, and hotkey-owner getters are NOT used (rung 3 was dropped).
- **Ownerless vault.** `AlphaVault` has no owner/admin (PR #38). No task may add one. The only privileged actor in the system is the `ValidatorRegistry` attester set.
- **No test-first TDD.** Implement the change, then add focused fuzz + unit tests (prefer `testFuzz_` with `bound()` over `vm.assume`; explicit unit tests for boundaries and revert cases). Test names are `test_<Scenario>_<Outcome>` / `testFuzz_<Scenario>` / `test_RevertWhen_<Condition>`, exactly two segments after the prefix.
- **Comments:** minimal, "why" only, ASCII only, no chain-internal identifiers (e.g. never name subtensor storage items), no review-finding labels, one statement per line.
- **Events:** user-meaningful only. New events: `SlotAutoHealed`, `SlotHealed`. No plumbing/internal-hop events, no kind enums.
- **Per-task workflow before marking done:** `forge fmt`, `forge build` (zero warnings), `forge test`, `forge coverage` (report changed-line coverage), then invoke the `code-review` skill and the `security-audit` skill and resolve findings.
- **Git:** feature branch only, never `main`; `git add <path>` explicitly (never `-A`/`.`); `git rm` not `rm`; commit at the end of each task.
- **Gas snapshots:** regenerate `.gas-snapshot` with the CLI `--threads 4` on forge v1.7.0; never let `forge coverage` poison snapshots.

---

## File Structure

- `src/interfaces/IStaking.sol` — **modify.** Add the two lineage getters. One responsibility: the staking precompile ABI.
- `src/HotkeyLineage.sol` — **create.** A stateless internal library of pure view logic over `IStaking`: the bounded successor walk and the two evidence-rung predicates. Kept out of the vault so the lineage rules are testable in isolation and the 1290-line vault does not grow a second concern.
- `src/AlphaVault.sol` — **modify.** Home of slot state, `tracked` accounting, health check, auto-heal, `heal()`, and their integration into `wrap` / `unwrap` / `unwrapForTao` / `rebalance`. The `_lastSeenHotkeys` memory is promoted to the new slot struct.
- `test/mocks/MockStaking.sol` — **modify.** Add settable successor/root maps with absence semantics so tests can build swap chains and forks.
- `test/HotkeyLineage.t.sol` — **create.** Unit + fuzz tests for the library.
- `test/HotkeySwapHeal.t.sol` — **create.** End-to-end vault tests: detection, auto-heal, `heal()` rungs, fail-closed reverts, and the authorized-rotation interaction.
- `test/HotkeySwapHeal.invariant.t.sol` — **create.** Protocol invariants.
- `test/AlphaVault.gas.t.sol` — **modify.** Add gas cases for the healthy hot path and a one-hop auto-heal.
- `script/e2e/` (localnet, spec-444) — **create.** Real-swap → auto-heal and dereg-then-attest → adopt e2e. Expected red until a 444 localnet exists (accepted).

---

## Interface & Type Reference (used across tasks)

```solidity
// IStaking additions — return (exists, value); exists=false means absent (caller folds absent -> self).
function getHotkeySuccessor(bytes32 hotkey, uint16 netuid) external view returns (bool exists, bytes32 successor);
function getHotkeyRoot(bytes32 hotkey, uint16 netuid) external view returns (bool exists, bytes32 root);

// HotkeyLineage library
function walk(IStaking staking, bytes32 hotkey, uint16 netuid, bytes32 vaultColdkey, uint256 tracked, uint8 bound)
    internal view returns (bool healed, bytes32 newHotkey);
function sameRoot(IStaking staking, bytes32 a, bytes32 b, uint16 netuid) internal view returns (bool);
function successorLeadsTo(IStaking staking, bytes32 from, bytes32 candidate, uint16 evidenceNetuid)
    internal view returns (bool);

// AlphaVault slot (replaces `mapping(uint256 => bytes32[3]) _lastSeenHotkeys`)
struct Slot { bytes32 hotkey; uint128 tracked; }
mapping(uint256 => Slot[3]) private _slots;

// AlphaVault new external surface
function heal(uint256 netuid, uint8 slotIdx, bytes32 candidate, uint16 evidenceNetuid) external;

// AlphaVault constants
uint8 private constant WALK_BOUND = 3;
```

---

### Task 1: Precompile surface + mock lineage

**Files:**
- Modify: `src/interfaces/IStaking.sol`
- Modify: `test/mocks/MockStaking.sol`
- Test: `test/HotkeyLineage.t.sol` (mock-only assertions; library added in Task 2)

**Interfaces:**
- Produces: `IStaking.getHotkeySuccessor`, `IStaking.getHotkeyRoot` (signatures above); mock setters `setHotkeySuccessor(bytes32 from, uint16 netuid, bytes32 to)` and `setHotkeyRoot(bytes32 key, uint16 netuid, bytes32 root)`.

- [ ] **Step 1: Add the two getters to `IStaking.sol`** (after `getStake`), matching the 444 ABI: both return `(bool, bytes32)`, absent entries return `(false, 0)`. One-line NatSpec each, "why absent means self-root" stated once.

- [ ] **Step 2: Extend `MockStaking`** with two nested maps and their setters, plus `exists` tracking so an unset entry returns `(false, bytes32(0))`:

```solidity
mapping(bytes32 => mapping(uint256 => bytes32)) private _successor;
mapping(bytes32 => mapping(uint256 => bool)) private _successorSet;
mapping(bytes32 => mapping(uint256 => bytes32)) private _root;
mapping(bytes32 => mapping(uint256 => bool)) private _rootSet;

function setHotkeySuccessor(bytes32 from, uint256 netuid, bytes32 to) external {
    _successor[from][netuid] = to;
    _successorSet[from][netuid] = true;
}
function getHotkeySuccessor(bytes32 hotkey, uint16 netuid) external view returns (bool, bytes32) {
    return (_successorSet[hotkey][netuid], _successor[hotkey][netuid]);
}
```

(Mirror for root.) These mirror the chain: the mock never folds absent to self — the caller does.

- [ ] **Step 3: Add mock round-trip tests** to `test/HotkeyLineage.t.sol`:
  - `test_MockSuccessor_AbsentReturnsFalseZero` — unset entry returns `(false, bytes32(0))`.
  - `test_MockSuccessor_SetRoundTrips` — after `setHotkeySuccessor`, getter returns `(true, to)`.
  - Same two for root.

- [ ] **Step 4: Run** `forge test --match-path test/HotkeyLineage.t.sol -vvv`. Expected: PASS.

- [ ] **Step 5: Workflow + commit.** `forge fmt`, `forge build` (zero warnings), targeted test, coverage of the mock/interface diff. Then:

```bash
git add src/interfaces/IStaking.sol test/mocks/MockStaking.sol test/HotkeyLineage.t.sol
git commit -m "feat(staking): add hotkey lineage getters to interface and mock"
```

---

### Task 2: `HotkeyLineage` library (walk + evidence rungs)

**Files:**
- Create: `src/HotkeyLineage.sol`
- Test: `test/HotkeyLineage.t.sol`

**Interfaces:**
- Consumes: `IStaking.getStake`, `IStaking.getHotkeySuccessor`, `IStaking.getHotkeyRoot`.
- Produces: `HotkeyLineage.walk`, `HotkeyLineage.sameRoot`, `HotkeyLineage.successorLeadsTo` (signatures above).

- [ ] **Step 1: Write the library.** All three functions are `internal view`. Core logic:

```solidity
// Walk successors up to `bound` hops, checking the vault's stake at every hop. The stake can be
// parked mid-chain (a rename that leaves stake put), so the tip is not the only candidate.
function walk(IStaking staking, bytes32 hotkey, uint16 netuid, bytes32 vaultColdkey, uint256 tracked, uint8 bound)
    internal view returns (bool healed, bytes32 newHotkey)
{
    bytes32 h = hotkey;
    for (uint8 i; i < bound; ++i) {
        (bool exists, bytes32 next) = staking.getHotkeySuccessor(h, netuid);
        if (!exists || next == h) break;
        if (staking.getStake(next, vaultColdkey, netuid) >= tracked) return (true, next);
        h = next;
    }
    return (false, bytes32(0));
}

// Absent root folds to self on BOTH sides, matching the chain's OptionQuery semantics.
function sameRoot(IStaking staking, bytes32 a, bytes32 b, uint16 netuid) internal view returns (bool) {
    return _rootOrSelf(staking, a, netuid) == _rootOrSelf(staking, b, netuid);
}

function successorLeadsTo(IStaking staking, bytes32 from, bytes32 candidate, uint16 evidenceNetuid)
    internal view returns (bool)
{
    (bool exists, bytes32 next) = staking.getHotkeySuccessor(from, evidenceNetuid);
    if (exists && next == candidate) return true;
    return sameRoot(staking, from, candidate, evidenceNetuid);
}

function _rootOrSelf(IStaking staking, bytes32 key, uint16 netuid) private view returns (bytes32) {
    (bool exists, bytes32 root) = staking.getHotkeyRoot(key, netuid);
    return exists ? root : key;
}
```

- [ ] **Step 2: Add a tiny harness** in the test file that etches `MockStaking` at `STAKING_PRECOMPILE` and exposes `walk/sameRoot/successorLeadsTo` via external wrappers (libraries are not directly callable from `vm`).

- [ ] **Step 3: Add library tests** (`test/HotkeyLineage.t.sol`):
  - `test_Walk_OneHopHealsToSuccessor` — A→B, stake `tracked` under B, `walk` returns `(true, B)`.
  - `testFuzz_Walk_HealsWithinBound` — `hops = bound(rawHops, 1, WALK_BOUND)`; build a chain and park `tracked` at the last hop; assert `walk` finds it.
  - `test_Walk_ChecksStakeEveryHop` — chain A→B→C, stake parked at B (a mid-chain rename), assert `walk` returns B not C.
  - `test_Walk_DeadEndReturnsFalse` — no successor from A returns `(false, 0)`.
  - `test_Walk_ExceedsBoundReturnsFalse` — chain longer than `WALK_BOUND` with stake only past the bound returns `(false, 0)`.
  - `test_SameRoot_AbsentFoldsToSelfBothSides` — A→B (root[B]=A, root[A] absent), assert `sameRoot(A,B)` true; assert `sameRoot(A, X)` false for unrelated X.
  - `test_SameRoot_ForkSharesRoot` — A→B and A→C both rooted at A, assert `sameRoot(B,C)` true.
  - `test_SuccessorLeadsTo_DirectEdge` and `test_SuccessorLeadsTo_ViaRoot`.

- [ ] **Step 4: Run** `forge test --match-path test/HotkeyLineage.t.sol -vvv`. Expected: PASS.

- [ ] **Step 5: Workflow + commit.**

```bash
git add src/HotkeyLineage.sol test/HotkeyLineage.t.sol
git commit -m "feat(vault): add HotkeyLineage walk and evidence-rung library"
```

---

### Task 3: Slot state + `tracked` accounting

Promote `_lastSeenHotkeys` (a bare `bytes32[3]`) to `Slot[3]` carrying the `tracked` high-water, and maintain `tracked` on every vault-signed stake mutation. **No health check or heal yet** — this task only makes the expectation durable and correct, so a reviewer can gate the accounting independently of detection.

**Files:**
- Modify: `src/AlphaVault.sol`
- Test: `test/HotkeySwapHeal.t.sol`

**Interfaces:**
- Consumes: existing `_unionStake`, `_consolidateRotatedStake`, `_fetchBalances`, `_coldkeyOf`, `IStaking.getStake`.
- Produces: `struct Slot`, `mapping(uint256 => Slot[3]) _slots`, `slots(uint256) view returns (Slot[3])`; internal helpers `_slotHotkeys(tokenId) returns (bytes32[3])`, `_ratchetTracked(tokenId, slotIdx, observed)`, `_reduceTracked(tokenId, slotIdx, amount)`.

- [ ] **Step 1: Replace the state.** Swap `mapping(uint256 => bytes32[3]) private _lastSeenHotkeys;` for `mapping(uint256 => Slot[3]) private _slots;`. Add `_slotHotkeys(tokenId)` that projects the three `hotkey` fields into a `bytes32[3]`, and repoint every current reader of `_lastSeenHotkeys` (`_consolidateRotatedStake`, `_unionStake`, `lastSeenHotkeys` view) at `_slotHotkeys`. Keep the public `lastSeenHotkeys(tokenId)` view (now derived) so existing tests keep compiling; add `slots(tokenId)` returning the full `Slot[3]`.

- [ ] **Step 2: Define the `tracked` update rules** as internal helpers and wire them into the existing flows (this is the accounting core):
  - After the vault stakes alpha onto slot `i` (wrap deposit lands; `_rebalance`/`_alignToWeights`/`_deliverAndAlign` move alpha onto a slot hotkey): set `tracked` for that slot to the post-op `getStake(slot.hotkey, coldkey, netuid)`. Because the vault just wrote it, chain and expectation agree.
  - When `_consolidateRotatedStake` refreshes the remembered set to the current registry set, set each new slot's `tracked` to the consolidated `getStake` for its hotkey (authorized rotation resets the high-water).
  - Add `_ratchetTracked(tokenId, slotIdx, observed)`: `if (observed > tracked) tracked = observed` — used later by the health check to absorb emissions. Expose it now; call site arrives in Task 4.
  - Because the vault sets `tracked` from live `getStake` right after each of its own writes, a vault-initiated remove (unwrap/rebalance-away) is captured by the same "set to post-op getStake" rule — there is no separate decrement path to drift.

- [ ] **Step 3: Guard `uint128`.** `tracked` is `uint128`; alpha balances are `uint256` from the precompile. Add an internal `_toU128(uint256) returns (uint128)` that reverts `TrackedOverflow()` above `type(uint128).max`. Alpha supply per subnet is far below `2^128`, so this is a defensive bound with a brief "why" comment, not an expected path.

- [ ] **Step 4: Add tests** (`test/HotkeySwapHeal.t.sol`, extends `AlphaVaultTestBase`):
  - `test_Wrap_SetsTrackedToStaked` — after a deposit+wrap, slot 0 `tracked` equals the vault's `getStake` for hotkey1.
  - `testFuzz_Emission_RatchetsTrackedUp` — `extra = bound(raw, 1, 1e15)`; simulate emission, call `_ratchetTracked` via a test-only path (or the Task-4 health check once available); assert `tracked` rises to the new stake and never falls.
  - `test_Unwrap_LowersTrackedToPostBalance` — after a partial unwrap, `tracked` equals the reduced `getStake`.
  - `test_AuthorizedRotation_ResetsTracked` — attesters rotate hotkey1→hotkey4; after a mutating call, slot for hotkey4 has `tracked` equal to the consolidated stake and no stale high-water from hotkey1.
  - `test_RevertWhen_TrackedOverflow` — force a `getStake` above `type(uint128).max` in the mock and assert `TrackedOverflow`.

- [ ] **Step 5: Run** `forge test --match-path test/HotkeySwapHeal.t.sol -vvv` and the full suite (this task refactors shared state): `forge test`. Expected: PASS (existing tests unaffected because `_slotHotkeys` preserves prior behavior).

- [ ] **Step 6: Workflow + commit.**

```bash
git add src/AlphaVault.sol test/HotkeySwapHeal.t.sol
git commit -m "feat(vault): promote last-seen hotkeys to tracked slots"
```

---

### Task 4: Health check + walk auto-heal (fail-closed) in mutating paths

Wire detection and inline recovery into every backing-reading mutating path. This is the core integration and the highest-risk task; the ordering versus `_consolidateRotatedStake` is load-bearing.

**Files:**
- Modify: `src/AlphaVault.sol`
- Test: `test/HotkeySwapHeal.t.sol`

**Interfaces:**
- Consumes: `HotkeyLineage.walk`, `_slots`, `_ratchetTracked`, `_consolidateRotatedStake`, `_coldkeyOf`, `WALK_BOUND`.
- Produces: internal `_reconcileSlots(tokenId, clone, coldkey, currentSet, alphaPriceE18)`; event `SlotAutoHealed(uint16 indexed netuid, uint8 indexed slotIdx, bytes32 oldHotkey, bytes32 newHotkey)`; error `SlotBroken(uint16 netuid, uint8 slotIdx, bytes32 lastVisited)`.

- [ ] **Step 1: Write `_reconcileSlots`** and call it at the top of the mutating paths, replacing the bare `_consolidateRotatedStake` call in `wrap` (line ~230), `_unwrapFromLiveSubnet` (~395), `rebalance` (~518), and adding it to `unwrapForTao`'s live branch (which today skips consolidation). Ordering, per slot:

```
for each slot i with a non-zero hotkey:
    observed := getStake(slot.hotkey, coldkey, netuid)
    if observed >= slot.tracked:
        _ratchetTracked(i, observed)          // healthy; absorb emissions
        continue
    // miss: try to follow the stake to a successor
    (healed, next) := HotkeyLineage.walk(staking, slot.hotkey, netuid, coldkey, slot.tracked, WALK_BOUND)
    if healed:
        emit SlotAutoHealed(netuid, i, slot.hotkey, next)
        slot.hotkey := next                   // tracked carries; stake proven >= tracked at `next`
        continue
    revert SlotBroken(netuid, i, slot.hotkey) // fail-closed: never price off an undercount
then:
    _consolidateRotatedStake(...)             // authorized rotations, now against healed hotkeys
    refresh slot.tracked from post-consolidation getStake
```

Heal-before-consolidate is required: if the attesters also rotated the slot in the same window, the stake must first be followed to where the chain parked it, then rolled onto the current set.

- [ ] **Step 2: Keep views honest.** `totalStake`, `sharePrice`, `previewWrap`, `previewUnwrap` must NOT call `walk` or mutate slots. They report the recorded position (`_unionStake` over `_slotHotkeys`), so an off-chain reader sees the same broken state the mutating path enforces. Add a `isSlotHealthy(tokenId, slotIdx) view returns (bool)` helper for off-chain monitors.

- [ ] **Step 3: Respect dissolution.** `_reconcileSlots` runs only on the live path. Dissolving subnets legitimately read zero backing; the existing `_requireNotDissolving` / dissolved-path branches must bypass the health check (guard at the call sites, not inside `_reconcileSlots`).

- [ ] **Step 4: Add tests** (`test/HotkeySwapHeal.t.sol`). Use `MockStaking` to move the vault's stake from hotkey1 to a successor and set the successor edge, simulating a chain swap:
  - `test_AutoHeal_OneHopOnWrap` — swap hotkey1→hotkeyB before a wrap; assert `SlotAutoHealed` emitted (`vm.expectEmit` with the exact event), slot 0 hotkey is hotkeyB, and shares minted match the true (not undercounted) backing.
  - `testFuzz_AutoHeal_WithinBound` — `hops = bound(raw, 1, WALK_BOUND)`; build the chain, assert heal and correct pricing.
  - `test_AutoHeal_MidChainKeepStake` — chain A→B→C with stake parked at B; assert heal lands on B.
  - `test_RevertWhen_WalkDeadEnds` — swap with no successor edge; assert `SlotBroken(netuid, 0, hotkey1)` on wrap AND on unwrap AND on unwrapForTao (fail-closed everywhere).
  - `test_KeepStakeSwap_IsNonEvent` — a rename that leaves stake under the recorded hotkey (`getStake >= tracked`): no walk, no event, op proceeds.
  - `test_Views_ReportBrokenStateHonestly` — on a broken slot, `sharePrice`/`totalStake` reflect the undercount and do not auto-heal; `isSlotHealthy` returns false.
  - `test_HealBeforeConsolidate_BothInSameWindow` — stake swapped A→B and attesters rotated slot to hotkey4: assert stake is first followed to B, then consolidated onto hotkey4, and NAV is whole.
  - `test_Dissolving_SkipsHealthCheck` — a dissolving subnet with zero backing does not revert `SlotBroken`.

- [ ] **Step 5: Run** `forge test --match-path test/HotkeySwapHeal.t.sol -vvv` then `forge test`. Expected: PASS.

- [ ] **Step 6: Workflow + commit.**

```bash
git add src/AlphaVault.sol test/HotkeySwapHeal.t.sol
git commit -m "feat(vault): fail-closed health check and inline auto-heal"
```

---

### Task 5: `heal()` permissionless ladder (rung 1 + rung 2)

Recover slots whose chain is longer than `WALK_BOUND`, or that were swapped on a netuid where the validator was not a member (no successor edge there). Permissionless; safety comes from unforgeable hotkey lineage, not from the candidate-holds-stake precondition.

**Files:**
- Modify: `src/AlphaVault.sol`
- Test: `test/HotkeySwapHeal.t.sol`

**Interfaces:**
- Consumes: `HotkeyLineage.sameRoot`, `HotkeyLineage.successorLeadsTo`, `_slots`, `_coldkeyOf`.
- Produces: `function heal(uint256 netuid, uint8 slotIdx, bytes32 candidate, uint16 evidenceNetuid) external`; event `SlotHealed(uint16 indexed netuid, uint8 indexed slotIdx, bytes32 oldHotkey, bytes32 newHotkey)`; errors `SlotHealthy()`, `CandidateLacksStake()`, `CandidateInAnotherSlot()`, `NoLineageEvidence()`.

- [ ] **Step 1: Implement `heal()`**:

```solidity
function heal(uint256 netuid, uint8 slotIdx, bytes32 candidate, uint16 evidenceNetuid) external nonReentrant {
    uint256 tokenId = currentTokenId(netuid);
    _requireNotDissolving(uint16(netuid));
    Slot storage s = _slots[tokenId][slotIdx];
    bytes32 coldkey = _coldkeyOf(subnetClone[tokenId]);
    uint16 nid = uint16(netuid);
    IStaking staking = IStaking(STAKING_PRECOMPILE);

    if (staking.getStake(s.hotkey, coldkey, netuid) >= s.tracked) revert SlotHealthy();
    if (staking.getStake(candidate, coldkey, netuid) < s.tracked) revert CandidateLacksStake();
    _requireNotInAnySlot(tokenId, slotIdx, candidate);

    bool ok = HotkeyLineage.sameRoot(staking, candidate, s.hotkey, nid)          // rung 1
        || HotkeyLineage.successorLeadsTo(staking, s.hotkey, candidate, evidenceNetuid); // rung 2
    if (!ok) revert NoLineageEvidence();

    emit SlotHealed(nid, slotIdx, s.hotkey, candidate);
    s.hotkey = candidate; // tracked carries; candidate proven to hold >= tracked
}
```

Note (comment in code, one line): the candidate-holds-stake check is a liveness gate, not a trust gate — anyone can park stake under the vault's coldkey, so the lineage rungs are what authorize the repoint.

- [ ] **Step 2: Implement `_requireNotInAnySlot`** — reverts `CandidateInAnotherSlot` if `candidate` equals any other slot's hotkey on this tokenId. Prevents one slot from shadowing another.

- [ ] **Step 3: Add tests** (`test/HotkeySwapHeal.t.sol`):
  - `test_Heal_Rung1_SameRoot` — chain longer than `WALK_BOUND`; `heal` with `sameRoot` evidence repoints and emits `SlotHealed`.
  - `test_Heal_Rung1_AbsentFoldsBothSides` — recorded hotkey is its own root (absent), candidate rooted at it; heal succeeds.
  - `test_Heal_Rung2_EvidenceNetuid` — no successor on `netuid`, successor edge present on `evidenceNetuid`; heal succeeds.
  - `test_Heal_ForkPicksFundedBranch` — A→B and A→C share a root; stake under C; `heal(candidate=C)` succeeds, `heal(candidate=B)` reverts `CandidateLacksStake`.
  - `test_RevertWhen_Heal_SlotHealthy` — recorded hotkey still holds `>= tracked`.
  - `test_RevertWhen_Heal_CandidateLacksStake`.
  - `test_RevertWhen_Heal_CandidateInAnotherSlot`.
  - `test_RevertWhen_Heal_NoLineageEvidence` — candidate holds stake but has no lineage link (the stranger case) reverts; recovery is left to attester re-attestation.
  - `test_Heal_Rung2_PerSubnetConfusable_RevertsSlotHealthy` — a per-subnet rename on `evidenceNetuid` that moved nothing on `netuid`: the slot is still healthy on `netuid`, so `heal` reverts `SlotHealthy` (cannot be abused to repoint an intact position).

- [ ] **Step 4: Run** `forge test --match-path test/HotkeySwapHeal.t.sol -vvv`. Expected: PASS.

- [ ] **Step 5: Workflow + commit.**

```bash
git add src/AlphaVault.sol test/HotkeySwapHeal.t.sol
git commit -m "feat(vault): permissionless heal via hotkey-lineage evidence"
```

---

### Task 6: Invariants, gas, and docs

**Files:**
- Create: `test/HotkeySwapHeal.invariant.t.sol`
- Modify: `test/AlphaVault.gas.t.sol`, `.gas-snapshot`
- Modify: `docs/` (the relevant edge-case/security doc), `hotkeyswapfix.md`

**Interfaces:**
- Consumes: all of the above.

- [ ] **Step 1: Write invariants** with a handler that randomly wraps, unwraps, rebalances, simulates emissions, simulates chain swaps (move stake + set successor edge), and calls `heal`:
  - `invariant_HealNeverFiresOnHealthySlot` — no `SlotHealed`/`SlotAutoHealed` when the recorded hotkey held `>= tracked`.
  - `invariant_BackingNeverDropsViaHeal` — the sum of `getStake` over slot hotkeys after any auto-heal/heal is `>=` the pre-op `tracked` sum (heals only follow stake, never shed it).
  - `invariant_NoTwoSlotsShareHotkey` — slot hotkeys on a tokenId stay distinct.
  - `invariant_SharePriceNeverMintsFromUndercount` — a wrap either reverts `SlotBroken` or prices off complete backing (no path mints against a detected undercount).

- [ ] **Step 2: Add gas cases** to `test/AlphaVault.gas.t.sol`: healthy `wrap` (per-slot health check on already-fetched data) and a one-hop auto-heal `wrap`. Regenerate the snapshot:

```bash
forge snapshot --snap .gas-snapshot --threads 4
```

- [ ] **Step 3: Update docs.** Correct `hotkeyswapfix.md`: mark F15 as monotonicity-only (a third party can `transfer_stake` under the vault coldkey, so the candidate-holds-stake check is a liveness gate); record that rung 3 / owner-coldkey / the distinct-owner-root invariant / the uid rung were dropped, that only two precompile getters are used, and that the no-evidence fallback is attester re-attestation (the ownerless vault has no timelock). Add a brief section to the shipping edge-case doc describing detection, auto-heal, `heal()`, and the fail-closed guarantee in plain language (no chain-internal names).

- [ ] **Step 4: Run** `forge test` (full suite incl. invariants), `forge coverage`. Expected: PASS; report changed-line coverage and flag any uncovered branch with justification.

- [ ] **Step 5: Workflow + commit.**

```bash
git add test/HotkeySwapHeal.invariant.t.sol test/AlphaVault.gas.t.sol .gas-snapshot hotkeyswapfix.md docs
git commit -m "test(vault): self-heal invariants, gas snapshot, and docs"
```

---

### Task 7: Spec-444 localnet e2e (expected red until localnet exists)

Accepted per scope: these are written now and run when a locally-built `release-444` node is available; they are not part of the green CI gate until then.

**Files:**
- Create: `script/e2e/HotkeySwapHeal.e2e.*` (following the existing localnet runbook / `scripts/localnet.sh`).

- [ ] **Step 1: Scenario A — auto-heal.** Deploy vault + registry on a 444 localnet, deposit and wrap, execute a real full `swap_hotkey` on the validator, then a `wrap`/`rebalance` and assert `SlotAutoHealed` and whole NAV.
- [ ] **Step 2: Scenario B — no-evidence fallback.** Deregister the validator everywhere, execute a real swap (no lineage recorded), assert the vault op reverts `SlotBroken`, then submit a threshold-signed attestation adding the new hotkey and assert the vault adopts it (authorized rotation) and prices correctly.
- [ ] **Step 3: Pin gas** from the localnet run into the `hotkeyswapfix.md` §6 table (replace the estimates).
- [ ] **Step 4: Commit** the scripts; document in the runbook that green requires a 444 node.

```bash
git add script/e2e docs
git commit -m "test(e2e): spec-444 localnet self-heal scenarios"
```

---

## Self-Review

**Spec coverage** (against `hotkeyswapfix.md`, as amended by the scope decisions):
- Detection via `tracked` high-water — Task 3 (accounting) + Task 4 (check). ✓
- Health check fail-closed in all mutating paths incl. `unwrapForTao` — Task 4. ✓
- Bounded walk + inline auto-heal, stake checked every hop — Task 2 (lib) + Task 4 (integration). ✓
- `heal()` rung 1 (same-netuid root) + rung 2 (cross-netuid evidence), fork picks funded branch, per-subnet-confusable excluded by the healthy precondition — Task 5. ✓
- Views report broken state honestly — Task 4 Step 2. ✓
- Dropped by scope, explicitly: rung 3 / owner coldkey, distinct-owner-root invariant, uid rung, in-vault rung-4 timelock, settable `healTolerance`. Documented — Task 6 Step 3. ✓
- F15 correction (candidate check is a liveness gate; lineage rungs are the trust gate) — encoded in Task 5 and documented in Task 6. ✓
- Invariants + gas + e2e — Tasks 6, 7. ✓

**Placeholder scan:** each code step carries real signatures/logic; each test step names concrete tests and their assertions. No "add error handling"/"similar to Task N"/"TBD".

**Type consistency:** `Slot{bytes32 hotkey; uint128 tracked}`, `_slots[tokenId][slotIdx]`, `walk(...)` returning `(bool, bytes32)`, `heal(uint256,uint8,bytes32,uint16)`, events `SlotAutoHealed`/`SlotHealed`, errors `SlotBroken`/`SlotHealthy`/`CandidateLacksStake`/`CandidateInAnotherSlot`/`NoLineageEvidence`/`TrackedOverflow` are used identically across Tasks 3–6.

**Open items to confirm during execution (not blockers):**
1. Whether `_reconcileSlots` should ratchet `tracked` up on emissions inside views is deliberately NO (views never mutate); confirm no test relies on view-side ratcheting.
2. Gas: the healthy hot path must add only a comparison when NAV already reads the slot's `getStake`; if a path fetches `getStake` twice, dedupe in Task 4.
3. `WALK_BOUND = 3` is retained from the design; revisit only if a gas case shows the dead-end waste matters.

---

## Value note (per repo policy)

The mechanism closes a real but narrow window: between a `swap_hotkey` and the attesters re-attesting, the vault today undercounts backing and mis-prices (`wrap` over-mints, `unwrap`/`unwrapForTao` underpay). This adds on-chain detection (`tracked`) that fails closed and on-chain recovery (walk + lineage `heal`) that does not trust the attesters for safety — the attester path remains only as the no-evidence fallback. It is inert on the live chain until the two 444 getters ship, and it does not add any privileged role to the ownerless vault.
