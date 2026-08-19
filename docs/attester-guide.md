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
there, and nothing on chain says where it went. It stops pricing and
moving that position until someone accounts for the difference, because
guessing wrong hands value from one set of holders to another. You settle
it one of two ways.

If the alpha is findable, name the key holding it in an ordinary
attestation. The next `rebalance` adopts it and the position reopens with
nothing further from you.

If it is genuinely gone - the chain sold a slice that fell below its dust
line, say - co-sign a write-down:

    struct BackingWriteDown {
        address vault;           // the vault this approval is for
        uint256 tokenId;         // the position it applies to
        bytes32 slotsHash;       // the exact record you examined
        uint256 minimumBacking;  // least backing you expect to survive
        uint256 nonce;           // orders write-downs for this position
        uint256 deadline;        // submission cutoff, unix seconds
    }

Signed over the same domain as an attestation, and submitted by anyone to
the vault's `writeDownBacking`. You acknowledge that a loss happened; you
do not decide its size. The position re-anchors to exactly what the chain
reports it still holds, and `minimumBacking` only lets you refuse if less
than that survived. `slotsHash` ties the approval to the record you
looked at, so it stops being valid the moment anything moves. The vault
refuses a write-down against a position that can account for itself.

Until one of the two lands, that position takes no deposits and allows no
exits, so a position waiting on an unreachable quorum stays shut. TAO
already credited to holders stays claimable regardless.

## Signer set changes

The registry admin replaces the signer set with
`setSigners(newSigners, newThreshold)`: 2 to 16 signers, threshold at
least 2 and at most the signer count. The change emits `SignersUpdated`
and takes effect immediately, so signatures from a removed signer stop
counting even if collected earlier. The admin role administers itself -
an admin can add or remove admins - so whoever holds it ultimately
controls future signer sets.
