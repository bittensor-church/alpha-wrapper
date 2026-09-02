# Response to the kimi audit

Reviewed against `main` at `1f64bb2`. Every cited line was re-read in the current source; the
subtensor runtime, precompiles and the vendored EVM crate were consulted where the finding
depends on chain behavior.

Summary:

| ID | Audit severity | Our verdict | Action |
|----|----------------|-------------|--------|
| H1 | High | Valid, fixed | `wrap(netuid, hotkey, minSharesOut)` shipped in #57 |
| H2 | High | Valid as a design tradeoff, documented | NatSpec + user guide + security model in #58 |
| M3 | Medium | Not a vulnerability | None |
| M4 | Medium | Not a vulnerability | None |
| M5 | Medium | Not a vulnerability | None |
| L6 | Low | Incorrect premise | None |
| L7 | Low | Accepted | None |
| L8 | Low/Info | Intentional | None |
| U1 | Note | The audit's correction is itself wrong | Keep the `IAlpha` comment as is |

---

## H1 - `wrap` share-price manipulation via AMM slippage

**Status: fixed in #57 (`6013f08`).** The fix adds a `minSharesOut` parameter to `wrap` and reverts `SlippageExceeded` when the settled rate would mint fewer shares, so a sandwich can only make the deposit fail, never under-price it.

`wrap` now takes `minSharesOut` and reverts `SlippageExceeded(shares)` when the mint falls short
of it. The lens quotes the expected mint, the caller passes a floor, and a sandwich that deflates
the pre-deposit stake reading can no longer force an under-priced mint. Tests cover the exact
boundary (mint equal to the floor succeeds, one share fewer reverts) and the e2e suite passes the
floor on every wrap. The user guide documents the parameter.

## H2 - `unwrapForTao` exit sells move the pool; stayers absorb the price impact

**Status: accepted design asymmetry, documented in #58 (`6c83528`).** The change rewrites the `unwrapForTao` NatSpec and the user guide, edge-cases and security-model docs to present it as the opt-in risk-on exit and `unwrap` as the default.

The mechanism is real: the two sell rounds trade against the subnet's constant-product AMM, the
proceeds go to the withdrawer, and the depressed price stays with remaining holders. This is the
same externality every on-chain unstake has, and it cannot be removed from a rail whose purpose is
to convert alpha to TAO. The vault's mitigation is to make the rail opt-in rather than default:

- `unwrap` is the default exit. It moves the caller's alpha to their own coldkey with no pool
  interaction, so it imposes nothing on stayers.
- `unwrapForTao` is marked risk-on in NatSpec, the user guide and the security model, reserved for
  the two cases `unwrap` cannot serve: the subnet owner disabled alpha transfers, or the position
  is below the chain's floor.

With H1 closed, the composite chain the audit describes (enter under-priced, exit via the TAO rail)
is broken at its entry.

---

## M3 - `recoverStray` / `syncBacking` griefing keeps `BackingShortfall` frozen

**Verdict: not a vulnerability. The premise ("partial recovery resets the clock") is false.**

The finding claims that `recoverStray` can partially recover a slot, clear `shortSince`, and
re-anchor `tracked` upward in a way that re-triggers the shortfall and keeps the rails frozen.
The code does not allow a partial recovery:

1. `_chooseRecoverySlot` reverts `RecoveryIncomplete` unless the source amount plus what the slot
   already holds covers `tracked`. A source that covers none of the loss is refused before any
   alpha moves.
2. After the move, `recoverStray` re-reads the target key and reverts `RecoveryIncomplete` again
   unless `coversTracked(recovered, slot.tracked)` holds. The clock is cleared only in the branch
   where the slot has been proven whole.
3. `slot.tracked = recovered` anchors the expectation to the balance just read from chain. A slot
   whose balance equals its expectation is by definition not short, so the re-anchor cannot
   re-trigger a shortfall. Only a new, independent loss can.

Every other writer of `shortSince` is equally constrained. `syncBacking` never clears the clock
while `resolveBacking` still reports the slot short; the test
`test_SyncBacking_CannotPushTheDeadlineOut` pins this. `_settle` and `_reanchor` run only behind
`_openBacking`, which calls `requireIntact` and reverts `BackingShortfall` before either can
execute.

To extend a freeze an attacker would have to remove alpha from the subnet clone's own coldkey.
Only the clone can do that. The one action an outsider has is to transfer alpha *into* the clone's
coldkey, and that ends a shortfall rather than prolonging it, at the outsider's own expense.

**Worst case:** a genuine chain-side loss the lineage cannot explain freezes `wrap`, `unwrap` and
`rebalance` on that token for one recovery window (3 hours by default in the deploy script). After
that anyone calls `syncBacking` and the loss is written off. This is the intended fail-closed
behavior, and the loss itself was caused by the chain, not by the freeze. No holder funds are at
risk from the freeze.

## M4 - Rounding floors accumulate on the dissolved path; final holder stranded

**Verdict: not a vulnerability. The last holder's division is exact.**

`proRata(total, shares, supply)` floors, so each exit takes at most its exact share and the pot is
never over-drawn. The remaining holders' shares grow by the flooring dust, not shrink. The final
holder calls with `shares == supply`, which makes `total * supply / supply` exact: they receive
the entire remaining pot, dust included. The fuzz test
`testFuzz_DissolvedUnwrapConservesRefundPot` asserts the clone ends at zero balance and zero supply
after the last exit.

The only rounding the vault cannot capture is the native transfer itself: the runtime represents
TAO with 9 decimals behind the 18-decimal EVM interface and truncates a value transfer to whole
RAO. That leaves under 1 RAO in the clone after the last exit, plus each fully exited holder's
sub-RAO claim remainder, which stays reserved in `taoLiability`.

**Worst case:** below 1e-9 TAO per dissolved token, plus below 1e-9 TAO per holder who ever
claimed. Not recoverable, not meaningful. A sweep for this residue would cost more in bytecode
than it could ever return.

## M5 - `syncAmounts` ceil-rounding of `liabilityIncrease` over-reserves

**Verdict: not a vulnerability. The ceiling is bounded by the arrival.**

`indexIncrease` is floored first: `indexIncrease = floor(newTao * 1e36 / supply)`, so
`indexIncrease * supply <= newTao * 1e36`. Dividing that product back down and rounding up gives
`liabilityIncrease <= newTao`. The reservation can never exceed the TAO that arrived, which is
what the NatSpec on `syncAmounts` states and what the fuzz test
`testFuzz_SyncAmounts_LiabilityTracksTheIndex` asserts.

Measured against what holders can actually claim, the liability can sit above the sum of their
floored entitlements by under 1 wei per synchronization. That wei stays in the clone and is
excluded from the dissolved pot. The ceiling exists precisely so that a floored-to-zero
allocation cannot leave the same arrival re-countable on the next sync, which would be a real
solvency bug.

**Worst case:** 1 wei of TAO (1e-18) locked per synchronization. A million synchronizations strand
1e-12 TAO.

---

## L6 - Floor-check band causes gas-burning reverts

**Verdict: incorrect premise. The band runs the other way.**

`_isBelowFloorAtReadPrice` values the amount at a price rounded *down* to the 1e9 quantum. An
amount that passes this check has TAO value at or above the floor at the read price, and therefore
at or above the floor at the true (higher or equal) price. The chain accepts it. The pre-check can
only refuse what the chain would have taken, never let through what the chain would refuse. The
NatSpec on the function says exactly this.

`_isBelowFloorAtAnyPrice` is the opposite tool: it rejects only when the amount cannot clear the
floor even at the highest price the rounded read could hide. It gates paths where a wrongful
refusal would be worse than a wasted attempt (`recoverStray`, rotated-stake consolidation,
delivery-slot selection), so those paths fall through to the chain when the read is inconclusive.

For the unstake rail the chain does not validate against spot at all but against the simulated
post-fee, post-slippage output, which is why `_sellableChunk` calls `simSwapAlphaForTao` after the
spot pre-check rather than relying on the pre-check alone.

**Action:** none.

## L7 - `syncBacking` uses `block.timestamp`

**Verdict: accepted.**

The window is hours, block time is 12 seconds, and a block producer's timestamp drift is seconds.
Nothing a producer can do moves a write-off by a meaningful amount, and the fuzz test
`testFuzz_WriteOff_FallsDueOnlyOnceTheWindowIsOut` pins the deadline boundary. Block numbers would
make the window depend on block-time assumptions instead, which is worse for an operator setting
it in seconds.

**Action:** none.

## L8 - Attestation nonce is per-netuid and strictly `+1`

**Verdict: intentional.**

Races between attesters on the same subnet are resolved by whichever attestation lands first; the
loser re-signs against the new nonce. Cross-netuid replay is impossible because the nonce is keyed
by netuid and the netuid is part of the signed digest. The NatSpec on `_validateNonce` explains why
the stored set can never rewind.

**Action:** none.

---

## U1 - "`simSwapAlphaForTao` rejection is a bounded revert, not OOG"

**Verdict: the audit's correction is wrong. The `IAlpha` comment stands.**

The audit reads `PrecompileFailure::Error(Other(...))` as "a normal revert" and concludes the
`IAlpha.sol` note that a rejected simulation "consumes all forwarded gas" is misleading. That is
not how the EVM executor treats it. In the vendored `evm` crate the stack executor maps
`PrecompileFailure::Error` to `ExitReason::Error` and exits the substate with `StackExitKind::Failed`,
which calls `swallow_discard`. `swallow_discard` returns nothing to the parent gasometer, so the
entire gas forwarded to the call is consumed. Only `PrecompileFailure::Revert` goes through
`swallow_revert`, which refunds the remaining gas. Every state-changing subtensor precompile and
the alpha simulation return `Error`, not `Revert`.

The audit is right that for the main AMM mechanism `sim_swap` rolls back instead of erroring on a
priced failure, so the simulation rarely rejects on a live subnet. The vault still keeps the
simulation off inputs it cannot price because the failure mode when it does reject is all-gas,
exactly as the comment says.

**Action:** none. The comment is accurate and should be kept.
