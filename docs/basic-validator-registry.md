# Basic validator registry

`BasicValidatorRegistry` implements `IValidatorRegistry` with one hotkey per subnet
at 10,000 BPS (100%). The vault stakes under that target. Deploy with a nonzero
`initialOwner` address, then have that address call `setValidator(netuid, hotkey)` for each
subnet before accepting deposits. Deposits must be under that currently configured
hotkey; the vault rejects `wrap` for other hotkeys. Pass the registry address to the vault constructor.
The existing deployment script accepts this address through `VALIDATOR_REGISTRY`.

The admin is the OpenZeppelin `Ownable2Step` owner, exposed through `owner()`.
There are no signers, attestations, batch updates or timelocks. Validator updates
take effect immediately. The owner has sole control over validator selection.

To rotate the admin, the current owner calls `transferOwnership(newOwner)`, then
that address calls `acceptOwnership()`. Until acceptance, the current owner retains
all update authority and `pendingOwner()` has none. The owner can replace a pending
nomination or cancel it with `transferOwnership(address(0))`; cancellation leaves
the current owner in place. Acceptance clears the pending nomination. Ownership
changes preserve all validator sets and nonces; the new owner must still publish a
validator update to release recovered parking. `renounceOwnership()` is disabled.

Two-step transfers permit planned key rotation, not recovery of an already lost
owner key. If the owner key is lost without an accessible pending successor, no
further updates can land. Existing and future recovered parking then cannot be
released: deposits and rebalance stay blocked, although parked exits remain available.
An already nominated successor can still accept without another call from the old owner.

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

E2E compatibility is documented in [the e2e guide](../e2e/README.md).
