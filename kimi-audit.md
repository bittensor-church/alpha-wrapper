# Alpha Wrapper — Security Audit (kimi)

**Scope:** `src/` only (9 `.sol` files). Interfaces and subtensor source read for ground truth.
**Precompile semantics verified against:** `~/Projects/subtensor/precompiles/src/{staking,extensions,alpha}.rs`,
`~/Projects/subtensor/runtime/src/lib.rs`, `~/Projects/subtensor/vendor/frontier/frame/evm`.

---

## PHASE 1 — DISCOVER

**In-scope files (9):** `AlphaVault.sol`, `AlphaVaultLens.sol`, `CloneBase.sol`, `SubnetClone.sol`,
`DepositMailbox.sol`, `ValidatorRegistry.sol`, `VaultErrors.sol`, `libraries/VaultMath.sol`,
`libraries/VaultReads.sol`.

**1. What the wrapper token represents** — A share of a growing pool, not a fixed alpha claim.
Shares are ERC1155 per `tokenId = netuid | (registrationBlock << 16)` (`AlphaVault.sol:171-178`).
Rate uses virtual offsets: `sharesFor = assets*(supply+1e9)/(stake+1)`,
`assetsFor = shares*(stake+1)/(supply+1e9)` (`VaultMath.sol:19-25`).

**2. Exchange-rate computation** — `wrap` at `AlphaVault.sol:258-261`: `totalAlpha = _settle(...)`,
`preStake = totalAlpha - totalDeposit`, `shares = sharesFor(preStake, totalSupply, totalDeposit)`.
Live path uses `assetsFor` at `AlphaVault.sol:447`. Virtual offsets make it inflation-resistant.

**3. Precompile call sites** (all revert on failure, never return false — verified `extensions.rs:60-119`):

| Call | Site | Args | Failure handling |
|---|---|---|---|
| `getStake` | `AlphaVault.sol:253,505,515,699,715,867,876,919,935,979,992,1152,1193` | `(hotkey,coldkey,netuid)` | view |
| `transferStake` | `CloneBase.sol:47` (via `flush`) | `(destColdkey,hotkey,netuid,netuid,amount)` | reverts → bubbles |
| `moveStake` | `SubnetClone.sol:18` | `(from,to,netuid,netuid,amount)` | reverts → bubbles |
| `removeStake` | `CloneBase.sol:66` (via `sellAlphaForTao`) | `(hotkey,amount,netuid)` | reverts → bubbles |
| `getAlphaPrice` | `AlphaVault.sol:239,381,431,561,802` | `(netuid)` | view, e18, rounds down |
| `simSwapAlphaForTao` | `AlphaVault.sol:816,825` | `(netuid,u64)` | rejected sim consumes all gas |
| `getNominatorMinRequiredStake` | `AlphaVault.sol:356` | — | view |
| `getDefaultMinStake` | `AlphaVault.sol:745` | — | view |
| `getHotkeySuccessor` | `VaultReads.sol:172` | `(hotkey,netuid)` | view |
| `getNetworkRegistrationBlock` | `AlphaVault.sol:175`, `VaultReads.sol:56` | `(netuid)` | view |
| `isSubnetDissolving` | `VaultReads.sol:63` | `(netuid)` | view |
| `addressMapping` | `VaultReads.sol:24` | `(evmAddress)` | view, H160→SS58 via `HashedAddressMapping<BlakeTwo256>` |

**4. Privileged functions** — `AlphaVault` has **no admin/owner**. The only privileged role is
`ValidatorRegistry` `DEFAULT_ADMIN_ROLE` → `setSigners` (`ValidatorRegistry.sol:110`).
Clone entry points gated by `onlyWrapper` (`CloneBase.sol:22`).

**5. Deposit / withdrawal paths**
- Deposit (`wrap:216`) — mailbox balance → flush → consolidate → rebalance → settle → mint.
- Live unwrap (`unwrap:294`) → consolidate → gather → flush to user coldkey → re-split → settle.
- TAO unwrap (`unwrapForTao:327`) → two-round sell → pay TAO → re-mint refund shares.
- Dissolved unwrap (`_unwrapFromDissolvedSubnet:525`) → pro-rata TAO from clone minus liability.

---

## PHASE 2 + 3 — FINDINGS

### HIGH

**H1 — `wrap` share-price manipulation via AMM slippage; no slippage floor on deposits** → **Fixed (minSharesOut, PR #57)**
- `AlphaVault.sol:258-267`, `AlphaVault.sol:236-245`.
- Rate = `preStake = totalAlpha - totalDeposit` where `totalAlpha` is post-deposit settled sum.
`flush` (`transferStake`) and `moveStake` rebalances trade against the CPMM. A holder can sandwich
a victim's `wrap` so the victim's `preStake` is deflated → fewer shares. No `minSharesOut` on `wrap`,
unlike `unwrapForTao`'s `minTaoOut`.
- Anchor: AMM/exchange-rate manipulation; deposit sandwich.
- Status: fixed on main via PR #57 — `wrap` now takes `minSharesOut`; the user guide documents it.

**H2 — `unwrapForTao` exit sells move the pool; stayers absorb price impact** → **Info (documented)**
- `AlphaVault.sol:361-376` (mechanism), NatSpec at `AlphaVault.sol:309-330` (documented),
`docs/user-guide.md` (Exiting), `docs/edge-cases.md` (disable-transfers), `docs/security-model.md`
(known tradeoffs).
- `unwrapForTao`'s two-round `removeStake` sells move the CPMM price permanently. Proceeds go to
the withdrawer (`minTaoOut`-bounded); the depressed price stays with remaining holders.
- Classification after the docs pass: the asymmetry is now **documented as opt-in** — `unwrap` is
the default exit (no pool interaction), `unwrapForTao` is marked risk-on, reserved for the cases
`unwrap` cannot serve (disabled alpha transfers, sub-floor positions).
- Anchor: unstaking asymmetry; who eats slippage. Status: Info — accepted design asymmetry,
documented in NatSpec + user guide + edge-cases + security model.

### MEDIUM

**M3 — `recoverStray` / `syncBacking` griefing keeps `BackingShortfall` frozen**
- `AlphaVault.sol:967-999`, `AlphaVault.sol:1030-1072`.
- `recoverStray` partially recovers → resets `shortSince=0` and re-anchors `tracked` higher
(`:996-997`), which can re-trigger shortfall → keeps all rails frozen (`wrap`/`unwrap` DoS).
`syncBacking` only writes off after `recoveryWindow` per slot, reset whenever state changes.
- Anchor: first-principles/liveness; recovery asymmetry.

**M4 — Rounding floors accumulate on the dissolved path; final holder stranded**
- `AlphaVault.sol:525-534`, `VaultMath.sol:76-78` (`proRata` floors).
- Floored dust accumulates in the clone; last holder's `proRata` of shrunk backing/supply can't
capture it; no sweep path for clone residue on a dissolved token. Permanently locked dust.
- Anchor: rounding direction; accumulation.

**M5 — `syncAmounts` ceil-rounding of `liabilityIncrease` over-reserves**
- `VaultMath.sol:110-118`, consumed at `AlphaVault.sol:1229-1232`.
- Ceil ensures no under-reserve but accumulates excess `taoLiability` (up to 1 wei per sync),
reducing `unreservedTao` for the dissolved path. Compounds with M4.
- Anchor: rounding direction; accumulation.

### LOW / INFO

**L6 — Floor-check band between `_isBelowFloorAtReadPrice` and `_AtAnyPrice` causes gas-burning reverts**
- `AlphaVault.sol:752-754` vs `758-760`.
- Amounts in the quantum band pass EVM pre-check but revert on-chain. Deliberate but wastes gas.
- Likelihood: low. Impact: gas only.

**L7 — `syncBacking` uses `block.timestamp`, forge-lint disabled**
- `AlphaVault.sol:1054,1059`. 12s blocks, window is presumably days → negligible.

**L8 — Attestation nonce per-netuid +1 (races intentional, no cross-netuid replay)**
- `ValidatorRegistry.sol:174-176`. Info.

### Categories with ZERO findings (explicitly checked)

- **Precompile return values:** all state-changing calls revert on failure; no bool-ignore bug.
- **Reentrancy across precompile boundary:** precompiles don't call back; `nonReentrant` on all
  state-mutating externals; `_update` settles debt before callbacks. Clean.
- **Approve/pull-in:** mailbox model replaces approve/pull; balance read from chain
  (`_mailboxBalance`, `AlphaVault.sol:1192`), not from passed amount. No stale-approval bug.
- **Address confusion (H160/SS58):** `coldkeyOf` uses chain's own `HashedAddressMapping`; mailbox
  clones deterministic, vault-initialized. No mirror-redirection bug.
- **ERC-1155 conformance:** `ERC1155+ERC1155Supply` override consistent. Clean.
- **Upgradeability/proxy storage:** EIP-1167, no upgradeable proxy, implementation locked in
  constructor (`CloneBase.sol:19`). Clean.

### UNVERIFIED → now resolved (subtensor source read, this branch)

- **U1 — `simSwapAlphaForTao` rejection is a bounded revert, not OOG. RESOLVED.**
  `precompiles/src/alpha.rs:175-190` records a fixed `9 db reads` *before* `sim_swap`; `sim_swap`
  error → `PrecompileFailure::Error(Other(...))` (normal revert). Furthermore
  `pallets/swap/src/pallet/impls.rs:471-497`: for mechanism `1` (the main AMM) `sim_swap` calls
  `swap(..., should_rollback=true)`, which rolls back instead of erroring, so on live subnets the
  sim *cannot* revert from a priced failure. The `_sellableChunk` gas-grief hypothesis is dead.
  Note: `IAlpha.sol:12`'s "consumes all forwarded gas" comment overstates the risk and is now
  misleading.

- **U2 — `getDefaultMinStake` as upper bound for transfers/moves. RESOLVED — the assumption
  HOLDS but the bound is wrong.** Transfer/move routes enforce `DefaultMinTransfer`
  (`runtime/src/lib.rs:842` = 0.0001 TAO), while the vault floors on `DefaultMinStake`
  (0.002 TAO) — a 20× mismatch. Same-subnet paths (`transfer_stake_within_subnet`,
  `staking/stake_utils.rs:1123`: `tao_equivalent >= DefaultMinTransfer`) confirm a lower floor,
  so the vault is *conservative wrong-way*: it refuses some moves the chain would accept (the
  comment at `AlphaVault.sol:741-745` admits this), and exits via the TAO rail compensate. The
  math is safe; the UX tradeoff is a tighter-than-needed floor.

- **U3 — Dissolution refund is ATOMIC in one cleanup run, not tranched. RESOLVED.**
  `pallets/subtensor/src/subnets/dissolution.rs:646-703`: cleanup runs to completion per
  netuid (phase-limited by `WeightMeter`, but the netuid is only dequeued once
  `cleanup_completed`), and only then is `CurrentDissolveCleanupStatus` killed. The precompile
  `getNetworkRegistrationBlock` reads `NetworkRegisteredAt` (still set during cleanup);
  `isSubnetDissolving` reads queue membership, which stays true for the whole run. So by the
  time `unwrap` on the dissolved path unlocks, the refund is fully credited — no partial-refund
  payout is possible. The vault's blackout logic (`SubnetInDissolutionBlackoutPeriod`) is
  exactly the right guard.

No residual U-items remain.

### Composite chain
- **[H1] + [H2]:** sandwich-underpriced shares → immediate `unwrapForTao` exit converts theft to TAO
  while externalizing exit slippage. Feasible in one 12s block.
- **Status after this change:** H1 closed by `minSharesOut` (PR #57). H2's exit-impact externalization
  remains as documented opt-in behavior, so the chain is broken at its entry (no longer possible to
  enter under-priced without explicit tolerance).

---

## Notes

- Execution: run serially in read-only mode; every cited line personally read. All Subtensor-specific
  classes worked explicitly; precompile semantics verified against subtensor source, not assumed.
- No fixes proposed (per rules).
