# How it works

The wrapper keeps Bittensor alpha staked and issues transferable ERC-1155 shares.
A live position can normally redeem for staked alpha or sell it for native TAO.
Recovery, chain minimums and subnet state can temporarily prevent exits.

## Contracts and addresses

- `AlphaVault`: deposits, shares, exits and permissionless maintenance. No vault
  admin; code, registry address and recovery window are fixed at deployment.
- `AlphaVaultLens`: read-only backing and payout quotes. Use a trusted build paired
  with the vault; a quote does not guarantee transaction success.
- `SubnetClone`: one vault-controlled coldkey per subnet registration, isolating
  that position's stake and TAO from other positions.
- `DepositMailbox`: a deterministic address per user and netuid. The vault only
  credits the caller's own mailbox.
- `ValidatorRegistry`: 1–64 target hotkeys and basis-point weights per subnet,
  chosen by a quorum of off-chain signers. Its admin manages signer membership.

A token id is `(registrationBlock << 16) | netuid`. Reusing a dissolved netuid
creates a different token; old shares retain their old clone and refund.
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
It follows one successor hop from that recorded location and retains a usable
receiving key after a slot empties.

Unresolved swaps need a watcher. Missing owner records require association;
missing backing requires recovery or an explicit, delayed write-off. Neither the
timer nor a write-off restores ownership. The example, watcher steps and exit
restrictions are in [Hotkey swaps and recovery](hotkey-swaps.md).

Start with the [user guide](user-guide.md) for transactions,
[attester guide](attester-guide.md) for registry updates, and
[security model](security-model.md) for trust and loss assumptions.
