# Observability scripts

Read-only Python tools for vault events and state. They load ABIs from `out/`;
build the contracts before using them.

| Script | Output |
| --- | --- |
| `get_deposits.py` | Deposits |
| `get_unwraps.py` | Live alpha exits, including actual alpha payout |
| `get_rebalances.py` | Weight-alignment moves |
| `get_subnet_proxies.py` | Clone creation |
| `get_validator_updates.py` | Registry updates |
| `get_volumes.py` | Alpha/TAO exit metrics, optionally filtered by user |
| `get_vault_state.py` | Token state and lens quotes |

`get_vault_state.py` requires `--lens-address` and `--vault-address`. Use a trusted
lens: checking its `vault()` catches a mismatch, not fabricated quotes.

Units: `_rao` columns are alpha at 9 decimals; `_wei` columns are native TAO at
18 decimals. Shares are raw ERC-1155 units. Alpha payouts, alpha requested for sale
and actual TAO proceeds are separate metrics, never summed across units.

`common.py` supplies shared web3, ABI and CSV helpers to these tools and the
[e2e harness](../e2e/README.md). Recovery monitoring requirements are in the
[watcher runbook](../docs/hotkey-swaps.md).
