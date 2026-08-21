# Attester guide

The vault stakes each subnet's alpha under the validators listed in
`ValidatorRegistry`. Those lists are set by attestations - EIP-712
messages signed off-chain by a quorum of registry signers. This guide is
for the people producing those signatures.

## What you are signing

One attestation sets the complete validator list for one subnet:

    struct WeightAttestation {
        uint256   netuid;    // the subnet the attestation applies to
        bytes32[] hotkeys;   // validators the vault stakes this subnet's alpha under
        uint256[] weights;   // each validator's share of the stake, in basis points
        uint256   nonce;     // orders this subnet's updates
    }

The registry enforces at submission time:

- 1 to 64 distinct, non-zero hotkeys, one weight per hotkey.
- Every weight non-zero; weights sum to exactly 10000.
- netuid fits in 16 bits.
- nonce equals `nonces(netuid) + 1`. Nonces count per subnet.

## How long a signature lasts

A signature stays usable until an attestation lands for that subnet.
Once one does, `nonces(netuid)` advances and every signature still
outstanding for the old nonce stops working - sign again at the new
nonce to replace it.

Signatures carry no clock of their own, so one signed today and
submitted a month later still applies, as long as nothing landed for
that subnet in between. What ages is the list inside it: it stays the
list you picked when you signed.

Signing again at the same nonce adds a competitor rather than a
replacement. Whichever payload reaches the chain first commits, and the
others revert against the nonce it advanced - so landing yours is what
settles which list takes effect. Once one has landed, the next nonce
opens and a signature there supersedes it.

A signature you have handed out is also beyond recall: anyone holding it
can submit it. Treat each one as final, and retire a list you have moved
away from by landing its replacement.

## Agreeing with the other signers

The threshold counts signatures over one identical payload, so every
signer must produce the same bytes. Every field supports that: netuid
and nonce come from the registry, and hotkeys and weights come from
applying your shared selection policy at an agreed evaluation point -
a block height each of you can name independently, such as an epoch
boundary. Signers who evaluate the same height under the same policy
arrive at identical payloads without coordinating.

The EIP-712 domain:

    name:              "AlphaVault ValidatorRegistry"
    version:           "1"
    chainId:           the chain the registry is deployed on
    verifyingContract: the registry address

## Submitting

Anyone can submit - the signatures are the authorization, the sender only
pays gas. Call `updateValidators(attestation, signatures)` with at least
`threshold()` signatures over the same digest, ordered ascending by
signer address; the contract rejects any other order, and duplicate
signers with it. Extra signatures beyond the threshold are fine as long
as each comes from a current signer. `updateValidatorsBatch` takes
several attestations in one transaction, each with its own signature
list.

A successful update emits `ValidatorsUpdated(netuid, nonce, hotkeys,
weights)`.

## What happens after an update

The vault picks up the new set on its next deposit, alpha exit or
`rebalance` for that subnet; the TAO exit ignores the weights and sells
from wherever the stake sits. If a validator was dropped, the next such
call first rolls the vault's stake off it onto the current set; whoever
wants the stake realigned right away can call the vault's
`rebalance(netuid)`.

Deposits parked under a dropped hotkey stay recoverable: `wrap` refuses
out-of-set hotkeys up front, and stake already sitting in a mailbox
under one stays reclaimable by its owner.

## Signer set changes

The registry admin replaces the signer set with
`setSigners(newSigners, newThreshold)`: 2 to 16 signers, threshold at
least 2 and at most the signer count. The change emits `SignersUpdated`
and takes effect immediately, so signatures from a removed signer stop
counting even if collected earlier. The admin role administers itself -
an admin can add or remove admins - so whoever holds it ultimately
controls future signer sets.
