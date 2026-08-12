# Locked-Alpha TAO Sale - Design

Expose `IStaking.removeStake` as an always-available exit path so holders of wrapped alpha (vault shares) and per-user mailbox alpha can convert their position to native TAO even when the subnet owner has flipped `TransferToggle` on for the netuid. See [docs/non_transferable_alphas.md](../../non_transferable_alphas.md) for the originating problem.

## Goals / Non-Goals

**Goals**

- `withdrawForTao(tokenId, shares, minTaoOut)` burns vault shares pro-rata and pays the caller native TAO.
- `reclaimMailboxAlphaAsTao(netuid, hotkey, minTaoOut)` swaps stuck mailbox alpha for native TAO and pays the depositing user.
- Caller-supplied `minTaoOut` enforced at the EVM layer over the sum of multi-hotkey swap output.
- Both entry points are always available (not gated on detected `TransferToggle` state); the caller picks the rail.

**Non-Goals**

- Auto-routing between rails based on `TransferToggle` state (no public storage reader exists).
- TAO-rail equivalent for the regular alpha-rail `withdraw` path.
- Changing share math, validator registry, rebalance, or dissolution handling.
- Invariant fuzzing and subtensor fork tests (future work).

## Architecture

```
                                       AlphaVault
                                  +---------------------+
   user (EVM addr)  --shares----->| withdrawForTao      |
                                  |                     |
   user (EVM addr)  ------------> | reclaimMailbox-     |
                                  |   AlphaAsTao        |
                                  +--------+------------+
                                           | onlyWrapper
                                           v
                          +------------------------------+
                          | CloneBase.sellAlphaForTao    |
                          |   IStaking.removeStake(...)  |
                          +--------+---------------------+
                                   | alpha -> TAO (substrate)
                                   v  TAO credited to clone's
                                      HashedAddressMapping address
                                      = clone's EVM balance
                                   |
                                   v
                          +------------------------------+
                          | CloneBase.withdrawTao        |
                          |   Address.sendValue(user)    |
                          +------------------------------+
```

`pallets/subtensor/src/staking/remove_stake.rs::do_remove_stake` does not call `check_transfer_toggle`. The TAO rail bypasses the toggle that blocks the alpha rail by switching staking precompile entry points to idx 2053 (`removeStake(bytes32,uint256,uint256)`).

## Components

### `src/interfaces/IStaking.sol`

```solidity
function removeStake(bytes32 hotkey, uint256 netuid, uint256 amount) external;
```

### `src/CloneBase.sol`

```solidity
function sellAlphaForTao(bytes32 hotkey, uint256 netuid, uint256 amount) external onlyWrapper {
    if (amount > 0) {
        IStaking(STAKING_PRECOMPILE).removeStake(hotkey, netuid, amount);
    }
}
```

The clone never holds the TAO directly during the call. `removeStake` credits the substrate coldkey for the calling EVM contract via `HashedAddressMapping`; that becomes the clone's native EVM balance. The vault computes actual TAO output as `clone.balance` delta around the call.

### `src/AlphaVault.sol`

```solidity
error SlippageExceeded(uint256 taoOut, uint256 minTaoOut);

event WithdrawnForTao(address indexed user, uint256 indexed tokenId, uint256 shares, uint256 assetsBurned, uint256 taoOut);
event MailboxAlphaSoldForTao(address indexed user, uint256 indexed netuid, bytes32 indexed hotkey, uint256 alpha, uint256 taoOut);

function withdrawForTao(uint256 tokenId, uint256 shares, uint256 minTaoOut) external nonReentrant;
function reclaimMailboxAlphaAsTao(uint256 netuid, bytes32 hotkey, uint256 minTaoOut) external nonReentrant;
```

Internal helper used by `withdrawForTao`:

```solidity
function _drainCandidates(uint256 tokenId, uint256 netuid)
    internal
    view
    returns (bytes32[6] memory hotkeys, uint256[6] memory balances, uint256 totalStake);
```

Returns the deduplicated union of `getBestValidators(netuid)` and `_lastSeenHotkeys[tokenId]` together with each entry's current stake under the clone's coldkey. Width is 6 because each source contributes at most 3. Order is not significant.

### `test/mocks/MockStaking.sol`

Add `removeStake` plus configuration:

```solidity
uint256 public taoPerAlpha;
uint256 public taoPerAlphaDenom;
bool    public removeStakeReverts;

function setRemoveStakeRate(uint256 num, uint256 denom) external;
function setRemoveStakeReverts(bool v) external;
function removeStake(bytes32 hotkey, uint256 netuid, uint256 alphaAmount) external;
```

`removeStake` reduces the per-caller stake mapping and credits `msg.sender` with `(alphaAmount * num) / denom` via `call{value: ...}("")`. The mock simulates `HashedAddressMapping` by paying the caller directly; pre-fund the mock with TAO in `setUp`.

### `test/AlphaVaultTestBase.sol` (new abstract base)

Lift `setUp` body byte-for-byte (marked `virtual`) and all helpers used by 2+ test files from the current `AlphaVault.t.sol`. Visibility flips from `private` to `internal`. Lands as a separate refactor commit ahead of the feature commits; acceptance criterion is that the existing `forge test` suite passes with identical per-test results before and after the lift.

Lifted helpers: `_setValidators`, `_hks1/2/3`, `_wts1/2/3`, `_toSubstrate`, `_simulateAlphaDeposit`, `_simulateAlphaDepositHotkey`, `_processDeposit`, `_processDepositHotkey`, `_getStake`, `_subnetColdkey`, `_getVaultStake`, `_totalVaultStakeAcrossHotkeys`, `_setRegBlock`, `_simulateDissolutionStarted`, `_simulateDissolutionCompleted`, `_simulateNewNetworkRegistered`, `_simulateTaoAwardedOnDissolution`, `_countRebalancedLogs`. `_simulateEmissions` stays in `AlphaVault.t.sol` (only used there).

New helpers added to the base for the TAO rail: `_setRemoveStakeRate`, `_setRemoveStakeReverts`, `_donateToClone`, `_expectedTaoFor`.

## Data Flow

### `withdrawForTao(tokenId, shares, minTaoOut)`

1. `shares != 0`, `balanceOf(msg.sender, tokenId) >= shares`.
2. `clone = subnetClone[tokenId]`; if zero -> `NothingToWithdraw()`.
3. `isNetuidInDissolvedQueue(netuid)` -> `SubnetInDissolutionBlackoutPeriod()`; `_isIssuedForDissolvedSubnet(tokenId)` -> `SubnetDissolved()`.
4. `_drainCandidates(tokenId, netuid)` -> `(hotkeys, balances, totalStake)`.
5. `totalStake == 0` -> `NothingToWithdraw()`.
6. Sync `totalStake[tokenId] = totalStake`. Compute `assets = _convertToAssets(shares, totalStake, totalSupply(tokenId))`; if zero -> `ZeroAmount()`.
7. `_burn(msg.sender, tokenId, shares)`; `totalStake[tokenId] -= assets`.
8. `balanceBefore = clone.balance`; `remaining = assets`. For each slot with `balances[i] > 0`: `take = min(balances[i], remaining)`; `SubnetClone(clone).sellAlphaForTao(hotkeys[i], netuid, take)`; `remaining -= take`. Stop when `remaining == 0`.
9. `taoOut = clone.balance - balanceBefore`; if `taoOut < minTaoOut` -> `SlippageExceeded(taoOut, minTaoOut)`.
10. `SubnetClone(clone).withdrawTao(payable(msg.sender), taoOut)`.
11. Emit `WithdrawnForTao(msg.sender, tokenId, shares, assets, taoOut)`.

### `reclaimMailboxAlphaAsTao(netuid, hotkey, minTaoOut)`

1. `netuid <= type(uint16).max`; `hotkey != bytes32(0)`.
2. `predicted = getDepositAddress(msg.sender, netuid)`; `mailboxColdkey = _coldkeyOf(predicted)`.
3. `amount = IStaking.getStake(hotkey, mailboxColdkey, netuid)`; if zero -> `ZeroAmount()`.
4. `_ensureMailboxClone(msg.sender, netuid)`; `balanceBefore = predicted.balance`.
5. `DepositMailbox(predicted).sellAlphaForTao(hotkey, netuid, amount)`.
6. `taoOut = predicted.balance - balanceBefore`; if `taoOut < minTaoOut` -> `SlippageExceeded(taoOut, minTaoOut)`.
7. `DepositMailbox(predicted).withdrawTao(payable(msg.sender), taoOut)`.
8. Emit `MailboxAlphaSoldForTao(msg.sender, netuid, hotkey, amount, taoOut)`.

## Security Notes

- **Burn before external.** Shares are burned and `totalStake` is decremented in step 7 (vault path) before any `sellAlphaForTao`/`withdrawTao` call. If anything downstream reverts, the EVM unwinds both mutations atomically and the user keeps their shares.
- **Delta-based output snapshot.** `taoOut = clone.balance - balanceBefore` excludes any pre-existing balance (donations, leftover wei). A griefer cannot inflate the slippage-check input by donating; the donation stays in the clone and is paid out to a later caller.
- **Union of hotkeys.** The drain set is `getBestValidators(netuid) UNION _lastSeenHotkeys[tokenId]`. `getBestValidators` reads from the validator registry (signature-gated). `_lastSeenHotkeys` is written only by `_sweepRotatedStake`, called from `processDeposit`/`withdraw`/`rebalance` after each has just read the current set from the registry. There is no path that writes attacker-controlled hotkeys into either source. Order is irrelevant for correctness; zero-balance slots are skipped in the drain loop. The remaining risk is under-redemption (value-leak) if alpha sits under a hotkey neither in the current set nor in `_lastSeenHotkeys`; the alpha-rail `withdraw` can still extract it when `TransferToggle` is off.
- **Reentrancy.** Both entry points are `nonReentrant`. `removeStake` is synchronous (no EVM callback). `Address.sendValue` at the end can re-enter a contract recipient, but by that point shares are burned, `totalStake` is decremented, and the clone TAO has moved; there is nothing left to double-claim.
- **No alpha-rail corruption.** The TAO rail mutates only `totalStake[tokenId]` and the ERC1155 supply, both of which the alpha-rail also drives. Both rails read the same `totalStake` source; partial draining by one path leaves consistent state for the other.

## Error Handling

| Error | Where it fires |
|---|---|
| `ZeroAmount()` | `shares == 0`; `assets == 0` (pro-rata rounds to zero); `amount == 0` on mailbox path |
| `ZeroHotkey()` | Mailbox path: `hotkey == bytes32(0)` |
| `InsufficientShares()` | Vault path: caller does not own enough shares |
| `NothingToWithdraw()` | Vault path: no clone, or union total stake is zero |
| `SubnetDissolved()` | Vault path: tokenId for a dissolved subnet |
| `SubnetInDissolutionBlackoutPeriod()` | Vault path: netuid in subtensor's cleanup queue |
| `NetuidOutOfRange()` | Mailbox path: `netuid > type(uint16).max` |
| `SlippageExceeded(taoOut, minTaoOut)` | Both paths: realized TAO below caller-supplied minimum |

`minTaoOut == 0` is allowed (explicit opt-out of slippage protection); cheaper checks come before mutations and before any external call (see the data-flow step order).

## Testing

### `test/WithdrawForTao.t.sol`

| # | Scenario | Expected outcome |
|---|---|---|
| H1 | Single hotkey, full burn | `taoOut > 0`; shares burned; `totalStake[tokenId]` decremented; caller balance += `taoOut` |
| H2 | Two hotkeys, partial burn | drain stops at `remaining == 0`; only required calls made |
| H3 | One hotkey rotated out (in `_lastSeenHotkeys` only) | union pulls the historical hotkey and drains it |
| H4 | Same hotkey in current set and `_lastSeenHotkeys` | dedup; drained exactly once |
| H5 | `minTaoOut = 0` | succeeds even with tiny pool yield |
| H6 | `minTaoOut = exact expected` | succeeds at the boundary |
| R1 | `shares = 0` | `ZeroAmount()` |
| R2 | `shares > balanceOf` | `InsufficientShares()` |
| R3 | `subnetClone[tokenId]` not set | `NothingToWithdraw()` |
| R4 | `isNetuidInDissolvedQueue` true | `SubnetInDissolutionBlackoutPeriod()` |
| R5 | tokenId for dissolved subnet | `SubnetDissolved()` |
| R6 | All union hotkeys empty | `NothingToWithdraw()` |
| R7 | Microscopic shares -> pro-rata rounds to zero | `ZeroAmount()` |
| R8 | `minTaoOut = expected + 1` | `SlippageExceeded(expected, expected + 1)` |
| R9 | `removeStakeReverts = true` (subtensor revert) | reverts; shares NOT burned |
| R10 | Mock `transferStake` to revert (simulate `TransferToggle = ON`), regular `withdraw` reverts, `withdrawForTao` succeeds | alternative-exit story end-to-end |
| A1 | Donate to clone before call | `taoOut` is swap delta only; donation remains in clone |
| A2 | Receiver reverts on `receive()` | tx reverts; shares NOT burned |
| A3 | Receiver re-enters `withdrawForTao` | OZ reentrancy revert |
| A4 | Two users share a tokenId; A drains; B can still withdraw with consistent pro-rata math | totalStake stays consistent |
| A5 | After `withdrawForTao`, alpha-rail `withdraw` and `rebalance` still work on remaining alpha | TAO rail does not corrupt alpha-rail state |

### `test/ReclaimMailboxAlphaAsTao.t.sol`

| # | Scenario | Expected outcome |
|---|---|---|
| MH1 | User has mailbox alpha, reclaims | TAO received; mailbox alpha gone; mailbox clone created if absent |
| MH2 | `minTaoOut = 0` | succeeds with any positive yield |
| MH3 | Two users on same netuid, independent mailboxes | strict isolation |
| MR1 | `netuid > type(uint16).max` | `NetuidOutOfRange()` |
| MR2 | `hotkey == bytes32(0)` | `ZeroHotkey()` |
| MR3 | No stake for that hotkey | `ZeroAmount()` |
| MR4 | `minTaoOut > realized` | `SlippageExceeded(...)` |
| MR5 | `removeStakeReverts = true` | subtensor revert bubbles up; mailbox stake intact |
| MA1 | Pre-existing leftover TAO in mailbox clone | `taoOut` is delta only; leftover untouched |
| MA2 | Receiver reverts on `receive()` | tx reverts; mailbox alpha intact |
| MA3 | Reentrancy via `receive()` | blocked by `nonReentrant` |

### Out of scope

Foundry invariant suite ("for any sequence of `withdrawForTao` calls, `sum(shares_burned * pricePerShare) <= sum(taoOut)` modulo rounding") and subtensor fork integration tests are future work.

## Implementation Style

These rules apply to every file touched by the implementation (contracts, mocks, tests):

- **Comments explain WHY, not WHAT.** Skip the comment if it just narrates the next line.
- **Comments must survive a rename.** Talk about the concept (e.g. "the swap delta", "the union of historical and current hotkeys"), not specific identifier names. NatSpec `@param`/`@return` is the documented exception: it is a documentation interface bound to the signature and tracked by tooling.
- **No alternatives-considered comments.** Do not leave `// we tried X first` or `// could also use Y` in code. Design rationale lives in this spec; code reflects only the chosen solution.
- **No stale-references.** Do not name files, line numbers, ticket IDs, PR numbers, or removed identifiers in comments. They rot.
- **ASCII only.** No box drawing, em-dashes, smart quotes, or other Unicode in comments or strings.
- **Prefer self-explanatory code over a comment.** If the call site needs an explanation, the call or its names probably need work.

## Risks

- **Stranded historical alpha.** Alpha under hotkeys neither in the current set nor in `_lastSeenHotkeys` is unreachable via this exit (alpha-rail withdraw can still reach it when `TransferToggle` is off). Mitigated by `_sweepRotatedStake` snapshotting the validator set on every state-changing path. Documented in natspec on `withdrawForTao`.
- **Subtensor precompile drift.** A future subtensor that gates `removeStake` behind `TransferToggle` would break the TAO rail. Pin the interface signature in `IStaking.sol` and reference the targeted subtensor commit in the natspec.

## Future Work

- Foundry invariant suite on the union drain.
- Auto-route between rails if `TransferToggle` becomes publicly readable on chain.
- `removeStakeLimit`-based per-call limit price as a finer-grained slippage variant.
