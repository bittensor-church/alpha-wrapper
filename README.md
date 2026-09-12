# alpha-wrapper

ERC-1155 shares of Bittensor staked alpha, with alpha and native-TAO exits.

## Documentation

- [Overview](docs/overview.md): contracts, shares and allocation.
- [User guide](docs/user-guide.md): deposits, exits and mailbox recovery.
- [Hotkey swaps](docs/hotkey-swaps.md): the empty-slot issue, automatic handling
  and watcher-assisted recovery.
- [Basic validator registry](docs/basic-validator-registry.md): one permanent admin and one target per subnet.
- [Attester guide](docs/attester-guide.md): signed validator weights.
- [Edge cases](docs/edge-cases.md): dissolution, minimums, disabled transfers and dust.
- [Security model](docs/security-model.md): authority, liveness dependencies and loss policy.
- [Deployment](docs/deployment.md): deploying the registry and vault set, and runtime compatibility.

## Layout

- `src/`: vault, read-only lens, clones, registry, shared stake operations, math
  and precompile interfaces. The vault links `VaultAllocation`, a deployed library
  holding its receiving-key rules, stake consolidation, payout gathering, weight
  alignment, deposit admission and clone initialization/recovery.
- `test/`: Foundry tests and chain mocks.
- `script/DeployAlpha.s.sol`: deployment; configure the registry separately first
  and pass `PARKING_HOTKEY`, an unused 32-byte account id the vault claims for
  its own coldkey at deployment.
- [scripts/](scripts/README.md): read-only chain observability.
- [e2e/](e2e/README.md): localnet scenarios and their Python harness.

## Build and test

Dependencies are git submodules:

```bash
git submodule update --init --recursive
forge build
forge test
```

## Gas snapshots

CI checks deterministic tests in `.gas-snapshot` and per-call files in
`snapshots/`. Fuzz and invariant tests run in separate steps; their sampled gas
costs vary with generated inputs and are excluded from snapshots. These tests
use mocked precompiles: compare regressions here, but use e2e transaction
receipts to size live-chain gas.

Regenerate using CI's profile and thread count:

```bash
FOUNDRY_PROFILE=ci FOUNDRY_GAS_SNAPSHOT_CHECK=false FOUNDRY_GAS_SNAPSHOT_EMIT=true \
  forge snapshot --tolerance 1 --no-match-contract Invariant --no-match-test testFuzz --threads 4
```

Coverage uses a different optimization mode and can overwrite snapshots;
regenerate them with the command above before committing.
