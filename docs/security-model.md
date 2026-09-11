# Security model

## Authority and trust

The vault has no admin or upgrade path. Only it can drive its mailbox and subnet
clones. Registry signers choose validator weights; the registry admin manages
signers and admins. Neither role can directly withdraw backing, mint/burn users'
shares, access their mailboxes or change vault code.

Registry choices affect emissions and transaction availability. The TAO exit
ignores registry weights, but cannot bypass source ownership, missing backing,
dissolution, chain minimums or pool constraints. A hostile set is not harmless
merely because that exit exists.

Holders rely on:

- Subtensor and its precompiles for stake ownership, moves, accounting and refunds.
- Registry governance and validator performance.
- A funded, responsive watcher to repair unresolved swaps and park backing, and
  attesters who publish a new set to release a parked position. These
  permissionless tasks have no on-chain completion guarantee.
- Trusted vault/lens builds and addresses. The lens's `vault()` checks pairing,
  not authenticity; mid-operation callback quotes may observe unfinished state.

## Safeguards

- Separate clones isolate each subnet registration's backing.
- Mailbox collection only credits its depositor; outsiders cannot collect it.
- Stake-moving and native-payout entry points are non-reentrant. Share changes
  checkpoint claimable TAO before recipient acceptance callbacks.
- Virtual shares/assets limit first-depositor inflation; a supply cap protects
  claim-index precision.
- Caller-selected minimum outputs make insufficient fills revert atomically.
- Unresolved backing blocks live pricing and exits until the position parks or
  the loss is written off; recovery moves only the vault's own stake, onto a
  hotkey only the vault's coldkey controls.
- A receiving key is usable only under the coldkey that owned the attested name;
  a name claimed by anyone else receives nothing.
- Alpha exits avoid pool trades. TAO exits are opt-in market sales with fees and
  price impact, including price impact borne by remaining holders.

## Recovery-window tradeoff and late-recovery attack

The [hotkey-swap runbook](hotkey-swaps.md) separates two failures: names that
answer to the wrong coldkey and unlocated alpha. Attestation repairs the first.
`syncBacking` handles the second: it moves all located backing onto the vault's
parking hotkey before starting one fixed recovery window, with a dust exception:
if even the richest source or parking balance is below the conservative movement
floor, collection leaves those balances in place without delaying the window.
Every sync retries collection before write-off, so a larger return or price rise
can bring the dust home. Other collection failures revert without changing the
clock or obligation; persistent chain restrictions can still delay recovery.

Recovery counts one expected total and one pool of located alpha, without assigning
finds to validators. After sync declares a loss, `recoverStray(tokenId, source)`
parks one source per call. Only sync finalizes recovery, collecting returns at
recorded locations first. Neither call extends the clock.
Validator swaps cannot move the secured balance off the vault-owned parking hotkey.
At expiry, sync collects returns before writing off the remaining deficit,
including any dust still outside parking. The dust exposure is per skipped
location, valued at the floor check's price; it is not a bound on future alpha
value. A movable pile gathers smaller balances too. Late dust recovery requires
explicit source keys and belongs to holders at that later time.
Full recovery or write-off leaves the position parked pending a newer attestation.

Write-off chooses repricing over indefinite waiting for missing alpha. It is a
real loss of accounted backing for holders at finalization, not proof the alpha
was destroyed. Any later recovery belongs to whoever holds shares then.

A validator can exploit that policy:

1. Swap its hotkey, carrying vault alpha, then re-register the old key on the
   subnet to erase the successor edge.
2. If watchers cannot park the funded key in time, finalize the write-off.
3. Once the attesters publish again, deposit against the reduced backing to
   acquire a larger share of the supply.
4. Reveal/recover the hidden alpha, or have a later attestation and settlement
   count it. The new shares now participate in that recovery.

For hidden principal `H` with no growth, the original holders' aggregate loss
from this ordering is bounded by `H`: it reallocates the late recovery, rather
than also extracting another `H` from located backing. Emissions or surplus on
the hidden key can make the later windfall exceed the `BackingWrittenOff` amount.
Deposits stay shut between the write-off and the next attestation, so the
attesters decide when step 3 becomes possible.

This is accepted policy and a reason to park before write-off. Afterward,
neither `recoverStray` nor a new attestation reconstructs the old holders' claims.
Following a complete write-off, a zero-floor `unwrap` voluntarily burns worthless
shares and gives up their claim on future recovery. A positive floor preserves
them; accrued TAO survives either way.

## Other accepted limits

- Watcher-assisted recovery permits temporary exit failures, including with intact
  backing. The contract does not skip required alpha-exit alignment to avoid them.
- Stake minimums and rounding can require top-ups or combining shares. A full
  TAO exit may discard sub-floor unsold residue.
- Partial TAO exits can refund unsold alpha as shares; `minTaoOut` bounds the payout,
  not the pool-price effect on remaining holders.
- A mailbox deposit moved by a swap needs manual reclaim and redeposit if its
  actual key is no longer attested.
- A parked position earns no emissions until the attesters publish a new set.
  Any validator in the set can force a parking event by renaming its key and
  cutting the trail.
- Signatures have no expiry; landing a replacement retires a competing old list.
- A dissolved token can wait through a successor's late cleanup when the chain
  no longer distinguishes their registration state.

See [edge cases](edge-cases.md) for dissolution, transfer restrictions and minimums.
