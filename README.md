# alpha-wrapper

Bittensor alpha-token wrapper (ERC-1155 vault + staking precompile integration).

## Contents
- `src/AlphaVault.sol` — ERC-1155 vault that wraps staked alpha
- `src/DepositMailbox.sol` — minimal-proxy mailbox for per-user deposits
- `src/SubnetClone.sol` — minimal-proxy stake holder for a single subnet
- `src/ValidatorRegistry.sol` — registry of target validator weights per subnet, attested by a threshold of signers whose membership the admin manages
- `src/interfaces/` — Bittensor precompile interfaces (IStaking, IMetagraph, IAddressMapping) + IValidatorRegistry
- `test/` — Foundry tests + mocks for the precompiles

## Subnet dissolution

Subtensor dissolves subnets asynchronously. While cleanup is in progress, the
vault temporarily freezes share-priced operations for the affected netuid so
they cannot price or distribute an incomplete TAO refund.

The blackout is scoped by netuid because Subtensor's precompile does not
identify the registration generation being dissolved. As a result, an older,
already-dissolved position can also be temporarily non-redeemable while a
successor on the same netuid is dissolving. Redemption resumes when that
cleanup completes. This conservative availability tradeoff avoids adding
per-generation finalization storage and its gas cost to every unwrap.

## Build
```bash
forge install foundry-rs/forge-std --no-commit
forge install OpenZeppelin/openzeppelin-contracts --no-commit
forge build
forge test
```
