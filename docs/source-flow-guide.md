# Alpha Wrapper: following the flow

A short guide to the wrapper's control flow.

## What lives where

```text
User's stake -> personal DepositMailbox -> pooled SubnetClone
                         wrap                  |
                                              +-> alpha delegated to hotkeys
                                              +-> native TAO balance

AlphaVault: shares and accounting     ValidatorRegistry: target keys and weights
```

## Why there are several kinds of key

The registry names a validator, but a rename can move its stake elsewhere.

- `logical`: the name associated with a recorded slot.
- `active`: the last recorded location of its stake.
- `tracked`: the alpha expected at the last record update.
- `Backing.keys`: locations resolved now, possibly after following one swap.

Example: after A renames to B, the record can say `logical = A, active = B`.
Locating backing and choosing a receiver are separate checks: a receiving key
must also belong to the owner recorded when the validator was attested.

## The lifecycle

```text
Missing backing -> syncBacking declares a shortfall
                       |
                       +-> backing returns + syncBacking -> cleared
                       +-> enough stake found + recoverStray -> parked
                       +-> first loss of a slot in this period + syncBacking -> restart window
                       +-> expired, no unseen missing slot + syncBacking -> write off; parked

Parked -> newer registry attestation -> next wrap/rebalance/alpha exit can
                                       apply the set and clear parked state
Parked -> live alpha or TAO exit leaves no shares -> parked state cleared
```

A detected shortfall already blocks ordinary live deposits and exits. Declaring
it starts the clock. Each slot can restart it once per unresolved recovery period,
before write-off; returning and losing that slot again does not extend it.
Time alone never clears it or executes a write-off. Recovery
can also park a shortfall before declaration. Attestations do not move stake.

Parking blocks deposits and rebalancing until a newer attestation. Exits can use
parked backing, subject to execution checks. Transfers and accrued TAO claims
remain separate. Dissolution takes another path: exits wait through applicable
cleanup, then old shares redeem the clone's unreserved TAO.

## Follow a transaction

- **`wrap`:** check backing and receivers -> collect the caller's mailbox stake
  at the chosen registry hotkey -> consolidate dropped keys -> align weights ->
  record actual balances -> calculate and mint shares. Collecting first lets a
  fresh deposit help move old dust; pricing uses the balances after movement.
- **Live `unwrap`:** check backing -> select destinations -> consolidate dropped
  keys -> price and burn shares -> gather and transfer staked alpha -> align the
  remainder -> update records. Check the recipient's actual credit against the
  minimum. A parked exit uses its recorded locations and skips weight alignment.
- **`unwrapForTao`:** check backing -> budget alpha and burn shares -> sell whole
  slots before partials -> measure proceeds and remaining alpha -> pay TAO ->
  refund eligible unsold alpha as shares. This path does not apply registry weights.
- **Dissolved `unwrap`:** exclude reserved TAO claims -> calculate a proportional
  refund -> burn shares -> pay native TAO. The caller must pass zero for `minAlphaOut`.

## Three details that explain surprising code

1. **Moving dust can require moving a large balance through it.** To collect 1
   unit at B into 100 at A, the code can move A's 100 to B, then 101 back to A.
   This clears a move minimum that the 1-unit transfer could not. Chain rounding
   requires fresh balance reads. Weight alignment may skip small moves.
2. **Minting, burning, and transferring also settle TAO.** `_update` synchronizes
   TAO and credits accounts using their old balances, changes shares, then resets
   their accounting debt. Accrued TAO stays with the account after its shares leave.
   A TAO sale pays before refund minting so proceeds do not enter that shared index.
3. **Reading and recording differ.** `_openBacking` resolves and checks without
   writing. `_settle` replaces the allocation record; `_reanchor` updates locations
   and balances while keeping slot identities.

Start tracing in `AlphaVault`. `VaultReads` resolves keys; `VaultAllocation`
moves stake. For recovery details, use the [runbook](hotkey-swaps.md).
