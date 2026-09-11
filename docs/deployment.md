# Deployment and runtime compatibility

## Order of operations

1. Deploy `ValidatorRegistry` with its admin, initial signers and threshold.
2. Have the signers publish a first validator set for every subnet in scope.
3. Deploy the vault set with `script/DeployAlpha.s.sol`, pointed at that registry.
4. Run the verification checks below, then record the addresses and code hashes.

## Registry

`ValidatorRegistry(admin, initialSigners, threshold)`:

- `admin` holds `DEFAULT_ADMIN_ROLE` and rotates the signer list and threshold
  later with `setSigners`.
- `initialSigners` are EVM addresses: at least 2, at most 16, distinct and
  nonzero.
- `threshold` is at least 2 and at most the number of signers.

```sh
forge create src/ValidatorRegistry.sol:ValidatorRegistry \
  --rpc-url <url> --private-key <key> --broadcast \
  --constructor-args <admin> "[<signer1>,<signer2>]" 2
```

A quorum then signs one attestation per subnet and anyone submits it with
`updateValidators`, with the signatures sorted by signer address ascending. The
[attester guide](attester-guide.md) covers the payload, domain and nonce rules.

## Vault set

The deployment script reads four environment variables:

| Variable | Meaning | Default |
| --- | --- | --- |
| `VALIDATOR_REGISTRY` | Address of the deployed registry. | required |
| `VAULT_URI` | ERC-1155 metadata URI, with `{id}` substitution. | `https://api.tao20.io/metadata/{id}.json` |
| `RECOVERY_WINDOW` | Length of the recovery window, in seconds. | 21600 (6 hours) |
| `PARKING_HOTKEY` | An unused 32-byte account id the vault claims for its own coldkey. | required |

Choose a fresh random `PARKING_HOTKEY`. The constructor claims it with
`tryAssociateHotkey` and confirms the result; deployment reverts
`ParkingHotkeyUnavailable` when another coldkey already owns that account.

```sh
forge script script/DeployAlpha.s.sol --rpc-url <url> --private-key <key> --broadcast
```

The script broadcasts from whichever signer the command line supplies; a
keystore account (`--account <name>`) or hardware wallet works in place of the
raw key.

The broadcast deploys the `DepositMailbox` logic, the `SubnetClone` logic, the
`AlphaVault` whose constructor deploys its own `CloneFactory`, and
`AlphaVaultLens(vault)`. Forge also deploys the `VaultAllocation` library and
links its address into the vault bytecode, so each vault is bound to one library
deployment. Deploying by hand needs the same link, passed as
`--libraries src/libraries/VaultAllocation.sol:VaultAllocation:<address>`.
`VaultAllocation` is the only linked library; the other libraries under
`src/libraries/` compile into the contracts that use them and need no address.

Every vault parameter is immutable: `validatorRegistry`, `recoveryWindow`,
`parkingHotkey` and `cloneFactory` are fixed at deployment and the vault has no
admin or upgrade path. Changing any of them means deploying a new vault, and a
rebuilt library means a new vault as well.

## Verification after deployment

- `lens.vault()` returns the vault address.
- `vault.validatorRegistry()`, `vault.recoveryWindow()` and
  `vault.parkingHotkey()` return the intended values.
- `getHotkeyOwner(parkingHotkey)` on the staking precompile `0x0805` returns the
  vault's own coldkey, which is `addressMapping(vault)` on the address-mapping
  precompile `0x080C`.
- The library address embedded in the deployed vault bytecode equals the
  deployed `VaultAllocation` address.
- Every address, its runtime code hash and the commit it was built from go into
  the table at the end of this page.

## Runtime compatibility

The vault reads and writes chain state through precompiles. A runtime must
provide each function below and honor the rule next to it.

| Precompile | Function | Rule relied on | Known minimum spec |
| --- | --- | --- | --- |
| Staking `0x0805` | `getStake` | Returns the alpha held by a (hotkey, coldkey, netuid) triple as a u64. | not recorded |
| Staking `0x0805` | `getHotkeyOwner` | Reports no owner record once an all-subnet hotkey swap removes it, and stake operations require that record. | not recorded |
| Staking `0x0805` | `getHotkeySuccessor` | Names the key a swap carried a hotkey's stake to. | 445 (storage recorded since 437) |
| Staking `0x0805` | `getColdkeyLock` | Reports the conviction-locked alpha an account holds on a subnet. | not recorded |
| Staking `0x0805` | `getRejectLockedAlpha` | Accounts reject incoming locked alpha by default, and this flag reports that setting. | not recorded |
| Staking `0x0805` | `getColdkeyRoot` | Reports whether an account carries coldkey-swap history. | not recorded |
| Staking `0x0805` | `getOwnedHotkeys` | Lists the hotkeys an account owns; an uncontaminated clone candidate owns none. | not recorded |
| Staking `0x0805` | `getDefaultMinStake` | The minimum a partial unstake enforces; the vault applies it to every move as its conservative floor. | 438 |
| Staking `0x0805` | `getNominatorMinRequiredStake` | The minimum a nominator may hold; the chain can sweep smaller positions into TAO. | not recorded |
| Staking `0x0805` | `moveStake` | A same-subnet move enforces the chain's transfer minimum, which is the lower of the two minimums. | not recorded |
| Staking `0x0805` | `transferStake` | Delivers alpha to another coldkey on the same subnet; the chain's transfer minimum applies. | not recorded |
| Staking `0x0805` | `removeStake` | A partial unstake enforces the default minimum stake; a full drain of a position clears it. | not recorded |
| Subnet `0x0803` | `getNetworkRegistrationBlock` | Zero while a netuid is unregistered. | not recorded |
| Subnet `0x0803` | `getRegisteredSubnetCounter` | Steps on every registration and survives dissolution, so it tells subnet generations apart. | not recorded |
| Subnet `0x0803` | `isSubnetDissolving` | Reports a subnet whose dissolution is under way. | 431 |
| Subnet `0x0803` | `getSubnetCapacityConfig` | Its tenth field is the owner's alpha-transfer switch. | not recorded |
| Neuron `0x0804` | `tryAssociateHotkey` | Assigns the caller's coldkey as owner only when the hotkey has none, and succeeds silently otherwise. | not recorded |
| Alpha `0x0808` | `getAlphaPrice` | Prices alpha in TAO, scaled by 1e18. | not recorded |
| Alpha `0x0808` | `simSwapAlphaForTao` | Quotes the TAO a sale of a given alpha amount returns. | not recorded |
| Address mapping `0x080C` | `addressMapping` | Returns the substrate coldkey an EVM address controls. | not recorded |

Two further rules sit outside any single function: the chain refuses a coldkey
swap into an account that is itself a hotkey, which is what keeps mailboxes and
subnet clones clean, and a rejected precompile call consumes all forwarded gas,
which is why the vault checks conditions before calling.

The behavior above is tested against Subtensor source commit
`14cde6410fe8ec81a940e290c56f94a632a0988d`, and CI exercises the localnet image
`ghcr.io/raofoundation/subtensor-localnet:devnet@sha256:f68b9a1744401fca244a25ec579f461926944c6addac252a89af88a9e9271510`.
A runtime that breaks any rule above is unsuitable for deployment.

## Deployed artifacts

Nothing is deployed on a public network yet. Each deployment adds a row.

| Network | Contract | Address | Code hash | Deployed at commit |
| --- | --- | --- | --- | --- |
| | | | | |
