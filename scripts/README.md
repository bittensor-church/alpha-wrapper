# scripts/

| Script | Description |
|---|---|
| `get_deposits.py` | `Deposited` events |
| `get_unwraps.py` | `Unwrapped` events |
| `get_rebalances.py` | `Rebalanced` events |
| `get_subnet_proxies.py` | `SubnetProxyCreated` events |
| `get_validator_updates.py` | `ValidatorsUpdated` events |
| `get_volumes.py` | Deposit/Unwrap totals for a subnet with optional user filter |
| `get_vault_state.py` | Returns on-chain data about an ERC-1155 token for a subnet |
| `e2e_helpers.py` | Subcommands for the localnet-e2e tests (H160<->SS58, `transfer_stake`, `set_validators`, `toggle_transfer`) |
| `e2e_common.sh` | Shared config + helpers + bootstrap (phases 0-5) sourced by the localnet-e2e tests |
| `localnet-e2e.sh` | Full end-to-end flow against a local subtensor |
| `localnet-e2e-transfers-off.sh` | E2E with subnet alpha transfers disabled: alpha rail reverts, TAO rails still pay |

Run `forge build` first -- the Python scripts load ABIs from `out/`.
