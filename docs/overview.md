# How it works

The wrapper keeps Bittensor alpha staked and issues transferable ERC-1155 shares.
A live position can normally redeem for staked alpha or sell it for native TAO.
Recovery, chain minimums and subnet state can temporarily prevent exits.

## Contracts and addresses

- `AlphaVault`: deposits, shares, exits and permissionless maintenance. No vault
  admin; code, registry address, recovery window and parking hotkey are fixed
  at deployment. Its receiving-key rules, stake consolidation, payout gathering and
  weight alignment live in `VaultAllocation`, a library deployed once and linked into
  the vault's bytecode. Share accounting and backing gates remain in the vault.
- `AlphaVaultLens`: read-only backing and payout quotes. Use a trusted build paired
  with the vault; a quote does not guarantee transaction success.
- `SubnetClone`: one vault-controlled coldkey per subnet registration, isolating
  that position's stake and TAO from other positions.
- `DepositMailbox`: a deterministic address per user and netuid. The vault only
  credits the caller's own mailbox.
- `ValidatorRegistry`: 1–64 target hotkeys and basis-point weights per subnet,
  chosen by a quorum of off-chain signers. Its admin manages signer membership.

A token id is `(registrations << 16) | netuid`, where `registrations` is the
number of times the chain has registered that netuid. Reusing a dissolved netuid
steps it and creates a different token; old shares retain their old clone and
refund. A chain migration that rewrites a subnet's registration block leaves its
token unchanged.
`currentTokenId(netuid)` identifies the live generation. The first wrap deploys
its clone, or anyone can deploy it earlier with `createSubnetProxy(netuid)`.

## Share value and allocation

Alpha backing divided by supply determines share value, with virtual offsets to
limit first-depositor inflation. Emissions increase backing without minting shares.
The lens's `sharePrice` is alpha per share scaled by 1e18; `previewUnwrap` prices a
specific burn. Native TAO on the clone is accounted separately, not included in
the live alpha share price.

Wraps, alpha exits and `rebalance(netuid)` first consolidate dropped validators
and align stake toward current weights. An alpha exit pays before aligning the
remainder. Small alignment moves are skipped; current share value depends on total
backing, while allocation affects future emissions. TAO exits sell where stake
sits and do not rebalance.

## Swaps and recovery

The vault records where stake actually sits, separately from registry names.
It follows one successor hop from that recorded location and keeps allocation
under the coldkey that owned each attested name.

Unresolved swaps need a watcher. Missing backing is parked on a hotkey the
vault's own coldkey controls, by recovery or by a delayed write-off, and stays
parked until the attesters publish a new set. A name claimed by a stranger is
retired by attestation. The example, watcher steps and exit restrictions are in
[Hotkey swaps and recovery](hotkey-swaps.md).

Start with the [user guide](user-guide.md) for transactions,
[attester guide](attester-guide.md) for registry updates, and
[security model](security-model.md) for trust and loss assumptions.
