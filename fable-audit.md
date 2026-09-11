# 🔐 Security Review — alpha-wrapper

---

## Scope

|                                  |                                                                                                          |
| -------------------------------- | -------------------------------------------------------------------------------------------------------- |
| **Mode**                         | default (all in-scope `src/`)                                                                              |
| **Files reviewed**               | `AlphaVault.sol` · `AlphaVaultLens.sol` · `CloneBase.sol`<br>`DepositMailbox.sol` · `SubnetClone.sol` · `ValidatorRegistry.sol`<br>`VaultErrors.sol` · `libraries/VaultMath.sol` · `libraries/VaultReads.sol` |
| **Confidence threshold (1-100)** | 80                                                                                                         |
| **Severity breakdown**           | Critical 0 · High 3 · Medium 4 · Low 4                                                                      |

Reviewed on `main` at `66a3f6e`. Twelve specialist agents ran sequentially: math-precision, access-control, economic-security, execution-trace, invariant, periphery, first-principles, asymmetry, boundary, and the numerical, trust and flow gap-hunters. Tests, docs, `src/interfaces/` and the local Subtensor source were read as context only; no worktree was opened and no file in the repository was modified.

Result: **no Critical, 3 High, 4 Medium, 4 Low**, plus 21 leads.

Severity and confidence answer different questions. Confidence is how certain the finding is real; severity is how much it costs if it is. Finding 1 is the most certain and only Medium; finding 5 is the most costly and one point less certain.

Raw agent output: 15 findings and 45 leads across 29 unique contract/function pairs. All 29 are adjudicated below.

---

## Findings

[90] **1. Full-supply `unwrapForTao` reverts once the position has appreciated**

`AlphaVault.unwrapForTao` · Severity: Medium · Confidence: 90

**Description**
On a full burn the `assets = total` override zeroes both operands of the refund's share price, so the refund mints at the fixed `1e9` virtual ratio rather than the vault's live rate; once backing has grown past that ratio, a short fill makes `refundShares` exceed `shares` and the event's `shares - refundShares` underflows, reverting the exit the docs promise is always available.

The trigger is exact: `refundShares = unsold * 1e9`, so the emit underflows whenever `unsold > totalSupply / 1e9`. Since the first wrap mints `supply = D * 1e9`, that threshold is the position's alpha cost basis — any staking dividend, donation or recovery windfall opens the window. At 2x appreciation it fires on any unsold remainder above 50%, at 10x above 10%. Two agents reached this independently; one supplied a repro that is the shipped test `test_SwapStoppedShortOnFullBurn_RefundsTheReturnedAlpha` with `_setVaultStakes(NETUID1, 100 ether, 0, 0)` changed to `300 ether`. The partial-burn path is provably safe, which is why the existing suite passes.

This matters most where it is least recoverable: the full-supply burn is the floor-exempt rail for a sub-floor position, and on a subnet whose owner has disabled alpha transfers it is the only exit at all.

**Fix**

```diff
-        emit UnwrappedForTao(msg.sender, tokenId, shares - refundShares, sold, taoOut);
+        emit UnwrappedForTao(
+            msg.sender, tokenId, refundShares < shares ? shares - refundShares : 0, sold, taoOut
+        );
```

---

[85] **2. An emptied slot re-targets a hotkey the chain has deleted**

`AlphaVault._assignActives` · Severity: Medium · Confidence: 85

**Description**
When a slot's balance reads zero, `_assignActives` discards the successor key the record resolved to and falls back to the attested name (`actives[i] = name`), but Subtensor's all-subnet `swap_hotkey` deletes `Owner(old_hotkey)` while still recording the successor edge — so the vault aims every subsequent stake move at a hotkey that no longer exists, and `validate_stake_transition` rejects it with `HotKeyAccountNotExists`. Precompile dispatch failures exit with `ExitError::Other`, consuming all forwarded gas, so `wrap`, the alpha `unwrap` and `rebalance` all revert expensively until the attesters publish a corrected set. Only the lossy AMM rail survives.

Three agents converged on this from different directions. Two reachable triggers need no attacker capital: an ordinary `unwrapForTao` that drains a slot whole, or a newly attested validator whose weight share never cleared the stake floor, leaving `tracked = 0`. Because `coversTracked(0, 0)` is trivially true, the swap-follow never runs again and the record stays pinned to the dead name. The existing `SwappedHotkeyStillAttested` guard does not fire, since it requires a non-empty slot. The test helper that simulates a followed swap never marks the old key deleted, which is why the suite misses it even though the staking mock already models the chain's revert.

A second mechanism lives in the same function: a stale `active` pointer on an emptied slot still occupies its key in `backing.keys`, so attesting that key while the old logical name is still listed reverts `SwappedHotkeyStillAttested` and shuts every rail, even though an empty slot could safely release the name.

**Fix**

```diff
                 uint256 holder = VaultMath.indexOf(backing.keys, name);
                 bool nameTaken =
                     holder != type(uint256).max && holder != at && VaultMath.contains(currentSet, logicals[holder]);
                 if (!nameTaken) {
-                    actives[i] = name;
+                    // An emptied slot must not forget a swap the chain still records: the retired
+                    // name has no owner account and cannot receive stake.
+                    bytes32 next = VaultReads.hotkeySuccessor(name, netuid);
+                    actives[i] = (next != bytes32(0) && !VaultMath.contains(backing.keys, next)) ? next : name;
                 } else if (at != type(uint256).max) {
```

---

[85] **3. A dust stake under a swapped-away key freezes the whole token**

`VaultReads._followSwap` · Severity: High · Confidence: 85

**Description**
`_followSwap` abandons the swap-follow on *any* non-zero balance at the old key (`if (balance != 0) return (false, ...)`) rather than on a balance that fails to explain the slot. Substrate lets any coldkey push stake onto an arbitrary destination coldkey — that is the very primitive `CloneBase.flush` uses, and `validate_stake_transition` checks only that both hotkeys exist, with no minimum on same-subnet transfers. So anyone can place one RAO under the old name of a per-subnet-swapped validator, whose `Owner` entry that path deliberately keeps, and convert a silent self-healing swap into `BackingShortfall` on every rail: `wrap`, `unwrap`, `unwrapForTao`, `rebalance`, and every lens quote including `totalStake`, `sharePrice`, `previewWrap` and `previewUnwrap`.

Cost to the attacker is a sub-cent transfer, permanently forfeited. Two agents found this independently. It also feeds finding 5: if no watcher recovers within the window, the freeze matures into a write-off, and the documented late-recovery attack becomes available without the dishonest-validator precondition the security model assumes.

A second refusal in the same function has the same shape: `contains(keys, successor)` marks a slot short even when the successor's balance covers both its own expectation and the swapped-in one, which the chain permits and records. That turns an unambiguous key merge into a full recovery-window blackout.

**Fix**

```diff
     ) private view returns (bool, bytes32, uint256) {
-        if (balance != 0) return (false, bytes32(0), 0);
         bytes32 successor = hotkeySuccessor(keys[index], netuid);
         if (successor == bytes32(0)) return (false, bytes32(0), 0);
         if (VaultMath.contains(keys, successor)) return (false, bytes32(0), 0);
         uint256 successorBalance = IStaking(STAKING_PRECOMPILE).getStake(successor, coldkey, netuid);
-        if (!coversTracked(successorBalance, tracked)) return (false, bytes32(0), 0);
+        // The chain moves stake entries whole, so anything left under the old name is foreign
+        // stake, not the slot's own remainder; it becomes an ordinary stray once the key is
+        // released. Only the successor has to explain the slot.
+        if (!coversTracked(successorBalance, tracked)) return (false, bytes32(0), 0);
         return (true, successor, successorBalance);
```

The `recoverStray` NatSpec claiming "only the subnet clone can stake under its own coldkey" states the false invariant this rests on and should be corrected in the same change.

---

[85] **4. A written-off position burns shares for nothing on the alpha rail**

`AlphaVault._unwrapFromLiveSubnet` · Severity: High · Confidence: 85

**Description**
After a complete write-off every slot's `tracked` is set to its located balance of zero, `coversTracked(0, 0)` passes, and the token reopens intact with its supply untouched. A holder calling `unwrap` then reaches the `totalAlpha == 0` branch, which settles, burns the caller's shares and emits a zero payout without reverting — while the alpha still exists under a key `recoverStray` can reclaim the next block, for the benefit of whoever still holds shares.

The branch's premise, that a fully swept position cannot regain alpha, does not hold for a written-off one. The two sibling paths refuse the same state: `unwrapForTao` reverts `NothingToUnwrap` and the dissolved path reverts on zero backing. Only the live path destroys the claim, and `previewUnwrap` quotes `(0, 0)` without warning. Two other agents independently reached the same zero-backing-with-live-supply state by different routes, which corroborates its reachability.

**Fix**

```diff
-        // A fully swept position cannot regain alpha, and the burn's checkpoint keeps any
-        // swept-sale proceeds claimable, so the shares are retired instead of trapped.
-        if (totalAlpha == 0) {
-            _settle(tokenId, coldkey, hotkeys, actives);
-            _burn(msg.sender, tokenId, shares);
-            emit Unwrapped(msg.sender, tokenId, shares, 0);
-            return;
-        }
+        // Backing the vault has merely stopped locating can still be recovered onto the record,
+        // so shares are never retired against it.
+        if (totalAlpha == 0) revert NothingToUnwrap();
```

`AlphaVaultLens.previewUnwrap` should revert the same way rather than quoting a zero payout.

---

[85] **5. A write-off and its later recovery can be separated by a mint**

`AlphaVault.syncBacking` / `AlphaVault.recoverStray` · Severity: High · Confidence: 85

**Description**
`syncBacking`, `wrap` and `recoverStray` are three unlinked permissionless calls, so an attacker can book a write-off, mint against the marked-down backing, and then restore the written-off alpha onto their own new shares — all as sequential top-level calls in one transaction, which the reentrancy guard does not constrain. `_chooseRecoverySlot` sets `chosen = 0` when no slot is short, so alpha reappearing after a write-off is booked as fresh backing to whoever holds shares at that moment, not to the cohort that absorbed the loss.

Worked example from the agent: four slots at 250 alpha each, one stranded by an unfollowable swap. After the write-off the attacker wraps 6750 alpha against 750 of visible backing, takes 90% of supply, recovers the 250, and redeems 6975 — a profit of 225 alpha, with the original cohort down 22.5%. Profit is `D·W/(V+D)`, approaching the full written-off amount as the deposit grows.

This is the late-recovery attack already documented in `docs/security-model.md` and accepted as a trust assumption in the prior Solidity audit, so it is reported here as still-live rather than as new. What is new is the cost of the trigger. The documented precondition is a dishonest validator re-registering an old hotkey, which needs open registration and a burn. Finding 3 reaches the same state for one RAO from any coldkey, and a validator no longer a subnet member can strand the alpha with an ordinary global swap that records no lineage edge at all and carries no cooldown, letting them re-strand each window for 0.1 TAO.

A second mechanism compounds it: recovery physically returns the alpha to a key the adversary owns, so nothing prevents the cycle repeating. The documented loss bound reads as a total but is per event.

**Fix**

```diff
     function syncBacking(uint256 tokenId) external nonReentrant {
```

Record the written-off amount and refuse `wrap` on that tokenId for one further `recoveryWindow` after `BackingWrittenOff`, so a late find can only land on the holder set that absorbed the loss. Fixing finding 3 is the cheaper half of this: it removes the permissionless trigger without changing the recovery policy.

---

[82] **6. The dissolved-subnet payout ignores the chain's native quantum**

`AlphaVault._unwrapFromDissolvedSubnet` · Severity: Low · Confidence: 82

**Description**
`userTao` is paid straight through with no rounding, but native TAO moves only in whole `1e9`-wei steps: Subtensor's balance converter truncates by integer division, so the transfer succeeds while delivering `floor(userTao / 1e9) * 1e9`. Because `taoLiability` accrues with ceiling rounding, `backing` is generically not a multiple of the quantum, so every dissolved exit forfeits its sub-RAO tail to the clone, and a holder whose whole pro-rata slice is below one RAO has their shares burned for a transfer of exactly zero. The `if (userTao > 0)` check does not catch that, since the value is non-zero in EVM units.

Five agents flagged this. It is the only native payout path in the contract without the guard; `claimTao` handles the identical hazard explicitly a hundred lines above, and the two mailbox reclaims pay balance deltas that are already quantum multiples.

**Fix**

```diff
         uint256 supplyBefore = totalSupply(tokenId);
         uint256 userTao = VaultMath.proRata(backing, shares, supplyBefore);
+        userTao = VaultMath.toNativeQuantum(userTao);
+        if (userTao == 0) revert ClaimBelowNativePrecision();
         _burn(msg.sender, tokenId, shares);
-        if (userTao > 0) SubnetClone(payable(clone)).unwrapTao(payable(msg.sender), userTao);
+        SubnetClone(payable(clone)).unwrapTao(payable(msg.sender), userTao);
         emit DissolvedSubnetUnwrapped(msg.sender, tokenId, shares, userTao);
```

---

[80] **7. The unstake minimum is applied to moves the chain never floors**

`AlphaVault._isBelowFloorAtReadPrice` / `AlphaVault._isBelowFloorAtAnyPrice` · Severity: Medium · Confidence: 80

**Description**
`_minStakeTao()` returns `getDefaultMinStake()`, and both floor helpers apply it to same-subnet `moveStake` and `transferStake` as well as to unstaking. On chain the minimum-amount check sits entirely inside `if origin_netuid != destination_netuid`, and the vault only ever issues same-subnet operations, which route to a pure ledger move with no minimum and no swap leg. Even reading the constants alone the guard is 20x stricter than the transfer minimum.

The refusals are real and user-facing: `DepositTooSmall` on wrap, `WithdrawTooSmall` on the alpha exit, `GatherBelowFloor`, `ConsolidationBelowFloor` and `RecoveryBelowFloor`, plus a silent skip in the rebalance step. The consolidation case is the sharpest: at an alpha price of `1e14`, a position whose richest single key holds under roughly 20 alpha reverts on `wrap`, `unwrap` *and* `rebalance` after any ordinary validator rotation, permanently, leaving only the AMM rail the contract's own NatSpec describes as taxing the holders who stay. `RecoveryBelowFloor` is the other cost: stray backing the chain would gladly move is refused, then written off against holders when the window lapses.

The direction is safe — the vault never permits what the chain would reject — and the substitution is acknowledged in the NatSpec. The test mock applies the same minimum unconditionally to both transfer and move with no netuid comparison, so the suite asserts a chain rule that does not exist and cannot surface this. Agents disagreed on whether the effective chain floor for these operations is `DefaultMinTransfer` or nothing at all; both readings support the over-refusal, which is why the mechanism is reported and the magnitude is bounded at "at least 20x".

**Fix**

```diff
-    function _minStakeTao() private view returns (uint256) {
-        return IStaking(STAKING_PRECOMPILE).getDefaultMinStake();
-    }
+    /// @dev The unstake floor. Same-subnet moves and transfers are not floored by the chain, so
+    ///      this must gate only removeStake sizing.
+    function _minUnstakeTao() private view returns (uint256) {
+        return IStaking(STAKING_PRECOMPILE).getDefaultMinStake();
+    }
```

Keep the floor on `removeStake` sizing in `unwrapForTao` and `_sellableChunk`, and gate every `moveStake` / `transferStake` call site on `amount != 0` instead. The staking mock needs the `origin_netuid == destination_netuid` exemption in the same change, or the fix is untestable.

---

[80] **8. Attested hotkeys are committed without checking they exist**

`ValidatorRegistry.updateValidators` · Severity: Medium · Confidence: 80

**Description**
`_validatePayload` checks netuid range, count, length agreement, zero hotkeys, zero weights, duplicates and the 10000 sum — but never that a hotkey names an account the chain knows. The vault has no fallback set and no non-fatal path around a rejected move, so the first `wrap`, `unwrap` or `rebalance` after such an attestation lands drives a `moveStake` at that key and reverts with all forwarded gas consumed, shutting the alpha rail for the subnet until a corrected attestation arrives.

No compromise is required. A single typo, or a hotkey that has since been deregistered or swapped away, produces the identical outcome from an entirely honest quorum, and nothing on chain rejects the attestation itself.

**Fix**

```diff
         uint256 sum;
         for (uint256 i; i < validatorCount;) {
             if (attestation.hotkeys[i] == bytes32(0)) revert ZeroValue();
+            // A hotkey with no owner account cannot receive stake, and the vault has no fallback
+            // set: committing one shuts the alpha rail for the subnet.
+            if (!_hotkeyExists(attestation.hotkeys[i])) revert UnknownHotkey();
             if (attestation.weights[i] == 0) revert ZeroWeight();
```

`_validatePayload` must lose `pure` for this. The staking precompile already exposes a hotkey-owner getter; it is simply absent from `IStaking`.

---

[75] **9. Move destinations are never validated before the dispatch**

`AlphaVault._rebalanceStep` · Severity: Low · Confidence: 75

**Description**
The rebalance step, the final hop of `_consolidateRotatedStake`, and the deposit redirect in `wrap` all use a registry-supplied `bytes32` directly as a `moveStake` destination, checking value preconditions (floor, price) but never identity. Both an all-subnet hotkey swap and a coldkey swap delete the destination's owner record, and each is a unilateral validator action. This is the same consequence as findings 2 and 8, at a third layer: it also covers the case those two do not, where the attested key never had an owner at all.

---

[75] **10. The TAO exit hands control away while its own supply is understated**

`AlphaVault.unwrapForTao` · Severity: Low · Confidence: 75

**Description**
The payout deliberately precedes the refund mint so proceeds are not folded into the claim index, but `Address.sendValue` forwards all remaining gas, so the caller executes arbitrary code while `totalSupply` is missing `refundShares` and `totalStake` still counts the unsold alpha. `nonReentrant` blocks re-entering the vault, not reading it: `sharePrice` and `previewUnwrap` both quote an inflated figure for the duration of the callback, by a factor of `1 + unsold/(total - assets)`, which rises without bound as the burn approaches the full supply. The lens NatSpec warns integrators against quoting from inside a callback, but the vault creates the window rather than closing it.

Confidence is held below the threshold because no consumer of these quotes exists in scope. Reserving the sale proceeds in `taoLiability` and minting before the payout would close it.

---

[75] **11. `sharePrice` floors to zero after a recapitalization**

`AlphaVaultLens.sharePrice` · Severity: Low · Confidence: 75

**Description**
The quote is scaled at `1e18`, which leaves only nine digits of headroom over the vault's normal ratio of about `1e9` shares per RAO. Recapitalizing a written-off position multiplies supply by the deposit — the path the `SUPPLY_CAP` comment names explicitly — pushing the ratio past `1e18`, after which `sharePrice` returns zero while `totalStake` and `previewUnwrap` on the same lens still report the real value. An integrator pricing a holding the conventional way reads zero against real backing. The dead zone begins at `1e18 * (stake + 1) < supply + 1e9`, which any position that once held a single alpha satisfies after recapitalization, and later wraps preserve the ratio.

This is a new consequence of the `sharePrice` change in `66a3f6e`, not a recurrence of the finding that change fixed. Quoting at a scale that survives the vault's own reachable ratio, or reverting instead of answering zero, resolves it.

---

Findings List

| # | Severity | Confidence | Title |
|---|---|---|---|
| 1 | Medium | [90] | Full-supply `unwrapForTao` reverts once the position has appreciated |
| 2 | Medium | [85] | An emptied slot re-targets a hotkey the chain has deleted |
| 3 | High | [85] | A dust stake under a swapped-away key freezes the whole token |
| 4 | High | [85] | A written-off position burns shares for nothing on the alpha rail |
| 5 | High | [85] | A write-off and its later recovery can be separated by a mint |
| 6 | Low | [82] | The dissolved-subnet payout ignores the chain's native quantum |
| 7 | Medium | [80] | The unstake minimum is applied to moves the chain never floors |
| 8 | Medium | [80] | Attested hotkeys are committed without checking they exist |
| 9 | Low | [75] | Move destinations are never validated before the dispatch |
| 10 | Low | [75] | The TAO exit hands control away while its own supply is understated |
| 11 | Low | [75] | `sharePrice` floors to zero after a recapitalization |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Stray recovery rests on a false chain invariant** — `AlphaVault.recoverStray` — Code smells: the NatSpec justifying permissionless access states that only the subnet clone can stake under its own coldkey, which is false — `do_transfer_stake` takes an arbitrary destination coldkey, and `CloneBase.flush` is itself an instance of it — Three agents confirmed the donation channel is open; none could turn it into profit because the operation is one-way into the pool, but the premise is load-bearing for future changes and the clone, unlike the mailbox, has no reclaim path for a mis-sent deposit.
- **`recoverStray` lacks the dissolved-token guard its sibling has** — `AlphaVault.recoverStray` — Code smells: `syncBacking` reverts `BackingUnchanged` for a token issued against a dissolved subnet; `recoverStray` carries only `requireNotHeldByDissolution` — Three agents; on a re-registered netuid it would move and then strand alpha under a retired token's record, but the precondition needs a pre-existing balance under the old clone's coldkey on the new subnet, which is attacker-funded.
- **Shares stay transferable while every quote reverts** — `AlphaVault._update` / `safeTransferFrom` — Code smells: every value-moving and pricing rail gates on the backing tripwire; the inherited ERC-1155 transfers do not, and `frozenUntil` publishes the markdown deadline — A holder who sees a write-off coming can still move shares while nobody can redeem them; exploitability depends on a secondary market for these ids, which could not be established from the repo.
- **The recovery slack books loss silently** — `AlphaVault.recoverStray` — Code smells: `coversTracked` carries an additive 1000-RAO slack, so the re-anchor can lower `slot.tracked` by up to that much with no window and no `BackingWrittenOff` event — Bounded at 1e-6 alpha per slot per recovery and total backing is unchanged, but it bypasses the mechanism `syncBacking` exists to enforce.
- **TAO arriving at a zero-supply clone accrues to the next depositor** — `AlphaVault._syncTao` / `_update` — Code smells: `syncAmounts` returns zero when supply is zero, so native TAO in a fully-exited position stays unreserved until a later sync folds it in at the then-current supply — Two agents; the pot size could not be bounded, so the impact is unquantified.
- **The refund mint is the one mint that bypasses `SUPPLY_CAP`** — `AlphaVault.unwrapForTao` — Code smells: `wrap` guards every mint against the cap; the refund mint does not — Two agents proved the bound cannot actually be breached (the refund rate is exactly rate-preserving on partials, and the full-burn case is capped by u64 alpha balances), so the invariant holds by an incidental external bound rather than by the check three lines away.
- **Unbounded attestation validity** — `ValidatorRegistry.updateValidators` — Code smells: `WeightAttestation` carries no deadline; the nonce alone bounds its life — A signed-but-unbroadcast attestation stays executable by anyone until some attestation lands on that netuid, including front-running the attesters' replacement; exposure depends on the off-chain signing procedure.
- **The 64-validator rotation path has no measured gas** — `AlphaVault._consolidateRotatedStake` / `_alignToWeights` — Code smells: a full rotation can issue up to 64 consolidation hops plus 63 rebalance moves and roughly 190 stake reads in one call, and every precompile rejection consumes all forwarded gas — If the widest path exceeds the block limit the alpha rail bricks; the repo's own notes flag this bound as unvalidated.
- **A gather can leave the whole position on one validator** — `AlphaVault._deliverAndAlign` — Code smells: the gather walks everything onto one hotkey and relies on `_alignToWeights` to re-split, but the rebalance step aborts the entire re-split on the first move it declines, and a zero price read makes the first step decline unconditionally — Concentration turns a later single-validator failure into a 100% shortfall instead of 1/N.
- **No slippage floor on alpha delivery** — `AlphaVault._deliverAndAlign` — Code smells: `unwrap` has no `minAlphaOut` while `previewUnwrap` quotes an exact figure, and delivery is re-read after up to 63 share-pool hops each able to credit short — The NatSpec concedes a few RAO of drift; no case was found where the gap exceeds hop-count dust.
- **`preStake` is derived from the requested amount, never the credited one** — `AlphaVault.wrap` — Code smells: `preStake = totalAlpha - totalDeposit` subtracts what the vault asked the chain to move, while the same file states elsewhere that a same-subnet move can credit one RAO short; the `> totalDeposit` clamp turns a few-RAO residual into the empty-vault mint rate — Three agents; the bias favours the depositor at existing holders' expense but is sub-dust at realistic pool sizes.
- **Preview and execution read different key sets** — `AlphaVaultLens.previewWrap` — Code smells: the preview prices over recorded slots, `wrap` prices over currently attested validators, and the two diverge until the first settle after a set expansion; anyone can credit alpha to a newly attested key permissionlessly — A paid grief that reverts preview-guarded wraps; the donation enriches holders, so no extraction path was found.
- **A stranger can claim an abandoned hotkey name** — `AlphaVault.recoverStray` — Code smells: recovery targets the name the record last saw, and the NatSpec directs watchers to claim abandoned hotkeys by registering them — Whoever claims the retired name first owns the key every recovery delivers the vault's alpha to, and can re-strand it; whether attester rotation reliably rolls the alpha off a claimant-owned key was not established.
- **Swaps that record no lineage edge reach write-off with no malice** — `AlphaVault.syncBacking` — Code smells: the chain records a successor edge only for netuids where the old hotkey is a member or parent, so a validator pruned from the subnet who then swaps normally strands the vault's alpha with no on-chain pointer, and re-registering an old hotkey erases an existing edge — The security model lists only erased or multi-hop successors; this reaches the same state without an attacker.
- **A keep-stake swap freezes a rail with no write-off path** — `AlphaVault._openBacking` — Code smells: a keep-stake global swap deletes the owner record while moving no stake, so `getStake` still reads the balance, `coversTracked` passes and no shortfall clock ever starts, yet every move naming that key fails — Documented operationally in the edge cases, but there is no vault-side detection and no bounded outcome.
- **The full-drain branch carries no pre-checks** — `AlphaVault._sellRound` — Code smells: the partial round layers four chain-rule checks specifically to keep the sim swap off unpriceable dust; round one issues `removeStake` with none, and the chain's liquidity bound is not full-drain-exempt the way the stake minimum is — Reaching it needs the clone to hold more than 1000x the subnet's alpha reserve, judged implausible but not ruled out for a collapsed pool.
- **The documented clamp on over-selling is a revert** — `AlphaVault.unwrapForTao` — Code smells: the comment says the subtraction "refuses to pay it out", but `assets - sold` is checked arithmetic, so any chain-side overshoot reverts the whole exit rather than withholding the excess — Two agents; the guard below it appears genuinely conservative against the chain's dust sweep, so no reachable overshoot was constructed.
- **Proxy creation is the one unguarded external** — `AlphaVault.createSubnetProxy` — Code smells: the only state-changing external without `nonReentrant`, reachable from every acceptance callback and value transfer — Idempotent in every window traced, so it is currently a no-op; it would open silently if any future path read the clone address before setting it.
- **`_rebalanceStep` tracks balances in memory across hops** — `AlphaVault._rebalanceStep` — Code smells: the align loop mutates a memory array across up to 63 moves while every other mover in the contract re-reads the chain per hop and documents why; the chain's share pool makes a post-move balance not exactly `old - amount` — An over-ask would revert the whole call; no case was found where the drift exceeds the slot's own target.
- **No upper bound on `recoveryWindow`** — `AlphaVault.syncBacking` — Code smells: the constructor rejects only zero, and the write-off compares `shortSince + recoveryWindow` as checked arithmetic — A near-maximum value makes that addition panic, removing the only path that reopens a frozen token; nobody controls it after deployment, so this is a deployment footgun.
- **A complete write-off bloats supply beyond recovery** — `AlphaVault.wrap` — Code smells: with located backing at zero the next deposit mints at the full recapitalization rate, so incumbent shares become worth a fraction of a RAO each and cannot clear the exit floor — One cycle leaves headroom under the cap; a second effectively kills the token.

**Refuted while hunting, recorded so they are not re-chased:** conviction-locked alpha cannot reach the vault (every account rejects incoming locked alpha by default); the chain's dust sweep cannot steal a neighbouring slot's backing (it is scoped to the entry being unstaked, and the global variant is sudo-only); duplicate keys cannot enter the active set (proved by case analysis, three agents); and the refund mint cannot breach `SUPPLY_CAP`.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
