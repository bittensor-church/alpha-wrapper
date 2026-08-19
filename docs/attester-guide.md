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
        uint256   deadline;  // submission cutoff, unix seconds
    }

The registry enforces at submission time:

- 1 to 64 distinct, non-zero hotkeys, one weight per hotkey.
- Every weight non-zero; weights sum to exactly 10000.
- netuid fits in 16 bits.
- nonce equals `nonces(netuid) + 1`. Nonces count per subnet.
- The deadline is still in the future.

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

## Acknowledging a loss

Sometimes the vault finds less alpha under a validator than it left
there, and nothing on chain says where it went. It stops taking new
deposits into that position until someone establishes what happened,
because pricing it wrong hands value from one set of holders to another.

Most of the time this is not yours to solve. If the alpha is findable,
anyone at all can call the vault's `recoverStray` and point the position
at the key holding it - no signature, no delay, and nothing further from
you. Finding it is a scan of the subnet's hotkeys against the vault's own
coldkey.

You are needed only when that scan comes back empty, because the chain
sold a slice that fell below its dust line and no key holds it any more.
Then co-sign a write-down:

    struct BackingWriteDown {
        address vault;           // the vault this approval is for
        uint256 tokenId;         // the position it applies to
        bytes32 shortfallHash;   // the exact loss you examined
        uint256 minimumBacking;  // least backing you expect to survive
        uint256 nonce;           // orders write-downs for this position
        uint256 deadline;        // submission cutoff, unix seconds
    }

Signed over the same domain as an attestation, and submitted by anyone to
the vault's `writeDownBacking`. You acknowledge that a loss happened; you
do not decide its size, and you do not erase it. The position keeps its
record of what it is owed, so if you turn out to be wrong, anyone can
still recover it afterwards. `minimumBacking` lets you refuse if less
survived than you expected, and `shortfallHash` ties the approval to the
loss you looked at: which slots could not be accounted for and what each
was owed. A different or additional loss is not covered by it, whether it
appears before you spend the approval or after, and needs its own.
The vault refuses a write-down against a position that can account for
itself.

Deposits then wait 24 hours before resuming, so anyone who can still find
the alpha has time to say so. Do the scan before you sign; that window is
the safety net, not the check.

Throughout all of this holders can still leave. Exits pay out of whatever
the vault can locate, mailbox deposits stay reclaimable, and credited TAO
stays claimable. Only new deposits wait on you.

## Signer set changes

The registry admin replaces the signer set with
`setSigners(newSigners, newThreshold)`: 2 to 16 signers, threshold at
least 2 and at most the signer count. The change emits `SignersUpdated`
and takes effect immediately, so signatures from a removed signer stop
counting even if collected earlier. The admin role administers itself -
an admin can add or remove admins - so whoever holds it ultimately
controls future signer sets.
