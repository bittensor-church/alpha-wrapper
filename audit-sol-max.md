# Alpha Wrapper Solidity Security Audit

## Executive summary

This audit was performed on `main` using pashov's x-ray v2 and Solidity Auditor v3. The review ran all 12 Solidity-auditor specialist passes: math, access, economic, execution, invariant, periphery, first-principles, asymmetry, boundary, numerical-gap, trust-gap, and flow-gap.

The result is **1 High, 3 Medium, 3 Low, and 1 Informational finding; no Critical findings**.

The x-ray readiness verdict is **FRAGILE**, primarily because the registry admin can immediately replace the entire signer quorum. The generated supporting artifacts are:

- [X-ray report](x-ray/x-ray.md)
- [Entry points](x-ray/entry-points.md)
- [Invariants](x-ray/invariants.md)
- [Architecture diagram](x-ray/architecture.svg)

`forge test --offline` passed **510/510 tests**. Coverage was **96.9% of lines** and **98.6% of functions**. No Solidity source or tests were modified during the audit.

No remediations are included because this was requested as a findings-only pass.

## Scope

The production finding surface was:

- `src/AlphaVault.sol`
- `src/AlphaVaultLens.sol`
- `src/CloneBase.sol`
- `src/DepositMailbox.sol`
- `src/SubnetClone.sol`
- `src/ValidatorRegistry.sol`
- `src/VaultErrors.sol`
- `src/libraries/VaultMath.sol`
- `src/libraries/VaultReads.sol`

Interfaces and Solidity tests were read as supporting context only. No worktrees, unrelated project source, or dependency source under `lib/` was inspected. Local Subtensor source at `/home/pawel/Projects/subtensor` was used only to validate chain semantics.

## Phase 1 — Discovery

### Wrapper representation

The ERC-1155 token is a **share of a changing alpha pool**, not a claim on a fixed alpha amount. Each token ID identifies one `(netuid, registrationBlock)` generation (`src/AlphaVault.sol:166-177`). Alpha emissions and other stake growth increase backing without minting shares.

Live conversions use one virtual alpha RAO and one billion virtual shares (`src/libraries/VaultMath.sol:10-25`). Holders also retain separate indexed claims on TAO received by a live clone (`src/AlphaVault.sol:88-101`).

### Exchange-rate calculations

| Path | Calculation and inputs |
|---|---|
| Wrap | `floor(deposit * (supply + 1e9) / (preStake + 1))` at `src/AlphaVault.sol:263-273` and `src/libraries/VaultMath.sol:19-21`. `preStake` is post-operation alpha minus the nominal mailbox deposit. |
| Live alpha unwrap | `floor(shares * (backing + 1) / (supply + 1e9))` at `src/AlphaVault.sol:450-475`. |
| Partial TAO unwrap | Uses the same `assetsFor` conversion at `src/AlphaVault.sol:360-365`. |
| Full TAO unwrap | If `shares == supply`, uses **all real backing**, bypassing virtual offsets at `src/AlphaVault.sol:360-365`. |
| Dissolved subnet | `floor(unreservedTao * shares / supply)` at `src/AlphaVault.sol:539-547` and `src/libraries/VaultMath.sol:67-77`. |
| Lens `sharePrice` | Raw `backing * 1e18 / supply`, without virtual offsets, at `src/AlphaVaultLens.sol:121-135`. |

Backing comes from `getStake` precompile reads over recorded hotkeys. AMM price and reserves do **not** enter the share exchange-rate formula; price is used for floor checks, allocation decisions, and TAO-sale sizing.

### Precompile call sites and failure handling

| Precompile | Call sites and behavior |
|---|---|
| Subnet `0x0803` | `getNetworkRegistrationBlock(netuid)` at `src/AlphaVault.sol:175` and `src/libraries/VaultReads.sol:54-57`. `isSubnetDissolving(netuid)` at `src/libraries/VaultReads.sol:60-70`. Typed `uint64`/`bool` returns are consumed directly; failure or malformed return data reverts. |
| Address mapping `0x080c` | `addressMapping(H160)` at `src/libraries/VaultReads.sol:23-25`. The returned `bytes32` identifies mirrored account state; it does not grant Substrate signing authority. |
| StakingV2 `0x0805` — reads | `getStake(hotkey,coldkey,netuid)` at `src/libraries/VaultReads.sol:39-48,128,165` and `src/AlphaVault.sol:258,519,529,713,729,881,890,933,949,993,1006,1166,1207`. Values drive mailbox amount, backing, gathering, recovery, and reconciliation. `getHotkeySuccessor` is checked for existence/self-reference and later for uniqueness and coverage at `src/libraries/VaultReads.sol:153-174`. Minimum-stake getters are used at `src/AlphaVault.sol:370,758-759`. |
| StakingV2 — transfer | `transferStake(destinationColdkey,hotkey,netuid,netuid,amount)` at `src/CloneBase.sol:45-48`, invoked by wrap, live delivery, and mailbox recovery. It returns no boolean. Local Subtensor moves the exact same-subnet alpha amount without AMM fees at `pallets/subtensor/src/staking/stake_utils.rs:1043-1103`. |
| StakingV2 — move | `moveStake(fromHotkey,toHotkey,netuid,netuid,amount)` at `src/SubnetClone.sol:16-19`, called during rebalancing, consolidation, gathering, and recovery. It returns no boolean; subsequent paths re-read balances. |
| StakingV2 — remove | `removeStake(hotkey,amount,netuid)` at `src/CloneBase.sol:59-67`, reached from mailbox and vault TAO sales. Actual TAO is measured as the clone balance delta, and vault sales re-read remaining alpha at `src/AlphaVault.sol:369-390`. |
| Alpha `0x0808` | `getAlphaPrice(netuid)` at `src/AlphaVault.sol:244,395,445,575,816,995`. It gates stake floors/rebalancing; it does not price shares. `simSwapAlphaForTao(netuid,uint64)` at `src/AlphaVault.sol:830-839` sizes partial sales and checks their residual. |

Local Subtensor converts rejected dispatches into `PrecompileFailure::Error`, rather than returning `false` (`precompiles/src/extensions.rs:98-118`). Frontier starts a storage transaction per EVM frame and rolls it back on revert or discard (`vendor/frontier/frame/evm/src/runner/stack.rs:803-845`). Therefore, in the reviewed checkout, a later Solidity revert also rolls back earlier pallet mutations.

Production runtime equivalence is **UNVERIFIED**.

### Privileged functions

- `ValidatorRegistry.setSigners` is restricted to `DEFAULT_ADMIN_ROLE`; the constructor grants that role to the supplied admin (`src/ValidatorRegistry.sol:66-71,110-144`).
- `updateValidators` and `updateValidatorsBatch` may be submitted by any relayer, but require the next nonce and a sorted threshold of current signer signatures (`src/ValidatorRegistry.sol:75-96,170-192`).
- `CloneBase.flush`, `unwrapTao`, `sellAlphaForTao`, and `SubnetClone.moveStake` are callable only by the clone's stored wrapper (`src/CloneBase.sol:22-25,45-67`, `src/SubnetClone.sol:16-19`).
- Clone initialization is one-shot and requires `msg.sender == _wrapper` (`src/CloneBase.sol:27-37`).
- `AlphaVault` has no authored admin. Its maintenance methods—clone creation, rebalance, backing synchronization, and stray recovery—are permissionless. Deposit, redemption, claim, and mailbox paths are bound to the caller's shares, entitlement, or deterministic mailbox.

### Deposit and withdrawal paths

Deposit:

1. The user pre-positions alpha at the SS58 mirror of `getDepositAddress(user,netuid)`.
2. `wrap` resolves the current generation and signed validator set.
3. It reads the caller-specific mailbox stake, checks its TAO floor, and transfers it to the subnet clone.
4. It consolidates and rebalances, re-reads all backing, subtracts the nominal mailbox amount to derive pre-deposit backing, and mints shares (`src/AlphaVault.sol:221-275`).

There is no production `approve`, `addStake`, allowance, or pull-from-user flow.

Live alpha withdrawal:

1. Caller burns owned shares.
2. Vault resolves backing and calculates `assetsFor`.
3. It transfers alpha to any nonzero caller-selected `bytes32` coldkey.
4. Remaining backing is realigned and recorded (`src/AlphaVault.sol:300-312,433-477`).

Live TAO withdrawal:

1. Caller burns shares.
2. Vault sells the corresponding alpha through the subnet AMM.
3. It measures actual TAO received and enforces `minTaoOut`.
4. It re-reads remaining alpha and refunds shares for material unsold backing (`src/AlphaVault.sol:341-406`).

Dissolved withdrawal divides the clone's unreserved TAO refund pro rata and burns the shares (`src/AlphaVault.sol:539-547`).

## Findings

### [97] High — Recoverable alpha can be written off, recapitalized, and captured

`AlphaVault.syncBacking / wrap / recoverStray`

Impact is near-total theft of existing holders' alpha principal. Likelihood is low-to-moderate: the attacker must control an attested validator, pay swap/re-registration costs, remain attested, and pass the observable recovery window without a watcher recovering the stake. Once the deadline arrives, writeoff, mint, and recovery can be atomic.

Attack path:

1. A malicious attested validator owner swaps `H0 -> H1`; Subtensor moves every delegator's stake, including the vault clone's stake (`pallets/subtensor/src/swap/swap_hotkey.rs:856-870`).
2. The owner registers `H0` as a neuron again. Registration clears `H0`'s stale successor edge (`pallets/subtensor/src/subnets/uids.rs:112-119,161-167`). The vault still records `H0`, while the principal remains at `H1`.
3. `resolveBacking` sees `H0 == 0` and no usable successor (`src/libraries/VaultReads.sol:114-167`). An attacker starts the loss clock and, after `recoveryWindow`, calls `syncBacking` again, setting `tracked` to zero without moving the alpha (`src/AlphaVault.sol:1044-1078`).
4. An ERC-1155-receiving helper atomically finalizes the writeoff, wraps a pre-funded minimum deposit under `H0`, and receives a dominant share supply because `preStake == 0` (`src/AlphaVault.sol:263-273`).
5. The helper calls `recoverStray(tokenId,H1)`. With no shortfall left, `_chooseRecoverySlot` treats the old principal as new backing for the current cohort (`src/AlphaVault.sol:981-1037`).
6. The attacker redeems nearly all of the old holders' alpha.

Concrete example: 1,000 alpha backing creates `S = 1e21` shares. After writeoff, a normal `2,000,000` alpha-RAO deposit mints `2,000,000,000,002,000,000,000,000,000` shares. Recovering the original 1,000 alpha lets the attacker redeem `1,000.0015` alpha, for approximately **999.9995 alpha profit** after their deposit; the old cohort retains about `0.0005 alpha`.

Checklist anchors: hotkey/address confusion, recovery state machine, first-depositor/share inflation, permissionless state-transition ordering.

### [96] Medium — Validator authority survives subnet-generation reuse

`ValidatorRegistry.updateValidators`

Impact is routing an entire replacement-generation position to obsolete or adversarial hotkeys, causing validator-take diversion, missed emissions, or operational reverts. Principal remains owned by the clone. Likelihood is medium because netuid reuse is explicitly anticipated by the vault, while registry state automatically persists.

Attack path:

1. During generation G1, the signer quorum signs a valid next-nonce validator list for netuid `N`; an untrusted relayer withholds it.
2. G1 dissolves and a different subnet registers at `N`. The vault creates a new token ID because it includes the registration block (`src/AlphaVault.sol:166-177`).
3. Registry lists and nonces remain keyed only by `netuid` (`src/ValidatorRegistry.sol:39-44`).
4. The relayer submits the old message. Its type hash contains only netuid, arrays, and nonce; there is no registration block or expiry (`src/ValidatorRegistry.sol:19-31,211-220`).
5. A G2 depositor calls `wrap`; the new pool consumes the old list solely by netuid (`src/AlphaVault.sol:224-230`).

Even without a withheld signature, the previously stored validator list remains active for G2 until another update lands.

Checklist anchors: subnet lifecycle, signature replay/freshness, access control, validator integration boundary.

### [95] Medium — A one-share holdout captures the virtual-share reserve

`AlphaVault.unwrapForTao`

Impact is extraction of alpha withheld from other holders by virtual-share rounding. It can reach approximately 10.5 alpha under the supplied 21M-alpha cap and minimum-size initial position. Likelihood is low because the attacker must retain the final indivisible share and wait for substantial backing growth.

Attack path:

1. Alice and Bob deposit normally.
2. Bob live-unwraps all but one share; this uses virtual-offset `assetsFor`.
3. Emissions increase backing.
4. Alice burns all her shares through live `unwrap`, again using `assetsFor`, leaving the virtual-share portion in the clone.
5. Bob now owns the entire real supply—one share—and calls `unwrapForTao`.
6. `shares == supply` assigns Bob all remaining backing rather than the one-share `assetsFor` amount (`src/AlphaVault.sol:360-365`).

With Alice initially depositing `2,000,000` alpha RAO, Bob `4,000,000`, and backing later reaching `1e15` RAO, Alice's final live exit leaves roughly `499,999,750` RAO. Bob's ordinary one-share entitlement rounds to zero, but the full TAO branch sells the entire residual for him.

Checklist anchors: last-holder boundary, rounding direction, first-depositor/share inflation, unstaking asymmetry.

### [93] Medium — Full live exit leaves backing for the next depositor to exact-sell

`AlphaVault._unwrapFromLiveSubnet`

Impact is transfer of the former sole holder's virtual-offset residual to the first subsequent depositor. Likelihood is low because it requires large backing growth relative to the original supply and a profitable AMM exit.

Attack path:

1. Alice is sole holder and backing grows through emissions.
2. Alice burns the full real supply through live `unwrap`.
3. `_unwrapFromLiveSubnet` still applies `assetsFor`, leaving alpha in the clone while real supply becomes zero (`src/AlphaVault.sol:450-477`).
4. Mallory makes the first new deposit and owns all newly minted real shares.
5. Mallory calls full `unwrapForTao`, which exact-sells the old residual plus Mallory's deposit.

At a 1 TAO/alpha price, a minimum `2,000,000`-RAO seed whose backing grows to the supplied 21M-alpha cap leaves approximately **10.49999475 alpha** after the full live exit. The next minimum depositor can acquire the entire new supply and exact-sell that residual.

Checklist anchors: zero-supply transition, virtual-share ownership, first depositor, cross-exit symmetry.

### [80] Low — First-deposit preview can be made unattainable

`AlphaVaultLens.previewWrap`

Impact is gas and first-deposit liveness grief, not direct principal loss. Likelihood is moderate for integrations that use the lens quote as `minSharesOut`; the attacker must lock a floor-clearing alpha amount in the clone.

Attack path:

1. Attacker calls permissionless `createSubnetProxy` before the first deposit (`src/AlphaVault.sol:180-185`).
2. Attacker transfers alpha directly to the clone's SS58 mirror under a current validator. Subtensor accepts arbitrary destination coldkeys and credits exact same-subnet alpha (`pallets/subtensor/src/staking/move_stake.rs:120-143`).
3. The lens sees an empty slot record and reports zero backing, so it quotes `D * 1e9` shares (`src/AlphaVaultLens.sol:103-119,145-148`).
4. Execution settles the current validator and discovers `X + D`; it prices the deposit against `preStake = X`, producing fewer shares (`src/AlphaVault.sol:238-268`).
5. A victim using the quoted value as their minimum reverts. The mailbox deposit remains safe, but the same pre-funded `X` keeps later strict quotes unattainable.

Checklist anchors: first-depositor initialization, view/write symmetry, address-mirror behavior, denial of service.

### [75] Low, conditional — `sharePrice` is not an executable share price

`AlphaVaultLens.sharePrice`

The formula mismatch is confirmed, but downstream loss is **UNVERIFIED** because no scoped contract consumes this function. It is reported at confidence 75 due multi-agent convergence.

`sharePrice` uses raw backing divided by real supply (`src/AlphaVaultLens.sol:121-135`); partial mint/redemption uses virtual balances (`src/libraries/VaultMath.sol:10-25`).

Attack path for an external integration:

1. Attacker establishes a two-alpha-RAO seed during a permitted maximum-price state.
2. Backing grows or is donated until it is `3,000,000,002` RAO.
3. The lens values half of the `2e9` shares at `1,500,000,001` RAO.
4. `previewUnwrap` and execution return only `1,000,000,001` RAO.
5. A buyer or lending market trusting `sharePrice` loses `500,000,000` RAO; the final holder can collect the retained backing through the exact TAO branch.

The local runtime exposes a high enough maximum price for the two-RAO seed to satisfy the default floor (`pallets/swap/src/pallet/impls.rs:372-377`). An actual affected exchange, lender, or accounting consumer remains unverified.

Checklist anchors: ERC-1155 composability, quote/execution parity, first-depositor boundary.

### [75] Low, conditional — AMM price can preserve an overweight validator allocation

`AlphaVault.wrap / _rebalanceStep`

Impact is temporary diversion of delegation and validator take, rather than loss of share principal. Profitability and practical duration are **UNVERIFIED** because they depend on deployed reserve depth, fees, validator take, and keeper behavior. Two independent agents converged on the path.

Attack path:

1. A deposit `D` arrives under attacker validator `H0` in a 50/50 allocation.
2. An AMM trader front-runs the deposit and sets spot price `p` so `D * p` clears the deposit floor but `(D/2) * p` is below it.
3. `wrap` accepts the deposit at `src/AlphaVault.sol:241-247`.
4. `_rebalanceStep` skips the `D/2` move at `src/AlphaVault.sol:631-677`.
5. The trader restores price. All `D` remains delegated to `H0`, which can receive excess validator take until another successful rebalance.

`minSharesOut` does not stop this because alpha-denominated share pricing is unchanged.

Checklist anchors: AMM sandwiching, validator economics, price-dependent access to a same-subnet move.

### [75] Informational — Dissolved payouts and events can exceed actual delivery by less than one RAO

`AlphaVault._unwrapFromDissolvedSubnet`

Impact is bounded native-precision dust transferred from earlier redeemers to later holders. Likelihood is high whenever a proportional result is not a multiple of the chain's `1e9` EVM-wei native quantum. Production runtime parity remains **UNVERIFIED**.

Attack/state path:

1. A dissolved clone holds `3,000,000,000` EVM wei with two equal receipt holders.
2. The first holder's pro-rata calculation is `1,500,000,000` and that amount is emitted (`src/AlphaVault.sol:539-547`).
3. Local Frontier converts EVM value to native balance by dropping the bottom nine decimals, so only `1,000,000,000` moves (`runtime/src/lib.rs:1097-1147`).
4. The last holder receives the remaining `2,000,000,000`.

The discrepancy is strictly less than one native RAO per redemption; it was not assigned a material-security severity.

Checklist anchors: native precision boundary, division rounding, event/accounting parity.

## Targeted and generic categories with no additional finding

- Exchange-rate manipulation: AMM reserves do not price shares. Deposits and live-alpha exits cannot be sandwiched into a share-rate theft. Price can affect floor/liveness and validator placement, as reported above.
- Precompile semantics: no mutation returns or silently ignored `false` values were found. Local rollback semantics are atomic.
- Approval/pull flow: not applicable; deposits use caller-specific pre-funded mailboxes.
- Address confusion: caller-selected `bytes32` destinations need not be controlled by the caller, but only the caller's burned/reclaimed assets can be sent there. No cross-user signing-authority confusion was found.
- Unstaking asymmetry: the TAO withdrawer receives the measured AMM proceeds and bears immediate slippage under `minTaoOut`; the resulting lower AMM price affects later sellers. No additional internal accounting loss was found.
- Rounding: ordinary mint, live redemption, and dissolved pro-rata divisions floor toward the pool/later holders; claim-index liability rounds upward. No repeated-small-operation over-credit was found beyond the exit discontinuities and native-quantum observation.
- Reentrancy: value-sending public paths are `nonReentrant`; accounting and burns precede callbacks. No extraction trace survived.
- Upgradeability: no authored upgrade mechanism exists. Clone implementations are constructor-locked and initialized in the deployment transaction.
- Signature handling: sorted/distinct threshold verification was intact apart from generation freshness.
- ERC-20 conformance: not applicable—the wrapper is ERC-1155. Exact inherited OpenZeppelin ERC-1155/EIP-712/AccessControl behavior remains unverified because dependency source was outside the permitted scope.

## Unverified questions and retained leads

- **Low-liquidity dual-exit liveness:** a still-live subnet with transfers disabled and reserves below swap limits may make both alpha and TAO exits fail. Confirmation requires deployed reserve values, subnet-owner controls, and the chain's eventual-dissolution guarantees.
- **Cross-generation blackout coupling:** `unwrap` checks dissolution by low-16-bit netuid before selecting an older dissolved token's refund path (`src/AlphaVault.sol:300-308`, `src/libraries/VaultReads.sol:66-70`). A newer generation's cleanup therefore freezes older refunds. An unprivileged trigger was not established; local dissolution is root-controlled.
- The deployed Subtensor runtime/spec version was not supplied, so local precompile selectors, rollback, conversion, and lifecycle behavior cannot be proven byte-identical to production.
- The scoped Solidity does not state the intended user operation for initially moving native alpha into a mailbox.
- Actual deployment addresses, registry admin/signers/threshold, recovery window, and keeper coverage cannot be determined from these contracts.
- No scoped source identifies external consumers of `sharePrice` or `previewWrap`.
- Exact inherited OpenZeppelin behavior requires inspection of the pinned dependency source, which was outside scope.

## Completeness

Eighteen unique `(Contract, function)` pairs appeared in raw agent output; all 18 are adjudicated in this report.

This was an AI-assisted review and cannot establish the absence of additional vulnerabilities.
