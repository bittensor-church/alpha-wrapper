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
| `plan_tao_exit.py` | Pre-flight for a TAO exit: per-slot quotes, the exclusion mask, a dry run |

`get_vault_state.py` and `plan_tao_exit.py` require `--lens-address` and
`--vault-address`. Use a trusted lens: checking its `vault()` catches a mismatch,
not fabricated quotes.

`get_validator_updates.py` defaults to the attested registry. Pass
`--registry-type basic` to decode `BasicValidatorRegistry.ValidatorUpdated` events.
The CSV schema is the same, with `count` equal to one.

Units: `_rao` columns are alpha at 9 decimals; `_wei` columns are native TAO at
18 decimals. Shares are raw ERC-1155 units. Alpha payouts, alpha requested for sale
and actual TAO proceeds are separate metrics, never summed across units. Burn columns
are gross; the shares a TAO exit mints back for alpha it left unsold are reported
separately as `tao_unwrap_shares_refunded` and stay out of `shares_minted`.

`common.py` supplies shared web3, ABI and CSV helpers to these tools and the
[e2e harness](../e2e/README.md). Recovery monitoring requirements are in the
[watcher runbook](../docs/hotkey-swaps.md).
