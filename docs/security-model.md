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
  ([edge-cases.md](edge-cases.md#a-validator-swaps-its-hotkey)).

## Recovery-window tradeoff and late-recovery attack

Backing that goes missing freezes the token - exits included - for the
recovery window fixed at deployment. Anyone can start the clock with
`syncBacking` and recover located alpha with `recoverStray`. If nobody
recovers it before the deadline, another `syncBacking` writes the missing
amount off and reopens the token against only the backing the vault can
locate. This deliberately chooses bounded unavailability over waiting for
alpha that may be gone or too small to recover economically forever.

A dishonest validator can manufacture a profitable late recovery:

1. Its attested hotkey carries some of the vault's alpha. The validator
   swaps to a successor, carrying the alpha with it, and then registers the
   old hotkey again. Subtensor removes the successor edge, leaving the vault
   unable to discover the funded key on chain.
2. If watchers cannot independently find and recover that key before the
   deadline, anyone - including the validator - can finalize the write-off.
3. The validator or a collaborator deposits after the token reopens and
   mints shares against the written-down backing. After a complete write-off,
   a comparatively small valid deposit can make it the dominant holder.
4. The validator reveals the funded key and calls `recoverStray`, or lets a
   later attestation and settling call bring it back into the accounting.
   The alpha then belongs pro rata to the current share supply, allowing the
   new shares to capture most of it.

For a hidden balance that has not grown, this ordering cannot drain backing
that remained located or charge incumbents for the same principal twice. If
`H` is the amount finalized as missing, the incumbent cohort's aggregate
reduction between its pre-loss claim and its post-recovery claim is at most
`H`; it approaches `H` as the new depositor approaches the entire share
supply. The attack changes who receives the late `H` rather than extracting
another `H` from the vault.

The `BackingWrittenOff` event is not necessarily a cap on the eventual
windfall. A hidden position may earn emissions, or its key may hold a surplus,
after the vault last anchored its expectation. Recovery accounts for the
whole balance actually returned, and that additional growth also belongs to
the cohort holding shares at recovery time.

This is accepted policy, not a guarantee that written-off alpha was destroyed.
It requires active monitoring: watchers should start the window promptly,
identify erased or multi-hop successors off chain, and recover them before the
deadline whenever possible. After finalization, neither recovery nor a new
validator attestation can reconstruct the prior cohort's entitlement.

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
