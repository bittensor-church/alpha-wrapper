# Response to the Solidity security audit

Reviewed against `main` at `1f64bb2`. Every cited path was re-read in the current source. Chain
claims were checked against the subtensor pallets (`swap_hotkey.rs`, `hotkey_lineage.rs`,
`uids.rs`) and the runtime's EVM balance converter.

Summary:

| Finding | Audit severity | Our verdict | Action |
|---|---|---|---|
| Recoverable alpha written off, recapitalized, captured | High | Valid; accepted trust assumption on attested validators | Mitigations outside pricing, see below |
| Validator authority survives subnet-generation reuse | Medium | Valid, low impact | Candidate: bind attestations to the registration block |
| One-share holdout captures the virtual-share reserve | Medium | Design choice, no victim | None |
| Full live exit leaves backing for the next depositor | Medium | Valid asymmetry, dust magnitude | None |
| First-deposit preview can be made unattainable | Low | Valid, self-defeating for the attacker | Optional lens change |
| `sharePrice` is not an executable share price | Low | Valid mismatch, dust-seeded pools only | Candidate: quote through `assetsFor` |
| AMM price can preserve an overweight allocation | Low | Not an issue | None |
| Dissolved payouts exceed delivery by under one RAO | Info | Agreed | None |
| Lead: cross-generation blackout coupling | Unverified | Valid, already documented as deliberate | Candidate: check the dissolved branch first |

---

## High - Recoverable alpha can be written off, recapitalized, and captured

**Status: accepted as a trust assumption on attested validators, with mitigations that leave
pricing and liveness untouched.**

The mechanism holds end to end:

- Registering a hotkey on a subnet clears its stale successor edge. Both `replace_neuron` and
  `append_neuron` call `clear_stale_hotkey_successor` on the incoming key, and after a swap the old
  key's owner entry is gone, so its former owner can re-register it. No forward pointer from the
  old key survives; the lineage root map points backward from the new key, which the vault does
  not know.
- The registry accepts a single validator at full weight. Weights must sum to 10000 and the count
  must be at least one; nothing caps one validator's share.
- The vault's own suite documents the outcome. `test_LateFoundAlpha_IsAWindfallForTheCurrentCohort`
  asserts that alpha found after a write-off belongs to whoever holds shares at recovery time.

The attacker's profit, with pool backing `B`, their validator holding fraction `f` of it, and a
deposit `D` made at the write-off deadline, is `D * f * B / (D + (1 - f) * B)`. It approaches `B`
only when the attacker's validator holds nearly the whole pool; at half the pool a deposit of half
the backing captures a quarter of it. The capital is needed for one transaction, since the deadline
is public and the attacker chooses when to start the clock.

Why this stays accepted rather than fixed in the vault:

- The vault cannot distinguish alpha that is gone from alpha that is hidden. Every accounting fix
  reduces to one of two shapes. Blocking deposits until the alpha returns bricks the generation if
  the stake is ever converted to TAO, and a time-bounded block only lengthens the race. Routing
  recovered alpha to the cohort that bore the loss needs per-account balance snapshots at write-off
  time and a second claim index, which is a parallel accounting system the size of the TAO claim
  index. Neither is acceptable for a rail that must stay live.
- The attacker sits inside the trust perimeter. The signer quorum chose that validator and set its
  weight. A validator holding a dominant weight is a trusted party under this design.

Mitigations, none of which touch share pricing:

1. **Cap per-validator weight in the registry.** One comparison in the existing weight loop keeps
   `f` well below one, which makes the attack require capital on the order of the pool for a
   fraction of it.
2. **Lengthen the default recovery window.** The deploy default of 3 hours suits a bot only. A
   window measured in days gives human watchers time as well; the deadline is public through the
   lens.
3. **Run a recovery bot on `BackingShortfallDeclared`.** The chain's swap event names the
   successor, and `recoverStray` is permissionless and cheap. A recovery inside the window ends the
   attack with the attacker out the swap and re-registration costs.

## Medium - Validator authority survives subnet-generation reuse

**Verdict: valid, low impact. Candidate change.**

The signed struct is netuid, hotkeys, weights and nonce, and nonces are keyed by netuid, so a stored
list carries into a new subnet on the same netuid and a withheld attestation replays if no newer one
landed. Principal is never at risk: `unwrap` delivers whatever the list says, and the position is
owned by the clone. The practical effect is that deposits into the new generation are delegated to
the old subnet's hotkeys until the attesters re-sign.

A small change closes both paths: include the registration block in the signed struct and refuse a
list whose block is not the subnet's current one. Deposits then revert with no validators until the
attesters sign a fresh list, which is the fail-closed behavior the rest of the vault follows.

## Medium - A one-share holdout captures the virtual-share reserve

**Verdict: design choice, no victim.**

The virtual-share reserve is owned by nobody in the virtual-offset model. The earlier exiter
received exactly what any such vault pays for a partial burn. Letting the last full burn take the
reserve is strictly better than stranding it in the clone forever, and the full-burn NatSpec on
`unwrapForTao` states this. Its size is bounded by the backing divided by the first deposit in RAO,
which reaches the audit's figure only for a floor-sized seed and a pool at the supply cap.

## Medium - Full live exit leaves backing for the next depositor to exact-sell

**Verdict: valid asymmetry, dust magnitude. No change.**

`_unwrapFromLiveSubnet` prices a full burn through `assetsFor` while the TAO rail claims exact
backing, so a sole holder's live exit leaves the virtual reserve behind. The reserve is roughly the
backing divided by the first deposit in RAO: a one-alpha seed and a million-alpha pool leave a
thousandth of an alpha. Making the live full burn exact would force a full gather across every
slot, which can fail on a dust slot below the chain's move floor and would trade a real liveness
risk for dust. Left as is.

## Low - First-deposit preview can be made unattainable

**Verdict: valid, self-defeating for the attacker. Optional lens change.**

The lens reads an empty record as zero backing while `wrap` settles against the attested keys and
counts alpha already under them. The pre-funded alpha becomes the first depositor's gift, and a
quote used as a strict floor simply reverts until the caller lowers it. The mailbox deposit is
never at risk. If quote parity on the first deposit matters to an integrator, the lens can total
the attested keys' balances when the record is empty.

## Low - `sharePrice` is not an executable share price

**Verdict: valid mismatch, dust-seeded pools only. Candidate change.**

`sharePrice` divides raw backing by real supply while every executing path applies the virtual
offsets. The relative error is one billion over the supply, so it is invisible for any pool seeded
above dust. Quoting one share unit through `assetsFor` aligns the view with execution in one line
and removes the discrepancy for any external consumer.

## Low - AMM price can preserve an overweight validator allocation

**Verdict: not an issue.**

Only a deposit within twice the chain's floor can have half of it fall below the move floor, so
the exposure is bounded to dust-sized deposits, and the next permissionless `rebalance` moves them
once the price is back. There is no path from this to share principal.

## Informational - Dissolved payouts exceed delivery by under one RAO

**Verdict: agreed.**

The runtime drops the bottom nine decimals of a value transfer, so a pro-rata result that is not a
multiple of the native quantum delivers less than the event states. The remainder stays in the
clone and reaches the last redeemer. Bounded below one RAO per redemption.

## Retained lead - Cross-generation blackout coupling

**Verdict: valid, already documented as deliberate. Candidate change.**

`unwrap` checks the netuid-wide blackout before selecting the dissolved-token branch, and the
NatSpec on `requireNotDissolving` says so. The old clone's TAO pot is untouched by a newer subnet's
cleanup on the same netuid, so nothing requires the freeze. Checking the dissolved-token branch
first lifts it.

---

## Findings on the x-ray readiness verdict

The verdict rests on the registry admin's ability to replace the signer quorum at once. That is
the governance model: the vault has no admin, and the registry admin is the one privileged role.
Bounding signer churn and the number of signers is already in place; whether the admin should sit
behind a timelock is a deployment decision outside this codebase.
