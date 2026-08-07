# Attester guide

The vault stakes each subnet's alpha under the validators listed in
`ValidatorRegistry`. Those lists are not set by an on-chain owner; they
are set by attestations - EIP-712 messages signed off-chain by a quorum
of registry signers. This guide is for the people producing those
signatures.

## What you are signing

One attestation sets the complete validator list for one subnet:

    struct WeightAttestation {
        uint256   netuid;
        bytes32[] hotkeys;   // substrate hotkey public keys, not SS58 strings
        uint256[] weights;   // basis points
        uint256   nonce;
        uint256   deadline;  // unix timestamp
    }

The registry enforces at submission time:

- 1 to 3 hotkeys, none zero, no duplicates, one weight per hotkey.
- Every weight non-zero; weights sum to exactly 10000.
- netuid fits in 16 bits.
- nonce equals `nonces(netuid) + 1`. Nonces count per subnet.
- The deadline has not passed.

The EIP-712 domain:

    name:              "AlphaVault ValidatorRegistry"
    version:           "1"
    chainId:           the chain the registry is deployed on
    verifyingContract: the registry address

`e2e/alpha_e2e/validators.py` builds and signs exactly this payload; use
it to check an implementation against.

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
call first rolls the vault's stake off it onto the current set. Nothing
forces an immediate move; whoever wants the stake realigned right away
can call the vault's `rebalance(netuid)`.

Dropping a hotkey does not strand user deposits parked under it: `wrap`
refuses out-of-set hotkeys up front, and stake already sitting in a
mailbox under a dropped hotkey stays reclaimable by its owner.

## Practical notes

- A signature is bound to one (netuid, nonce) pair on one registry on one
  chain. Once the update lands, the signatures are spent; there is no
  replay across subnets, nonces or chains.
- Pick deadlines long enough to collect the quorum, short enough that a
  leaked but unsubmitted signature set goes stale.
- Weights steer where the stake sits, not how much the vault holds.
  Wrong weights cost holders emissions, and a list with a bad hotkey
  does worse: deposits and the alpha exit only work against hotkeys the
  chain accepts, so both can stall until a corrected attestation lands.
  Funds still cannot be moved out of the vault, and the TAO exit keeps
  working. See [security-model.md](security-model.md) for the exact
  boundary.

## Signer set changes

The registry admin replaces the signer set with
`setSigners(newSigners, newThreshold)`: 2 to 16 signers, threshold at
least 2 and at most the signer count. The change emits `SignersUpdated`
and takes effect immediately, so signatures from a removed signer stop
counting even if collected earlier. The admin role administers itself -
an admin can add or remove admins - so whoever holds it ultimately
controls future signer sets.
