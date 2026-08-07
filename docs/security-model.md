# Security model

## Who can do what

The vault runs ownerless: its code and registry address are final at
deployment, and every function is either open to everyone or acts only
on the caller's own balance and mailbox.

The only privileged parties live in `ValidatorRegistry`:

- The signers, threshold-of-N, choose validator sets and weights per
  subnet by co-signing attestations
  ([attester-guide.md](attester-guide.md)).
- The registry admin rotates the signer set and threshold; the role
  administers itself, so an admin can also add or remove admins. Those
  two levers are its full reach.

## The boundary of registry control

Registry control steers where stake is delegated, and that is its full
extent. The signers - or an admin who replaces them all with its own
keys - can point the vault's stake at validators of their choosing, and
bad choices cost holders emissions. Stake transfers out of the vault,
share mints and burns, mailbox withdrawals and every vault parameter
stay beyond their reach.

A hostile validator set can break wrapping and the alpha exit, since
deposits must name a listed hotkey and stake moves only onto validators
the chain accepts. Holders can still leave with TAO: the TAO exit sells
from wherever the stake actually sits, if need be over several sales.

## What holders trust

- The Bittensor chain. The staking, alpha, subnet and address-mapping
  precompiles, plus the `ValidatorRegistry` it reads validator sets
  from, are the vault's only external dependencies, and all accounting
  reads stake balances straight from the chain.
- The performance of the attested validators: emissions accrue, or do
  not, according to where the registry points the stake.
- The registry quorum and its admin key, within the boundary above.

## Design safeguards

- Per-subnet isolation. Each position's alpha sits under its own clone
  coldkey, so a subnet's dissolution or misbehavior stays contained to
  its own position.
- Clones obey only the vault. Every mailbox and subnet-clone function
  reverts for other callers, and initialization is one-shot, vault-only.
  The one thing outsiders can do is send a clone TAO, which the claim
  index absorbs ([edge-cases.md](edge-cases.md)).
- `wrap` credits only the caller's own mailbox, so each deposit stays
  claimable by its owner alone.
- Every entry point that moves stake or native TAO is `nonReentrant`,
  and payouts come after burns.
- First-depositor share-price inflation is blunted with virtual shares
  and assets (the ERC-4626 pattern), and a share-supply cap keeps the
  TAO claim index exact.
- Market-order exits are slippage-bounded by the caller's `minTaoOut`.

## Known tradeoffs

- The netuid-scoped dissolution blackout can temporarily freeze an old
  position while a successor subnet on the same netuid dissolves
  ([edge-cases.md](edge-cases.md)).
- Amounts below the chain's minimum stake size can leave the stake split
  drifted from target weights; share value is unaffected.
- A partial `unwrapForTao` can fill short and refund the unsold part as
  shares; callers bound the damage with `minTaoOut`.
