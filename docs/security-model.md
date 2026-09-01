# Security model

## Who can do what

The vault is permissionless: it has no privileged roles, and every
function is either open to everyone or acts only on the caller's own
balance and mailbox. Its code and registry address are final at
deployment.

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
- Whoever told them which lens to read, and which build of it. Quotes come
  from a separate read-only contract that names its vault through `vault()`
  while the vault names no lens in return. The pairing check catches a
  mismatched lens and stops there: any contract can answer `vault()`
  correctly and still invent every quote, and a lens compiled from changed
  shared-library source answers for the same vault while computing
  differently. The lens itself can move no stake and mint no shares, so a
  person reading a number off the wrong one is misinformed. A contract that
  sizes a slippage bound from a quote can be walked into a bad fill, which
  is why an integrator pins a reviewed lens address and its runtime code
  instead of accepting one at call time.

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
- Market-order exits are slippage-bounded by the caller's `minTaoOut`,
  and the mint by their `minSharesOut`, so a rate that moves between the
  quote and the call costs the caller no more than they allowed.
- Backing the vault cannot account for shuts every share-pricing and
  alpha-moving path rather than being priced around, so an understated
  total can never be minted or redeemed against. Recovery is open to
  anyone and can only move alpha between the vault's own keys, so it
  needs no permission and grants none
  ([design/backing-resolution.md](design/backing-resolution.md)).

## Known tradeoffs

- The netuid-scoped dissolution blackout can temporarily freeze an old
  position while a successor subnet on the same netuid dissolves
  ([edge-cases.md](edge-cases.md)).
- Amounts below the chain's minimum stake size can leave the stake split
  drifted from target weights; share value is unaffected.
- `wrap` reads the caller's mailbox only under the chosen key. A hotkey
  swap landing between deposit and wrap carries the deposit to the new
  key, and the wrap reverts until the owner reclaims and retries
  ([user-guide.md](user-guide.md)). The deposit stays the owner's
  throughout; the manual retry is the accepted price of a wrap that
  never guesses where a deposit went. When every attested key has
  swapped away at once, deposits wait for the next attestation to name
  a live key; exits and quotes keep working through the record.
- A partial `unwrapForTao` can fill short and refund the unsold part as
  shares instead of reverting; callers bound the damage with
  `minTaoOut`.
- Every `unwrapForTao` exit sells into the subnet's pool, and that sale
  moves the pool's price against the holders who stay. The withdrawer
  is protected by `minTaoOut`; the stayers are not compensated. Users
  paying attention exit through `unwrap`, which never touches the pool -
  `unwrapForTao` is the opt-in escape hatch for when the pool touches
  them (disabled alpha transfers, sub-floor positions). Accepted design
  asymmetry: the alternative is a rail that prices an exit above what
  the pool can pay.
- A quorum-signed attestation stays submittable until one lands for its
  subnet, so a list the signers have moved away from can still be
  installed by anyone holding its signatures. Landing a replacement is
  what retires it.
- Backing that goes missing shuts the token - exits included - for up to
  the recovery window fixed at deployment (`recoveryWindow`), and holders
  wait that out. The design buys a watcher time to preserve the backing
  and then chooses liveness over waiting longer.
- Backing nobody recovers inside that window is written off across the
  holders of the moment, and alpha found afterwards accrues to whoever
  holds shares then. Whoever knows where that alpha sits can deposit at
  the written-down price first and recover it second, taking most of it
  from the holders who bore the loss. Accepted policy rather than an
  accident; the vault has no recapitalization mechanism.
- The vault relies on someone watching it. Nothing is lost if no one
  does - the window still runs and the token still reopens - but the
  missing alpha is then socialized rather than recovered.
