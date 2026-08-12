# Alpha-Wrapper Observability Scripts — Design

**Date:** 2026-04-20
**Status:** Approved (verbal)
**Owner:** PawelGebal

## 1. Goal

Provide a small set of read-only Python CLI scripts that expose AlphaVault and ValidatorRegistry on-chain activity for validation, operational monitoring, and later incentive design. Modeled on the structure of `~/Projects/collateral/scripts/` (one file = one tool, CSV stdout, argparse), stripped of every signing / transaction path.

The TAO20Index mint/redeem volume requirement (in `~/Projects/tao20-contract`) is the parallel work; it gets its own mirror set later. This spec covers only the AlphaVault layer.

## 2. Non-goals

- No transaction signing, no key handling, no wallet code.
- No URL fetching / MD5 calculation (no analogue of collateral's `denyReclaim` flow exists).
- No live tail / daemon mode — block-range queries only.
- No `eth_getLogs` chunking / pagination — caller picks a range that fits the provider's limit. Documented as a known limitation; can be added later if a real consumer hits it.
- No on-chain TAO20Index event readers — separate spec, separate ABI.

## 3. Audience

Operators, validators, auditors. Anyone who wants to inspect vault flow without trusting a frontend or third-party indexer. Output is CSV everywhere so it pipes cleanly into spreadsheets / Grafana ingesters / `jq` / etc.

## 4. Layout

```
alpha-wrapper/
├── scripts/
│   ├── common.py
│   ├── get_current_block.py
│   ├── get_deposits.py
│   ├── get_withdrawals.py
│   ├── get_subnet_proxies.py
│   ├── get_rebalances.py
│   ├── get_validator_updates.py
│   ├── get_volumes.py
│   └── get_vault_state.py
└── requirements.txt
```

ABIs are loaded directly from forge build output (`out/{Name}.sol/{Name}.json`) at runtime — no separate ABI checkout, no copy step.

## 5. Shared infrastructure

### 5.1 `common.py`

Read-only subset of the patterns in `~/Projects/collateral/scripts/common.py`.

Functions:
- `RPC_URLS` dict — `{"finney": "https://lite.chain.opentensor.ai", "test": "https://test.chain.opentensor.ai"}`
- `get_web3_connection(network) -> Web3` — uses `RPC_URLS` first, falls back to `bittensor.utils.determine_chain_endpoint_and_network` for any other network name (e.g. `local`).
- `validate_address_format(address)` — raises `ValueError` if not a valid EVM address.
- `load_abi(contract_name) -> list` — loads `out/{ContractName}.sol/{ContractName}.json` (forge build output) and returns the `.abi` field. Raises a clear `FileNotFoundError` if forge hasn't built. Callers: `load_abi("AlphaVault")`, `load_abi("ValidatorRegistry")`.
- `decode_token_id(token_id) -> (netuid, reg_block)` — splits `(reg_block << 16) | netuid` (matches `AlphaVault.currentTokenId` / `_netuid` / `_regBlock`).
- `make_csv_writer(stream, fieldnames) -> csv.DictWriter` — thin convenience wrapper that calls `writeheader()` for the caller.

Explicitly **not** included (would need extending if write paths get added later):
- `get_account`, `build_and_send_transaction`, `wait_for_receipt`, `calculate_md5_checksum`, `get_revert_reason`.

### 5.2 ABI loading

ABIs are loaded directly from forge build output (`out/{ContractName}.sol/{ContractName}.json`). `out/` is gitignored, so the operator must run `forge build` once before running any script — `load_abi` raises a clear `FileNotFoundError` with that hint if the artifact is missing.

Rationale: keeping a copy under `scripts/abi/` introduces drift risk (forget to refresh after a contract change → silently stale ABI → events not decoded / topic-hash mismatches). Reading from `out/` makes forge the single source of truth.

### 5.3 Units in CSV

All amount fields are emitted as raw integers (no float conversion). Unit is encoded in the column suffix:
- `assets_rao` — alpha amount, 1 alpha = 1e9 rao (subtensor RAO precision).
- `shares` — raw ERC1155 share count, no canonical scale.
- `total_stake_rao` — same as `assets_rao`, applied to `AlphaVault.totalStake[tokenId]`.
- `share_price_e18` — raw value as returned by `AlphaVault.sharePrice()` (alpha-rao × 1e18 / shares); consumer divides by 1e18.
- `weight_bps` — basis points as stored in `ValidatorRegistry` (sum = 10000).

Rationale: avoids float precision loss; matches blockchain explorer convention; downstream consumer decides display formatting.

### 5.4 `requirements.txt`

```
web3>=7.10.0,<8.0
bittensor>=9.4.0,<10.0,!=9.5.0,!=9.6.0
```

`requests` from collateral's deps is intentionally omitted — no URL fetching.

### 5.5 Networks

Default `--network finney`. `RPC_URLS` covers `finney` and `test`. Any other name (including `local`) is resolved via `bittensor.utils.determine_chain_endpoint_and_network`.

## 6. Per-script CLI & CSV schema

### 6.1 `get_current_block.py`

- Args: `--network` (default `finney`).
- Output: single CSV column `block_number`.

### 6.2 `get_deposits.py`

- Source: `AlphaVault` event `Deposited(address indexed user, uint256 indexed tokenId, uint256 assets, uint256 shares, bytes32 hotkey)`.
- Args: `--vault-address`, `--block-start`, `--block-end`, `--network`.
- CSV columns: `block_number, tx_hash, log_index, user, token_id, netuid, reg_block, assets_rao, shares, hotkey_hex`.

### 6.3 `get_withdrawals.py`

- Source: `AlphaVault` event `Withdrawn(address indexed user, uint256 indexed tokenId, uint256 shares, uint256 assets, bytes32 hotkey)`.
- Args: `--vault-address`, `--block-start`, `--block-end`, `--network`.
- CSV columns: `block_number, tx_hash, log_index, user, token_id, netuid, reg_block, shares, assets_rao, hotkey_hex`.

### 6.4 `get_subnet_proxies.py`

- Source: `AlphaVault` event `SubnetProxyCreated(uint256 indexed tokenId, address clone)`.
- Args: `--vault-address`, `--block-start`, `--block-end`, `--network`.
- CSV columns: `block_number, tx_hash, token_id, netuid, reg_block, clone_address`.
- Doubles as the canonical "what tokenIds exist" discovery script.

### 6.5 `get_rebalances.py`

- Source: `AlphaVault` event `Rebalanced(uint256 indexed tokenId, uint8 moveCount)`.
- Args: `--vault-address`, `--block-start`, `--block-end`, `--network`.
- CSV columns: `block_number, tx_hash, token_id, netuid, reg_block, move_count`.

### 6.6 `get_validator_updates.py`

- Source: `ValidatorRegistry` events `ValidatorsUpdated(uint256 indexed netuid, uint8 count, uint256 timestamp)` and `ValidatorsBatchUpdated(uint256 subnetCount, uint256 timestamp)`.
- Args: `--registry-address`, `--block-start`, `--block-end`, `--network`.
- CSV columns: `block_number, tx_hash, event_type, netuid, validator_count, subnet_count, timestamp`.
  - `event_type` = `"ValidatorsUpdated"` or `"ValidatorsBatchUpdated"`.
  - For `ValidatorsUpdated`: `netuid` + `validator_count` populated, `subnet_count` blank.
  - For `ValidatorsBatchUpdated`: `subnet_count` populated, `netuid` + `validator_count` blank.

### 6.7 `get_volumes.py` (rollup)

- Args: `--vault-address`, `--block-start`, `--block-end`, `--by user|token_id|both`, `--network`.
- Internally fetches `Deposited` and `Withdrawn` over the range, groups by the chosen key.
- CSV columns:
  - `--by user`: `user, deposit_count, total_assets_in_rao, total_shares_minted, withdraw_count, total_shares_burned, total_assets_out_rao`.
  - `--by token_id`: `token_id, netuid, reg_block, deposit_count, total_assets_in_rao, total_shares_minted, withdraw_count, total_shares_burned, total_assets_out_rao`.
  - `--by both`: `user, token_id, netuid, reg_block, deposit_count, total_assets_in_rao, total_shares_minted, withdraw_count, total_shares_burned, total_assets_out_rao`.

### 6.8 `get_vault_state.py`

- Args:
  - `--vault-address` (required).
  - One of (mutually exclusive, exactly one required):
    - `--token-ids 12345,67890` — explicit list of full tokenId values.
    - `--netuids 12,42` — list of netuids; script computes `currentTokenId(netuid)` for each.
    - `--from-events --block-start N --block-end M` — discovers tokenIds via `SubnetProxyCreated` log scan.
  - `--registry-address` (optional). If provided, calls `ValidatorRegistry.getValidators(netuid)` per token and includes validator columns.
  - `--network`.
- View functions called per token:
  - `AlphaVault.totalSupply(tokenId)` (ERC1155Supply).
  - `AlphaVault.totalStake(tokenId)`.
  - `AlphaVault.sharePrice(tokenId)` — wrapped in try/except.
  - `AlphaVault.subnetClone(tokenId)`.
  - `ValidatorRegistry.getValidators(netuid)` if `--registry-address` given.
- CSV columns: `token_id, netuid, reg_block, total_supply, total_stake_rao, share_price_e18, share_price_error, subnet_clone, validator_count, validator_1_hotkey_hex, validator_1_weight_bps, validator_2_hotkey_hex, validator_2_weight_bps, validator_3_hotkey_hex, validator_3_weight_bps`.
  - Validator columns are blank if `--registry-address` not provided.
  - On `sharePrice` revert: `share_price_e18` blank, `share_price_error` set to the Solidity error name (`SubnetInDissolutionBlackoutPeriod`, `SubnetDissolved`, `NoSharesOutstanding`).

## 7. Edge cases & error handling

- **`sharePrice()` reverts** on dissolved / blackout / zero-supply tokens. `get_vault_state.py` catches `ContractLogicError`, emits empty `share_price_e18` and the decoded error name in `share_price_error`. Other callers don't touch `sharePrice`.
- **`eth_getLogs` provider limits.** Mirrors collateral: no chunking. If the caller picks too wide a range, the RPC returns an error; script bubbles it up as a non-zero exit. Future enhancement candidate.
- **TokenId discovery in `get_vault_state.py --from-events`** uses the same log-fetching code as `get_subnet_proxies.py`. First duplication; second occurrence triggers extraction into `common.py`.
- **Bytes32 → human formatting.** `hotkey_hex` columns are written as `0x` + 64 hex chars (raw). No ss58 conversion in v1 — adds bittensor SDK round-trip cost per row and we already require bittensor for the network resolver. Can be added later as a `--ss58` flag if a consumer needs it.
- **Network errors / RPC failures.** Each script wraps `main()` in `try/except` and prints `Error: <msg>` to stderr with exit code 1, matching collateral's pattern.

## 8. Testing strategy

Out of scope for v1 (matches collateral, which ships no Python tests). Verification path:
- Manual smoke test against testnet (`--network test`) once a vault is deployed there.
- Spot-check CSV row counts against block explorer (e.g. taostats / etherscan-equivalent).

If/when these scripts grow beyond the 8-script footprint, factor `common.py` into a package with unit tests then.

## 9. Open questions / explicit deferrals

| Item | Decision | Trigger to revisit |
|---|---|---|
| ss58 hotkey formatting | Deferred. Raw hex in v1. | Real consumer asks. |
| `eth_getLogs` chunking | Deferred. Caller picks range. | RPC range limit complaints. |
| TAO20Index event mirror | Separate spec, in `tao20-contract` repo. | After v1 ships. |
| Python tests | Deferred. | Script count > 8 or first regression bug. |
| Pinning ABI to a specific contract version | Deferred. Scripts read whatever `out/` currently contains. | If we need to inspect events from an older deployment whose ABI no longer matches `out/`. |
