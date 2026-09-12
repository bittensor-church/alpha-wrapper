# Basic validator registry

`BasicValidatorRegistry` implements `IValidatorRegistry` with one hotkey per subnet
at 10,000 BPS (100%). The vault stakes under that target. Deploy with a nonzero
`admin` address, then have that address call `setValidator(netuid, hotkey)` for each
subnet before accepting deposits. Deposits must be under that currently configured
hotkey; the vault rejects `wrap` for other hotkeys. Pass the registry address to the vault constructor.
The existing deployment script accepts this address through `VALIDATOR_REGISTRY`.

The admin is immutable: there is no transfer, renunciation, signer management,
attestation, batch update or timelock. Updates take effect immediately. The admin
can redirect future allocation, so selecting this registry gives that address sole
control over validator selection. Losing the admin key makes further updates impossible.

Updates reject zero hotkeys, netuids above 65,535 and hotkeys without an owner record
in the staking precompile. Like `ValidatorRegistry`, this contract records the owner
at update time, without requiring subnet membership. It uses the precompile's owner
existence flag; a stored zero AccountId is not the absence of an owner record.

Unconfigured subnets return three empty arrays and nonce zero. Each successful update
increments only that subnet's nonce and emits
`ValidatorUpdated(netuid, nonce, hotkey, owner)`. The same hotkey may be submitted again
to refresh its owner and advance the nonce. The vault uses that newer nonce to release
recovered parking after an admin decision. Configured subnets cannot be cleared.
Owner changes on-chain do not silently change the recorded owner; the vault retains
its existing ownership checks and recovery behavior.

For update history, use `scripts/get_validator_updates.py --registry-type basic`
with the usual registry address, RPC and block-range arguments. The shared getters
used by `get_vault_state.py` need no special mode.

Foundry tests cover constructor validation, access control, permanent administration,
subnet bounds/isolation, ownership snapshots/refresh, precompile failure rollback,
nonces, event payloads, empty/configured interface responses, fuzzed inputs, vault
allocation/rotation/exits and release from parking. Gas snapshots cover initial
configuration, rotation, refresh and both getter paths. E2E compatibility and the
scenarios that require multiple validators are listed in [the e2e guide](../e2e/README.md).
