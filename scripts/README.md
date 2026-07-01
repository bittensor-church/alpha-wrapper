# scripts/

Python tooling for the alpha-wrapper contracts: on-chain observability readers,
chain-operation subcommands, and the shared library they build on.

| Script | Description |
|---|---|
| `get_deposits.py` | `Deposited` events |
| `get_unwraps.py` | `Unwrapped` events |
| `get_rebalances.py` | `Rebalanced` events |
| `get_subnet_proxies.py` | `SubnetProxyCreated` events |
| `get_validator_updates.py` | `ValidatorsUpdated` events |
| `get_volumes.py` | Deposit/Unwrap totals for a subnet with optional user filter |
| `get_vault_state.py` | Returns on-chain data about an ERC-1155 token for a subnet |
| `chain_ops.py` | Chain-operation subcommands (H160<->SS58, `transfer_stake`, `set_validators`, `toggle_transfer`) |
| `common.py` | Shared web3/ABI/CSV helpers imported by the scripts above |

Run `forge build` first -- the Python scripts load ABIs from `out/`.

The end-to-end tests and their harness live in [`../e2e/`](../e2e/).
