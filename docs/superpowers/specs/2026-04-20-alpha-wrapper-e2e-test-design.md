# Alpha-Wrapper Localnet E2E Test — Design

**Date:** 2026-04-20
**Status:** Pending approval
**Owner:** PawelGebal

## 1. Goal

Add a single end-to-end script that exercises the alpha-wrapper deposit and withdraw paths against a real local subtensor node, plus a GitHub Actions workflow that runs it on every PR. Modeled as closely as possible on `~/Projects/tao20/scripts/localnet-e2e.sh` and `~/Projects/tao20/.github/workflows/e2e.yml`, trimmed to only alpha-wrapper surface area.

The purpose is smoke coverage of the real precompile call graph — `IStaking.transferStake` / `IStaking.getStake` / `IStaking.moveStake`, the `blake2b("evm:" + h160)` address mapping, and `StorageQueryReader` against live subtensor storage. Forge unit tests already cover logic against mocks; nothing in the unit-test suite catches a regression in, for example, the substrate account-id derivation or the legacy-tx gas envelope.

## 2. Non-goals

- No withdrawal in dissolved-subnet state. That path requires forcing a subnet dissolution on the localnet which is out of scope for a first cut; dedicated tests can be added later.
- No rebalance-only phase. Skewed stake ratios (3:2:1) already trigger `_findBestMove` inside `processDeposit`, so rebalance runs naturally and is covered without its own phase.
- No invariant / fuzz testing, no gas measurement, no multi-run matrix. One linear pass through deposit → withdraw.
- No fork tests (Foundry `vm.createFork` against bittensor mainnet / testnet). Local subtensor only.

## 3. Audience

Contract authors validating a change against the real chain before merging. CI consumers who want the PR gate to include live-chain smoke. Operators running the script by hand against a fresh localnet when triaging a suspected precompile-level regression.

## 4. Layout

```
alpha-wrapper/
├── scripts/
│   ├── localnet-e2e.sh   # the E2E driver
│   └── LOCALNET.md       # how to run it locally
└── .github/
    └── workflows/
        └── e2e.yml       # CI job
```

Python helpers are inlined as `python3 - <<PYEOF` heredocs inside the shell script (matches tao20). No separate `.py` file.

## 5. Script structure

Phases are numbered to match tao20's script one-for-one so anyone reading both side-by-side sees the correspondence.

| # | Phase | Purpose |
|---|---|---|
| 0 | Fund deployer | `btcli wallet transfer` 10 000 TAO Alice → `DEPLOYER_SS58` if deployer balance < 50. Skipped on reruns. |
| 1 | Create 3 subnets | `btcli subnets create` ×3, `btcli subnets start`, `btcli sudo set max_regs_per_block=8`. Honors `EXISTING_NETUIDS` env var. |
| 2 | Hotkeys + register | 3 hotkeys per subnet (`hk_e2e_1a..c`, `hk_e2e_2a..c`, `hk_e2e_3a..c`), `btcli subnets register` each with retry on rate-limit. |
| 3 | Stake TAO | Alice stakes `STAKE_RATIOS=(600 400 200)` TAO across the 3 validators per subnet. The 3:2:1 skew is deliberate — it forces `_findBestMove` to move stake during Phase 7, giving us real coverage of `SubnetClone.moveStake` and the `IStaking.moveStake` precompile without a dedicated rebalance phase. |
| 4 | Deploy contracts | `forge create` in this order: `DepositMailbox`, `SubnetClone`, `AlphaVault(uri, mailboxLogic, subnetLogic)`, `ValidatorRegistry(admin, updater)`. Then `cast send` to wire `AlphaVault.setValidatorRegistry`, push validators to `ValidatorRegistry.setValidators(netuid, hotkeys[], weights[])` with `[5000, 3000, 2000]` BPS split, and call `AlphaVault.createSubnetProxy(netuid)` for each of the 3 subnets. |
| 5 | User EVM account | Use fixed `WRAPPER_ADDR` / `WRAPPER_PK` (same values tao20 uses) so reruns hit the same account. `btcli wallet transfer` 100 TAO Alice → `WRAPPER_SS58` if balance < 5. |
| 6 | Alpha → clone | For each of the 3 vaults: call `AlphaVault.getDepositAddress(WRAPPER_ADDR, netuid)`, derive the clone's SS58 via `blake2b("evm:" + clone_h160)` + SS58 encoding, then `transfer_stake_py` 100 alpha from Alice to the clone via `SubtensorModule.transfer_stake`. Verify via `getStake(hotkey, clone_sub, netuid)`. |
| 7 | Process deposits | For each vault: `cast send AlphaVault.processDeposit(WRAPPER_ADDR, netuid, cloneSubstrateColdkey)` with `--legacy --gas-price 10000000000 --gas-limit 1000000`. |
| 8 | Verify deposits | Per vault, read `balanceOf(WRAPPER_ADDR, tokenId)`, `totalStake(tokenId)`, `sharePrice(tokenId)`. Hard-fail if any is 0. |
| 9 | Withdraw | **New code — no tao20 analogue.** For each vault: read `SHARES=balanceOf(WRAPPER_ADDR, tokenId)`, call `cast send AlphaVault.withdraw(tokenId, SHARES, WRAPPER_SUB_B32)`, then verify `balanceOf(WRAPPER_ADDR, tokenId) == 0`. Sum `getStake(hk, WRAPPER_SUB_B32, netuid)` across the 3 hotkeys per vault to confirm alpha was returned to the user's substrate account (tolerance `>= deposited - 10 RAO` to allow for rebalance rounding dust). |

## 6. What we reuse verbatim from tao20

These pieces are battle-tested against the same precompile / btcli / localnet surface. Copying them byte-for-byte avoids reinventing known-fragile glue.

- Pre-flight Alice wallet regen from `ALICE_COLDKEY_SEED` (handles the "wrong Alice" case and the "missing hotkey" case)
- Helper functions: `log`, `ok`, `info`, `fail`, `h160_to_substrate_b32`, `h160_to_ss58`, `btcli_cmd`, `transfer_stake_py`, `wait_for_zero`, `create_subnet`, `read_hotkey_pubkey`, `read_hotkey_ss58`
- Constants: `CHAIN_ENDPOINT=ws://127.0.0.1:9944`, `RPC_URL=http://127.0.0.1:9944`, `CHAIN_ID=42`, `ALICE_WALLET`, `ALICE_HOTKEY_NAME`, `ALICE_COLDKEY_B32`, `DEPLOYER_ADDR`, `DEPLOYER_PK`, `DEPLOYER_SS58`, `STAKING=0x805`
- The `EVM_FLAGS` / `FORGE_FLAGS` / `CAST_FLAGS` triplet — Bittensor's EVM requires legacy txs with explicit gas price/limit; omitting those is the #1 cause of silent failures.
- Phase 1 subnet creation (`printf '\n\n\n\n\n\n\n\n\n\n' | btcli subnets create ...`), Phase 2 hotkey + register with retry, Phase 3 stake loop
- Phase 4 `forge create` idiom (`--private-key ... --rpc-url ... $FORGE_FLAGS --json | python3 -c "import json,sys; print(json.load(sys.stdin)['deployedTo'])"`)
- Phase 6 clone address derivation + `transfer_stake_py` usage

## 7. What we drop from tao20

tao20 has steps that only make sense because the TAO20Index protocol layers on top of alpha-wrapper. None of them apply here.

- **Phase 4 — BasketManager / PriceOracle / TAO20Index deploy.** None of these exist in this repo. Phase 4 shrinks from 7 contracts to 4.
- **Phase 5b — "Fund substrate wallet test account."** Pre-stakes alpha to a substrate-only SS58 for the TAO20 substrate-path deposit. Irrelevant without TAO20Index.
- **Phase 5c — "Stake alpha for EVM wrapper user."** Pre-stakes alpha to the wrapper user across all validators so TAO20 can mint from existing positions. In alpha-wrapper the only way to get alpha into the system is via Phase 6.
- **Phase 9 — TAO20 basket propose / timelock / accept / mint.** No basket manager to propose to.
- **Phase 10 — TAO20 burn path.** No TAO20 tokens to burn.

Concretely: our script is ≈ (tao20 phases 0–8, Phase 4 trimmed) + our new Phase 9 withdraw.

## 8. Configuration & idempotency

Knobs at the top of `localnet-e2e.sh`, same style as tao20:

```bash
CHAIN_ENDPOINT="ws://127.0.0.1:9944"
RPC_URL="http://127.0.0.1:9944"
DEPLOYER_ADDR="0x7bD3E0F025FC388e08dd2A63595dbcaB486F335b"
DEPLOYER_PK="0x58a595a0863f6894cf22d465014abf7c7ca5b46fc8dd7e7e932d158002c33039"
WRAPPER_ADDR="0xd10375caed456c5902D7B155117Dd155398145C7"
WRAPPER_PK="0xf784bf897e423437b1d2a1584a7fc5c99b0ec3f34d70ff74a0643094ccfd4bbe"
STAKE_RATIOS=(600 400 200)
TRANSFER_AMOUNT=100
HK_SUFFIXES=(a b c)
```

Reuse patterns:

- `EXISTING_NETUIDS=4,5,6 ./scripts/localnet-e2e.sh` — skip Phase 1 subnet creation (expensive, ~1–2k TAO per subnet). Phase 1 still forces `max_regs_per_block=8` on each netuid in case it wasn't set.
- Phase 2 tolerates already-registered hotkeys — `btcli subnets register` output is matched for `Registered\|Already`; either counts as success.
- Phases 0 and 5 skip their transfers when the target account already has > threshold balance.

No cleanup phase — the script is additive against whatever state the localnet is already in. A truly fresh run is achieved by restarting the subtensor container.

## 9. Failure model

Every phase after 0 uses `fail "..."` (red ✗, `exit 1`) on unrecoverable error. Assertion points:

- Phase 4: `forge create` failed parse of `deployedTo` from the `--json` output.
- Phase 6: `getStake(hotkey, clone_sub, netuid) == 0` after `transfer_stake_py` returned success.
- Phase 7: `cast send processDeposit` returned `status != 0x1`.
- Phase 8: `balanceOf == 0` or `totalStake == 0` for any vault.
- Phase 9: `balanceOf != 0` after withdraw; OR user's summed `getStake` across hotkeys for a vault is `< deposited_amount - 10 rao`.

Tolerance: `_findBestMove` uses `moveStake` which rounds at ≤ 1 rao per hop. With up to 2 moves per deposit and up to 2 moves per withdraw, we allow ≤ 10 rao slippage per vault before failing Phase 9 — comfortably above observed drift, well below anything that could mask a real bug (all amounts are on the order of 1e11 rao).

## 10. CI workflow

File: `.github/workflows/e2e.yml`. Direct port of `~/Projects/tao20/.github/workflows/e2e.yml` with three diffs:

```
diff <tao20/.github/workflows/e2e.yml> <alpha-wrapper/.github/workflows/e2e.yml>

- on:
-   push:
-     branches: [main]
-   pull_request:
-   workflow_dispatch:
+ on:
+   pull_request:
+   workflow_dispatch:
```

*Rationale: test.yml in this repo already uses PR+dispatch triggers; staying consistent. E2E runs on PRs, not post-merge.*

```
- - name: Post-E2E on-chain sanity checks
-   run: |
-     ... (40 lines of cast calls)
```

*Rationale: the checks that step performs (contracts have code, total supply > 0, basket non-empty) are alpha-wrapper irrelevant or already done inside Phase 8/9 of the script. Removing them removes a whole class of "env vars not propagated between steps" CI noise.*

Kept unchanged: `services.subtensor` (same `ghcr.io/opentensor/subtensor-localnet:main` image on port 9944), `actions/checkout@v5` with `submodules: recursive`, `foundry-rs/foundry-toolchain@v1`, `actions/setup-python@v5` with `python-version: "3.11"`, `pip install bittensor-cli==9.15.3`, the `Wait for subtensor to be ready` loop (30 tries × 2s polling `cast chain-id`), and the `Collect subtensor logs on failure` step.

Workflow env: `FOUNDRY_PROFILE: ci`. Timeout: 30 minutes (same as tao20 — phase 1 subnet creation is the dominant cost at ~1 min per subnet).

## 11. Documentation

`scripts/LOCALNET.md` — condensed version of tao20's `scripts/LOCALNET.md`. Keep:

- Prerequisites table (local subtensor / btcli / forge / python3 / Alice wallet / funded EVM deployer)
- "Setting Up the Local Chain" section (start subtensor, import Alice)
- "Running the E2E Script" (fresh run, reuse via `EXISTING_NETUIDS`)
- "Troubleshooting" subsections for `SubtokenDisabled`, `NotEnoughBalanceToStake`, `execution fatal: Module(ModuleError { index: 22 })`, clone substrate coldkey mismatch, Alice wallet not found
- "Configuration Reference" table

Drop: the full phase-by-phase prose (replaced by a two-line summary pointing at the script), tao20-specific troubleshooting entries (`processDeposit reverts with ZeroAmount` for *tao20* reasons, basket timelock errors).

## 12. Open risks

- **Subtensor localnet image drift.** tao20's workflow pins `ghcr.io/opentensor/subtensor-localnet:main` — a floating tag. If the upstream image changes extrinsic encoding, `transfer_stake_py` can break silently. Same risk tao20 accepts; pinning to a SHA is a follow-up for both repos.
- **btcli version lock.** `bittensor-cli==9.15.3` is the version tao20's CI uses. Bumping it in isolation can shift CLI flag names. Left as-is; synchronize with tao20 when we bump.
- **Fixed wrapper private key in the script.** The `WRAPPER_PK` constant is a well-known localnet-only key (same one tao20 uses). Not a secret; still gets flagged by secret scanners. Annotated with a comment.
