# e2e/

Localnet end-to-end tests. Run from the repo root against a local subtensor (see
the prerequisites in each script's header). The tests source `e2e_common.sh` and
call the Python tooling in [`../scripts/`](../scripts/).

| File | Description |
|---|---|
| `localnet-e2e.sh` | Full end-to-end flow against a local subtensor |
| `localnet-e2e-transfers-off.sh` | E2E with subnet alpha transfers disabled: alpha rail reverts, TAO rails still pay |
| `localnet-e2e-convicted-alpha.sh` | E2E with conviction-locked alpha: over-movable deposits refused on-chain, movable portion wraps, vault flows and unwraps unaffected |
| `localnet-e2e-subnet-dissolved.sh` | E2E with a dissolved subnet: dissolved unwrap and mailbox reclaim recover native TAO, alpha rails revert, untouched subnet unaffected |
| `localnet-e2e-min-stake-floor.sh` | E2E for min-stake floor handling: the wrap gate binds between the chain floor and a raised vault floor, rotated-out dust is consolidated by the next wrap, sub-floor rebalance moves are skipped in-budget |
| `e2e_common.sh` | Shared config + helpers + bootstrap (phases 0-5) sourced by the tests |
| `verify_csv.py` | Asserts invariants on the CSV output of the `../scripts/` observability readers |

Usage (from the repo root, so the `scripts/...`/`src/...`/`out/...` paths resolve):

```sh
./e2e/localnet-e2e.sh
./e2e/localnet-e2e-transfers-off.sh
```
