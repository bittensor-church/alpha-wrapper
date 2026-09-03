# alpha-wrapper

Bittensor alpha-token wrapper (ERC-1155 vault + staking precompile integration).

## Contents
- `src/AlphaVault.sol` - ERC-1155 vault that wraps staked alpha
- `src/AlphaVaultLens.sol` - read-only companion answering every quote about a position
- `src/DepositMailbox.sol` - minimal-proxy mailbox for per-user deposits
- `src/SubnetClone.sol` - minimal-proxy stake holder for a single subnet
- `src/CloneBase.sol` - shared base of both clones: vault-only access, one-shot initialization
- `src/FixedValidator.sol` - the vault's validator source, pinned at deployment: one immutable hotkey at full weight for every subnet
- `src/libraries/` - share math and chain reads shared by the vault and the lens (VaultMath, VaultReads)
- `src/VaultErrors.sol` - the failure vocabulary both contracts revert with
- `src/interfaces/` - Bittensor precompile interfaces (IStaking, IAlpha, ISubnet, IAddressMapping) + IValidatorRegistry
- `test/` - Foundry tests + mocks for the precompiles

## Documentation

- [How it works](docs/overview.md) - the mental model: mailboxes, clones,
  token ids, share price, the validator registry
- [User guide](docs/user-guide.md) - wrapping, exiting, fixing mistakes
  validator-weight attestations
- [Edge cases](docs/edge-cases.md) - dissolution, disabled transfers, the
  chain's minimums, stray TAO
- [Security model](docs/security-model.md) - roles, trust boundaries,
  safeguards

Tooling docs: [`scripts/README.md`](scripts/README.md) for the on-chain
observability scripts.

## Build

Dependencies are vendored as git submodules:

```bash
git submodule update --init --recursive
forge build
forge test
```

## Gas

`snapshots/AlphaVault.json` and `snapshots/AlphaVaultLens.json` record what each
entry point costs, and CI fails on a change, so a regression shows up in review.

**Read them as approximations.** The unit tests mock every chain call, and a mock
costs what it costs rather than what the chain charges. Measured against a live
localnet at three validators: `wrap` and `unwrap` land within about a tenth of the
recorded figures, while `unwrapForTao` runs half again dearer than shown - it leans
hardest on the swap and unstake calls the mock makes cheap. The sixty-four-validator
entries have no measured counterpart at all and are the least trustworthy, since that
is where per-validator chain reads dominate.

For a real figure, read the gas the end-to-end run prints for every call it makes.
Each run collects them into its GitHub Actions summary, one row per broadcast call.

Regenerate the snapshots with the profile and thread count CI checks them under:

```bash
FOUNDRY_PROFILE=ci FOUNDRY_GAS_SNAPSHOT_CHECK=false FOUNDRY_GAS_SNAPSHOT_EMIT=true \
  forge snapshot --tolerance 1 --no-match-contract Invariant --threads 4
```

The thread count matters: the fuzzer's dictionary is shared across concurrently
running tests, so a different one produces different inputs and a snapshot CI will
reject. Run `forge coverage` only after regenerating, never before - it builds
unoptimized and overwrites the recorded numbers.
