# scripts/

Python tooling for the alpha-wrapper contracts: read-only on-chain observability
readers and the shared library they build on.

| Script | Description |
|---|---|
| `get_deposits.py` | `Deposited` events |
| `get_unwraps.py` | Live-subnet `Unwrapped` events, including the successful alpha payout |
| `get_rebalances.py` | `Rebalanced` events |
| `get_subnet_proxies.py` | `SubnetProxyCreated` events |
| `get_validator_updates.py` | `ValidatorsUpdated` events |
| `get_volumes.py` | Unit-safe alpha and TAO unwrap metrics, with optional user filter |
| `get_vault_state.py` | Returns on-chain data about an ERC-1155 token for a subnet |
| `common.py` | Shared web3/ABI/CSV helpers imported by the scripts above and by `../e2e/chain_ops.py` |

Run `forge build` first -- the Python scripts load ABIs from `out/`.

Volume column suffixes identify their units: `_rao` is raw alpha (1e-9 alpha) and `_wei`
is native TAO (1e-18 TAO). Shares are raw ERC-1155 share units. Live alpha payouts,
nominal alpha requested for TAO, and actual TAO payouts remain distinct; only values with
the same unit are rolled up.

The end-to-end tests and their harness live in [`../e2e/`](../e2e/).
