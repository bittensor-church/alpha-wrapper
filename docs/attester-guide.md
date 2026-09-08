# Attester guide

A quorum of registry signers chooses each subnet's validator set using EIP-712
attestations. Anyone can submit the signatures; the sender only pays gas.

## Payload and validation

```solidity
struct WeightAttestation {
    uint256 netuid;
    bytes32[] hotkeys;
    uint256[] weights;
    uint256 nonce;
}
```

Submission requires:

- A 16-bit netuid and `nonce == nonces(netuid) + 1`.
- 1–64 distinct, nonzero hotkeys with owner records at submission time.
- One positive BPS weight per hotkey, summing to 10000.

An ownerless entry reverts `OwnerlessHotkey`. The registry records each entry's
owner coldkey; the vault allocates to a name, its recorded key or its successor
only while that coldkey holds it. A name that later answers to another coldkey
receives nothing until it is replaced. This check does not replace watcher
monitoring.

All signers must sign identical bytes. Agree on a selection policy and evaluation
block, then derive the same ordered hotkeys, weights and nonce.

EIP-712 domain:

```text
name:              "AlphaVault ValidatorRegistry"
version:           "1"
chainId:           deployment chain id
verifyingContract: registry address
```

## Submission and signature lifetime

Call `updateValidators(attestation, signatures)` with at least `threshold()`
current signers, ordered by recovered address ascending. Duplicates, unordered
signatures and non-current signers are rejected, including extra signatures beyond
the threshold. `updateValidatorsBatch` applies several updates atomically.
Success emits `ValidatorsUpdated(netuid, nonce, hotkeys, weights)`.

Signatures have no expiry or recall. Signing a replacement at the same nonce
creates a competing payload; whichever lands first wins and invalidates the others.
To retire an old signed list, submit its replacement. Nonces advance per subnet.

The admin uses `setSigners(newSigners, newThreshold)`: 2–16 distinct nonzero
signers, with threshold 2 through signer count. Changes take effect immediately,
invalidating signatures from removed signers. Admins can add or remove admins.

## Allocation and hotkey swaps

A new set takes effect in the vault on the next wrap, alpha exit or
`rebalance(netuid)`. Dropped stake is consolidated before payout/alignment.
The TAO exit ignores registry weights. Mailbox deposits under dropped keys stay
with their depositors and must be reclaimed or wrapped after an appropriate update.

After a swap, replace the old name with the intended successor in one update.
Listing both can produce `SwappedHotkeyStillAttested` when two entries would
share one backing key. Ordinary one-hop swaps are handled automatically, including
empty-slot receiving-key selection; unresolved cases rely on a watcher.
See [Hotkey swaps and recovery](hotkey-swaps.md) for the exact restrictions.

## Releasing a parked position

A recovery or write-off parks the whole position on the vault's parking hotkey
and reports `awaitingAttestation`. Deposits and weight alignment stay shut, and
nothing earns emissions, until an attestation newer than the one in force at
parking lands for that netuid. Publish a set without the lost or captured name,
naming the intended successor; re-publishing the same set under a new nonce
also releases the position. The next wrap or `rebalance(netuid)` moves the
parked alpha onto the set.

Do not use a new attestation as a substitute for parking missing backing.
Coordinate `recoverStray` before write-off where possible. Adding a funded
successor after write-off lets later settlement credit it to current holders,
not reconstruct the original holders' claims. See the
[late-recovery risk](security-model.md#recovery-window-tradeoff-and-late-recovery-attack).
