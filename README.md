# alpha-wrapper

Bittensor alpha-token wrapper (ERC-1155 vault + staking precompile integration).

## Contents
- `src/AlphaVault.sol` — ERC-1155 vault that wraps staked alpha
- `src/DepositForwarderLogic.sol` — minimal-proxy forwarder for per-subnet deposits
- `src/interfaces/` — Bittensor precompile interfaces (IStaking, IAlpha, IMetagraph) + IValidatorRegistry
- `test/` — Foundry tests + mocks for the precompiles
- `frontend/` — wrap/unwrap dApp (Vite + React)

## Build
```bash
forge install foundry-rs/forge-std --no-commit
forge install OpenZeppelin/openzeppelin-contracts --no-commit
forge build
forge test
```

## Frontend
```bash
cd frontend && npm install && npm run dev
```
