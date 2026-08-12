# Dynamic validator set (1..64) — design

The registry stored three validator slots per subnet. It now stores a list of one
to sixty-four, and the vault stakes across whatever length it finds.

**Three validators stays the expected size.** Sixty-four is the ceiling the
contract has to survive, not the case to tune for.

## What the change is

Almost entirely arity. Fixed arrays become dynamic, `i < 3` and `i < 6` become
`i < length`, and the union of remembered and current validators is sized and
trimmed rather than padded to six. The consolidation roll, the weight alignment
and the floor rules are the ones that were already there — none of them needed a
new mechanism to work at a larger size.

Two things fall out of the arity change rather than being decided:

- A set can no longer carry trailing zero slots, so the "first zero weight ends
  the set" convention disappears, along with the zero-hotkey guards that existed
  to skip padding. A subnet is configured iff its set is non-empty.
- `getCurrentValidators` and `lastSeenHotkeys` return `bytes32[]`. **This is an
  ABI break** for anything decoding them as `bytes32[3]`.

## Why 64

`MAX_VALIDATORS = 64` is a policy cap, and the vault has no structural dependency
on it — every loop is bounded by the array it walks. 64 is chosen because it is
the widest set the staking precompile's batched read
(`getStakeInfoForColdkeyAndNetuid`, `MAX_STAKE_INFO_HOTKEYS = 64`) will price in
one call, so it stays the natural ceiling if that read is ever adopted here.

It is not adopted here. One `getStake` per validator costs about 10% more of
chain-charged gas than the batched form at 64 validators, and nothing at three.
That did not justify a second read path, a mock that has to mirror four
load-bearing chain behaviours, and a localnet probe to prove the mock honest.

## What the cap costs

Measured with `forge` against mocks, so these price the vault's own work — the
mock understates every `moveStake`, which on chain is a staking extrinsic rather
than one `SSTORE`. The localnet run is the authority on chain-side cost.

| path | 3 validators | 64 validators | before |
| --- | ---: | ---: | ---: |
| wrap: first | 525,195 | 6,372,303 | 495,823 |
| wrap: subsequent | 279,745 | 4,181,258 | 268,544 |
| unwrap: partial | 210,288 | 3,051,627 | 198,414 |
| unwrap: full | 165,846 | 1,531,766 | 154,571 |
| unwrapForTao: full | — | 1,857,492 | — |
| unwrapForTao: fully rotated | — | 2,528,472 | — |
| previewUnwrap | 62,618 | 930,792 | — |
| rebalance | 137,568 | — | 126,431 |

The widest case is a first wrap at 6.37M, under 9% of a 75M block. The widest
*rotation* case — a full 64-to-64 swap, where the remembered and current sets are
both at the cap and the position is sold through the TAO rail across 128 slots —
is 2.53M.

At three validators the priced paths cost 4-9% more than before. That is what
reading a length instead of a constant costs: two array-length reads on the
registry side and dynamic-array encoding where fixed arrays decoded inline.

## Chain facts worth not re-deriving

- Gas per db read is **625** (`RocksDbWeight` 25,000,000 ref_time ÷ `WeightPerGas`
  40,000). The mainnet-measured 4,952 for `getStake` is 7 × 625 = 4,375 of reads
  plus ~577 fixed per-call overhead. Dividing 4,952 by 7 to get "707 per read"
  folds the fixed cost into the marginal rate and inflates every estimate.
- `getTotalColdkeyStakeOnSubnet` looks like an O(1) replacement for summing
  balances. It is not usable: it returns a TAO-denominated value via `sim_swap`,
  which makes share pricing an oracle-manipulation surface. Do not revisit it.
- A same-subnet move can credit the destination a RAO short. Any hop that moves a
  pile must size it from a live read, never from a running total — asking a
  hotkey for more than it holds is refused outright, and a rejected dispatch
  burns all forwarded gas rather than reverting cleanly.

## Known consequences of the larger cap

- **`ConsolidationBelowFloor` binds over a wider band.** The roll refuses when the
  richest slot across the union provably cannot clear the chain's stake floor.
  Spreading a position across 64 validators makes each slot smaller, so positions
  up to roughly 64× the floor can now hit this where only positions near 1× could
  before. Such positions still exit via `unwrapForTao`, which is floor-exempt on
  full balances. This is `main`'s behaviour at a wider setting, not a new rule.
- **A full 64-validator commit costs ~1.36M.** `_commit` replaces the stored set
  rather than diffing it, so a weights-only re-attestation pays for rewriting
  every hotkey slot. That also bounds `updateValidatorsBatch` at roughly 50
  subnets per transaction. Keepers size their own batches.
- **`tao20-contract` breaks silently.** `BuybackTreasury` decodes
  `getCurrentValidators` into a `bytes32[3]` inside a `try`. The dynamic return
  decodes into that static array *without* reverting, so the `catch` never fires
  and the first two "hotkeys" it reads are the ABI offset and length words.
  `lastSeenHotkeys` has the same break. Both need the dynamic type before this
  ships anywhere tao20 points at.
- **The localnet run has never driven a wide set.** `e2e/` still bootstraps three
  validators per subnet, so the chain-side cost of a rotation at the cap — where
  the roll chains a pile through up to 64 hops — is unmeasured.
