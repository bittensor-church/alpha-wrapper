# alpha-wrapper

Bittensor alpha-token wrapper (ERC-1155 vault + staking precompile integration).

## Contents
- `src/AlphaVault.sol` - ERC-1155 vault that wraps staked alpha
- `src/AlphaVaultLens.sol` - read-only companion answering every quote about a position
- `src/DepositMailbox.sol` - minimal-proxy mailbox for per-user deposits
- `src/SubnetClone.sol` - minimal-proxy stake holder for a single subnet
- `src/CloneBase.sol` - shared base of both clones: vault-only access, one-shot initialization
- `src/ValidatorRegistry.sol` - registry of target validator weights per subnet, attested by a threshold of signers whose membership the admin manages
- `src/libraries/` - share math and chain reads shared by the vault and the lens (VaultMath, VaultReads)
- `src/VaultErrors.sol` - the failure vocabulary both contracts revert with
- `src/interfaces/` - Bittensor precompile interfaces (IStaking, IAlpha, ISubnet, IAddressMapping) + IValidatorRegistry
- `test/` - Foundry tests + mocks for the precompiles

## Documentation

- [How it works](docs/overview.md) - the mental model: mailboxes, clones,
  token ids, share price, the validator registry
- [User guide](docs/user-guide.md) - wrapping, exiting, fixing mistakes
- [Attester guide](docs/attester-guide.md) - producing and submitting
  validator-weight attestations
- [Edge cases](docs/edge-cases.md) - dissolution, disabled transfers, the
  chain's minimums, stray TAO
- [Security model](docs/security-model.md) - roles, trust boundaries,
  safeguards

Tooling docs: [`scripts/README.md`](scripts/README.md) for the on-chain
observability scripts, [`e2e/README.md`](e2e/README.md) for the end-to-end
suite.

## Build

Dependencies are vendored as git submodules:

```bash
git submodule update --init --recursive
forge build
forge test
```
