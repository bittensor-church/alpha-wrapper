# Security model

## Who can do what

The vault is permissionless: it has no privileged roles, and every
function is either open to everyone or acts only on the caller's own
balance and mailbox. Its code and registry address are final at
deployment.

Recovering alpha the vault has lost sight of is permissionless too: anyone
may point a position at a key holding its stake, because only the vault's
own account can put stake there, so recognising it can only add backing.

The only privileged parties live in `ValidatorRegistry`:

- The signers, threshold-of-N, choose validator sets and weights per
  subnet by co-signing attestations
  ([attester-guide.md](attester-guide.md)).
- The registry admin rotates the signer set and threshold. The role
  administers itself, so an admin can also add or remove admins; it has
  no other power.

## What the privileged parties cannot do

Registry control steers where stake is delegated, nothing else. The
signers - or an admin who replaces them all with its own keys - can point
the vault's stake at validators of their choosing, and bad choices cost
holders emissions. They cannot transfer stake out of the vault, mint or
burn shares, touch mailboxes, or change any vault code or parameter.

A hostile validator set can break wrapping and the alpha exit, since
deposits must name a listed hotkey and stake cannot be moved onto
validators that do not exist. It cannot lock funds in: the TAO
exit never moves stake between validators, it sells from wherever the
stake actually sits, so holders can still leave with TAO, if need be
over several sales.

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
  coldkey; one subnet's dissolution or misbehavior cannot touch another
  position's backing.
- Clones obey only the vault. Every mailbox and subnet-clone function
  reverts for other callers, and initialization is one-shot, vault-only.
  The one thing outsiders can do is send a clone TAO, which the claim
  index absorbs ([edge-cases.md](edge-cases.md)).
- `wrap` credits only the caller's own mailbox, so nobody can claim
  someone else's deposit.
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
- If the chain takes a position's stake and leaves no record of where it
  went, new deposits stay closed until someone finds the alpha or a quorum
  signs the loss off. Holders are not shut in: exits pay out of whatever
  the vault can locate, mailbox deposits stay reclaimable, and credited
  TAO stays claimable throughout. Leaving while a position is short does
  forfeit a share of anything recovered later, which is the cost of taking
  an honest price early.
- A write-down that is wrong, and that nobody challenges inside its
  24-hour window, dilutes the existing holders once the alpha resurfaces.
  Anyone can prevent that by pointing the vault at the key holding it,
  which requires somebody to be watching.
- Amounts below the chain's minimum stake size can leave the stake split
  drifted from target weights; share value is unaffected.
- A partial `unwrapForTao` can fill short and refund the unsold part as
  shares instead of reverting; callers bound the damage with
  `minTaoOut`.
