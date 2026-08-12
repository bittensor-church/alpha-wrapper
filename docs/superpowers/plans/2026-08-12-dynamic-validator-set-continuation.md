# Dynamic validator set (1..64) — outcome

Branch `pg/dynamic-validator-set`, branched from `main` @ `c6533a5`. Design and
rationale live in `docs/superpowers/specs/2026-08-12-dynamic-validator-set-design.md`;
this file records what shipped and what is left for someone else.

## State

- `forge build` — clean, no warnings.
- `forge fmt` — applied.
- `forge test` — **376 passing, 0 failing.**
- `forge coverage` — `ValidatorRegistry.sol` 100% on lines, statements, branches
  and functions; `AlphaVault.sol` 99.02% lines / 98.11% branches. The handful of
  lines reported uncovered sit inside paths several tests exercise and are
  artifacts of the `--ir-minimum` source mapping coverage needs on this contract.

## What shipped

`ValidatorRegistry` stores a dynamic 1..64 validator set per subnet instead of a
fixed 3, and `AlphaVault` stakes across all of it. **Three validators remains the
expected set size** — 64 is the ceiling the contract must survive, not the case
to tune for.

- Registry: `MAX_VALIDATORS = 64`, dynamic `bytes32[]`/`uint16[]`, `delete`+push
  commit, `getValidators` returns `(hotkeys, weights, version)`. The version is
  `nonces[netuid]`, already monotonic per commit — no new registry storage.
- Vault: batched balance reads chunked at the chain's 64-per-call bound; a
  set-version fast path that skips all history reads when membership has not
  moved; a drain that empties dropped validators with whole-balance moves;
  unified target-zero alignment; union reads on views and on `unwrapForTao`.
- Every whole-balance move is sized by a live read. This is load-bearing: the
  chain credits same-subnet moves a RAO short, so a second move sized from the
  vault's running total over-asks and is refused, which would take `wrap`,
  `unwrap` and `rebalance` down together for that position.

## Decisions worth not relitigating

- **Unmovable dust is left in place, not reverted.** A dropped validator holding
  less than the chain's floor keeps its alpha, stays remembered, and stays in the
  reported backing until a later deposit can carry it off. Reverting instead
  would let a few RAO wedge every deposit and withdrawal on that position.
  `ConsolidationBelowFloor` was removed with the behaviour.
- **The drain is a separate move class from alignment, deliberately.** Alignment
  moves `min(surplus, deficit)`; spreading a dropped validator's balance over the
  remaining set puts every individual deficit below the floor, so alignment would
  skip every move and strand many times the floor on a validator the set no
  longer names. The two also differ on floor policy, zero-price policy and
  whether they emit. `test_Rebalance_DrainsDroppedBalanceTooSmallToSpread` pins
  the failure boundary.
- **The remembered set is never capped.** Forgetting a dropped validator that
  still holds alpha would drop that alpha out of the backing every view reports
  and out of every settlement path. A bound would only be safe alongside a
  permissionless per-slot recovery, which does not exist.
- **Views must read the union.** The registry commits outside the vault, so
  between a commit and the next vault call the whole position sits on validators
  the set no longer names; a current-set-only view would report zero backing.

## Left for someone else

- **`tao20-contract` does not compile against this ABI, and fails silently.**
  `BuybackTreasury` decodes `getCurrentValidators` into a `bytes32[3]` inside a
  `try`. The dynamic return decodes into that static array without reverting, so
  the `catch` never fires and the first two "hotkeys" it reads are the ABI offset
  and length words. `lastSeenHotkeys` has the same break. Both need the dynamic
  type before this ships anywhere tao20 points at.
- **`updateValidatorsBatch` has no batch-size cap.** A full 64-validator commit
  costs ~1.36M, so a batch approaches the block limit near ~50 subnets. Keepers
  size their own batches; the ceiling is documented in the design spec §3.3.
- **A weights-only re-attestation rewrites every hotkey slot.** `_commit` is
  `delete`+push, so re-attesting the same 64 members at new weights pays ~64
  slot rewrites where a diff-write would pay reads. This is a keeper cost on the
  commonest commit; the design locked `delete`+push for simplicity, and changing
  it is a real gas/readability tradeoff for the repo owner to call.
- **`getDefaultMinStake()` is re-read per floor check.** One call per executed
  move, where one per transaction would do. Threading the value through ~6
  signatures is worth roughly 44k EVM plus 75k chain-charged gas at 64
  validators, and nothing at three.
- **The localnet run has never exercised a wide set.** `e2e/` still bootstraps
  three validators per subnet. The batched read now has a probe
  (`e2e/tests/test_batched_stake_read.py`), but no scenario drives a rotation at
  the 64 ceiling, and the chain-side cost of 63 `moveStake` dispatches is
  unmeasured — the gas snapshots are EVM-side against mocks and understate it.
