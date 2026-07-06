# Convicted (Locked) Alpha — Wrapper Readiness Assessment

Date: 2026-07-06.
Subtensor ref: branch `pg/add_precompile_for_extracting_minimal_movable_stake_value` @ `5037041e0` (includes current main lineage).
Docs ref: `~/Projects/developer-docs` (conviction-staking.md et al.).
Wrapper ref: current working tree.

## Verdict

**The wrapper is ready.** Convicted alpha is refused at wrap time and cannot break any
contract flow. The refusal is entirely **chain-enforced** (not contract-detected): locked
alpha physically cannot arrive under any vault-controlled coldkey, so `wrap` sees a zero
mailbox balance and reverts cleanly. All other flows are untouched because vault-held
stake can never be locked. Two follow-ups are recommended (test coverage, off-chain
preflight); neither blocks readiness.

## 1. What convicted alpha is (chain mechanics, verified)

- `lock_stake(hotkey, netuid, amount)` (call 136) lets a coldkey lock part of its own
  staked alpha on a subnet to a "conviction hotkey". One lock per `(coldkey, netuid)`,
  keyed to a single hotkey (`Lock` NMap, `lib.rs:1536-1546`; top-up to a different hotkey
  reverts `LockHotkeyMismatch`).
- `LockState { locked_mass, conviction, last_update }` (`staking/lock.rs:14-24`).
  `locked_mass` **decays exponentially** by default (τ = `UnlockRate` = 934,866 blocks,
  ~90-day half-life); `set_perpetual_lock` (call 138) freezes it. Conviction matures
  toward the locked mass (`MaturityRate`) and currently drives **nothing live**: the
  conviction-based subnet-owner takeover is commented out — "inactive by design"
  (`run_coinbase.rs:414-416`; developer-docs claiming it "active as of spec 425" are
  ahead of the code). No emission boost, no governance weight (docs confirm: "Locking
  does not affect emissions").
- **Enforcement invariant:** the coldkey's *total* alpha on that subnet cannot drop below
  `locked_mass`. `ensure_available_to_unstake` (available = total − individual lock,
  `lock.rs:726-751`) gates: `remove_stake` / `remove_stake_limit` (`stake_utils.rs:1182`),
  `burn_alpha` / `recycle_alpha`, order-book swaps, and **cross-subnet** move/transfer/swap
  (`stake_utils.rs:1327-1331` — cross-subnet only, comment explicit). `unstake_all`
  variants silently skip a locked subnet. Same-subnet `move_stake` is unrestricted
  (coldkey-subnet total unchanged).
- **Same-subnet `transfer_stake` clamps, then lock-follows** (`transfer_lock`,
  `lock.rs:1803-1949`): the unlocked portion moves first and arrives **unlocked**
  (`available_transfer = min(amount, total − locked)`, :1852-1858); only the remainder
  dips into locked mass, moves the lock+conviction to the destination, and requires the
  destination to accept (`ensure_can_receive_locked_alpha`, :1898) — else the **whole
  extrinsic reverts `AccountRejectsLockedAlpha`** (test-confirmed, `tests/locks.rs:2290`).
- **Accept flag:** `AccountFlags` bit 0 (`lib.rs:70-71,1197-1199`);
  `account_rejects_locked_alpha = flags & 1 != 1` → **default = reject**
  (`lock.rs:470-472`). Settable only via native `set_reject_locked_alpha` (call 142).
- **Visibility:** locked alpha stays inside the normal Alpha share ledger — `getStake`
  **includes** it — and keeps earning emission. Movable amount is exposed only via
  runtime API `StakeInfoRuntimeApi::get_stake_availability_for_coldkeys` →
  `{total, locked, available}` (`runtime-api/src/lib.rs:71`). Note `StakeInfo.locked` is
  hard-coded 0 (`stake_info.rs:79`) — never use it.

## 2. Why the wrapper is safe — six angles

**A. Inbound (wrap).** Deposits reach the vault only via the user's *own*
`transfer_stake` into their per-`(user, netuid)` mailbox coldkey. Mailbox and subnet
clones are contract-controlled EVM-mapped coldkeys: they can never sign
`set_reject_locked_alpha`, and **no precompile exposes any lock extrinsic** (grep of
`precompiles/src` = zero hits; `IStaking.sol` carries only
transferStake/moveStake/getStake/removeStake). So every vault coldkey **permanently
rejects locked inflow**. Outcomes for a user with a lock:
- transfer ≤ movable → succeeds, alpha arrives **unlocked**, wrap proceeds normally.
  Only free alpha ever gets wrapped — exactly the intended policy.
- transfer > movable → whole extrinsic reverts `AccountRejectsLockedAlpha` **before the
  vault is involved**. Nothing arrives.

**B. Wrap flow integrity.** `wrap` (`AlphaVault.sol:150-193`) is balance-delta based: it
reads the live mailbox balance (`getStake`, :178) and reverts `ZeroAmount` (:179) /
`DepositTooSmall` (:180) if nothing usable arrived. The mailbox keeps **no deposit
ledger** (`CloneBase` storage = `wrapper`+`initialized` only), mailboxes are per-user
isolated, and the whole tx is atomic — a failed/never-arrived deposit persists nothing,
blocks nobody, and cannot double-count concurrent deposits.

**C. Vault-held stake can never be locked.** Locks are created only by the owning
coldkey signing `lock_stake` (impossible for clones), received only with accept-flag
opt-in (impossible), or migrated by coldkey-swap (root-gated / native-signed —
unreachable; destination with active locks is rejected anyway, `swap_coldkey_locks`).
`swap_hotkey` only relocates **existing** lock entries; third parties cannot lock
someone else's stake (all four lock extrinsics are `ensure_signed` on the caller's own
coldkey). Subnet-owner/hotkey locks are conviction aggregates that never encumber a
delegator's unstake (`get_current_locked` reads only the individual lock,
`lock.rs:598-609,692-700`). The disabled owner-takeover moves no delegator stake even if
enabled. Coinbase auto-lock (`auto_lock_owner_cut`) touches only the subnet owner and
defaults off (`OwnerCutAutoLockEnabled` default `false`; note the storage doc-comment at
`lib.rs:1605-1606` wrongly says "default true" — upstream doc nit). ⇒ For every vault
coldkey, `available == total` forever: **unwrap, unwrapForTao, rebalance, sweep, flush
and dissolution can never hit `StakeUnavailable`/lock errors.**

**D. Unwrap to users with their own locks.** `transfer_lock` **no-ops when the origin
has no lock** (`lock.rs:1812,1823-1827`). The vault (lock-free origin) can therefore
transfer to any user — including one with an existing conviction lock on the same
subnet — with no accept-flag requirement and no `LockHotkeyMismatch` (both trigger only
when locked mass actually moves). A locked-up user can always receive their unwrap.

**E. Pricing immunity.** Share pricing reads only vault-coldkey balances
(`preStake = totalAlpha − totalDeposit` over the subnet clone, `AlphaVault.sol:184-187`;
`totalStake`/`sharePrice`/previews likewise). User coldkeys never enter the basis, and
vault coldkeys can't hold locked alpha, so `getStake`-includes-locked is harmless.
No path lets a third party park immovable alpha inside the pricing set.

**F. Dissolution.** `destroy_alpha_in_out_stakes` calls `destroy_lock_maps` — all lock
records for the netuid are wiped before pro-rata TAO liquidation (`remove_stake.rs:665`;
docs concur: "lock records are deleted before liquidation runs", conviction gives no
dereg protection). Locked users get TAO like everyone; the vault's dissolved-position
redemption is native-TAO-only and unaffected.

## 3. Failure-mode walkthroughs

| Scenario | On-chain outcome | Wrapper outcome |
|---|---|---|
| User, 100α with 40α locked, transfers 60α to mailbox, wraps | Transfer succeeds, arrives unlocked; lock stays with user | Normal wrap of 60α |
| Same user transfers 61α | Whole `transfer_stake` reverts `AccountRejectsLockedAlpha` (opaque `ExitError::Other` if sent via precompile) | Vault never involved; a later `wrap` reverts `ZeroAmount` — clean, nothing persisted |
| User wraps free alpha, then locks their remaining stake | Lock applies to user's own residual only | No effect on vault (its alpha is under vault coldkeys) |
| Locked user unwraps shares | Vault `transferStake` → user succeeds (origin lock-free ⇒ `transfer_lock` no-op) | Normal unwrap; user's own lock unaffected |
| Locked user on a dissolving subnet | Chain wipes locks, pays TAO pro-rata | Vault redemption path unaffected |

Precompile error surfacing (context for support/UX): pallet-level rejections come back as
`PrecompileFailure::Error { ExitError::Other("dispatch execution failed: <Variant>") }` —
an exceptional halt with empty returndata, not a decodable revert
(`precompiles/src/extensions.rs:106-118`). Callers can't branch on the variant; the
wrapper never needs to (atomic revert is the desired behavior everywhere).

## 4. Gaps and recommendations (ranked)

1. **Test coverage (do).** `MockStaking` models no locks: no per-key locked mass, no
   accept flag; `transferStakeReverts` is a global bool. The refusal property exists
   in-repo only as prose (`audit-prep-findings.md:108`). Add to the mock: per-
   `(coldkey, netuid)` `lockedMass` + per-coldkey accept flag; make `transferStake`
   clamp-check like `transfer_lock` and `removeStake` enforce `available`. Tests:
   partial-lock user wraps movable portion (succeeds); inbound over-movable transfer
   rejected at mock level → `wrap` → `ZeroAmount`; regression tripwire that no vault flow
   moves more than `available` from a vault coldkey.
2. **Off-chain preflight (do, small).** The contract cannot read lock state on-chain
   (no precompile view; `Lock`/`AccountFlags` are Blake2_128Concat-keyed, so the 0x807
   storage-query key is underivable in-EVM). Frontend/SDK should preflight deposits with
   `get_stake_availability_for_coldkeys` and cap the suggested amount at `available`,
   so users never hit the opaque `AccountRejectsLockedAlpha` halt.
3. **Optional subtensor view (nice-to-have, fits current branch).** A
   `getStakeAvailability(bytes32 coldkey, uint256 netuid) → (total, locked, available)`
   view on staking V2 would let the vault (and any integrator) preflight on-chain and
   emit a reasoned revert. Natural sibling of `getStakeOperationThreshold`. Not required
   for safety.
4. **Terminology hygiene (note).** Repo docs use "locked alpha" for TransferToggle-stuck
   alpha (`docs/superpowers/specs/2026-05-25-locked-alpha-tao-sale-design.md`,
   `docs/non_transferable_alphas.md`) — unrelated to conviction locks. Keep the terms
   distinct ("convicted/conviction-locked" vs "non-transferable/toggle-locked").
5. **Invariant to preserve (standing).** Never add a wrapper path that (a) opts a clone
   into accepting locked alpha, (b) exposes proxy registration from a clone, or
   (c) prices against non-vault coldkeys. Today none exists.
6. **Branch-name clarification.** `getStakeOperationThreshold` returns the flat
   `DefaultMinStake` (2,000,000 rao TAO-equivalent, u64→U256, no price conversion,
   no netuid arg, no lock awareness) — useful for the H-1 floor work but unrelated to
   convicted alpha; per-subnet alpha floors still need client-side conversion via
   `getAlphaPrice`/`simSwapAlphaForTao` (0x808).

## 5. Verification provenance

Personally verified at file:line (not agent-trusted): `lock.rs:470-503` (default-reject +
accept gate), `lock.rs:1803-1917` (clamp-first transfer_lock, origin-no-lock no-op),
`stake_utils.rs:1160-1214` (remove/unstake-all lock gates), `stake_utils.rs:1280-1331`
(cross-subnet-only sender gate), `run_coinbase.rs:405-422` (takeover disabled),
`precompiles/src/staking.rs:392-401` (+ zero-hit grep for lock extrinsics in
`precompiles/src`), `AlphaVault.sol:150-193`, `CloneBase.sol` (whole file),
`IStaking.sol` (whole file). Agent-sourced with consistent cross-checks: storage/extrinsic
inventory, enforcement matrix, docs corpus, mock gap analysis. One agent claim was
corrected during verification: the sender-side availability check on `transfer_stake` is
cross-subnet-only; same-subnet over-movable transfers are stopped by the destination
accept gate instead (same net effect for the vault).
