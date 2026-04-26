# scripts/

| Script | Description |
|---|---|
| `get_deposits.py` | `Deposited` events |
| `get_withdrawals.py` | `Withdrawn` events |
| `get_rebalances.py` | `Rebalanced` events |
| `get_subnet_proxies.py` | `SubnetProxyCreated` events |
| `get_validator_updates.py` | `ValidatorsUpdated` events |
| `get_validator_batch_updates.py` | `ValidatorsBatchUpdated` events |
| `get_volumes.py` | Deposit/Withdraw totals for a subnet with optional user filter |
| `get_vault_state.py` | Returns on-chain data about an ERC-1155 token for a subnet |
| `e2e_helpers.py` | Subcommands for `localnet-e2e.sh` (H160<->SS58, `transfer_stake`) |
| `localnet-e2e.sh` | Full end-to-end flow against a local subtensor; |

Run `forge build` first -- the Python scripts load ABIs from `out/`.
