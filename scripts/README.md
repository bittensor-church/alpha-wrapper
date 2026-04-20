# scripts/

Read-only observability scripts for AlphaVault / ValidatorRegistry, plus the
localnet end-to-end integration test.

Every Python script needs `--rpc-url`; event fetchers also need `--block-start`
and `--block-end`. All output CSV to stdout, progress to stderr.

| Script | Emits / does |
|---|---|
| `get_deposits.py` | `Deposited` events |
| `get_withdrawals.py` | `Withdrawn` events |
| `get_rebalances.py` | `Rebalanced` events |
| `get_subnet_proxies.py` | `SubnetProxyCreated` events |
| `get_validator_updates.py` | `ValidatorsUpdated` events |
| `get_validator_batch_updates.py` | `ValidatorsBatchUpdated` events |
| `get_volumes.py` | Deposit/Withdraw totals grouped by `--by {user,token_id,both}` |
| `get_vault_state.py` | `totalSupply`/`totalStake`/`sharePrice`/`subnetClone` per token, optional validators |
| `common.py` | Shared helpers (web3 connect, ABI load + drift assertion, CSV writer) |
| `e2e_helpers.py` | Subcommands for `localnet-e2e.sh` (H160<->SS58, `transfer_stake`) |
| `localnet-e2e.sh` | Full end-to-end flow against a local subtensor; exercises every Python script in Phase 10 |

Run `forge build` first -- the Python scripts load ABIs from `out/`.
