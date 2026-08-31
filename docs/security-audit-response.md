# Static security review response

- **Review date:** 2026-08-31
- **Reviewed wrapper snapshot:** `f21b70344e2580fb7ff62523d4c52b66727cf75b`
- **Code snapshot assessed for this response:** `890667830e604e3adb12af7fe0cbc9c3dbdca4a9`

This document records the project's response to the four findings from the
source-only security review. A finding marked **resolved** has a merged code
change. **Mitigated** means the repository supplies a recovery procedure but
cannot remove the underlying chain behavior. **Accepted** means the behavior
remains by design after its preconditions and impact were evaluated.

| ID | Original severity | Status | Response |
| --- | --- | --- | --- |
| H-01 | High | Mitigated; residual risk accepted | Wrapper recovery and accounting shipped in [PR #53](https://github.com/bittensor-church/alpha-wrapper/pull/53); watcher recovery for ownerless hotkeys was validated and documented in [PR #54](https://github.com/bittensor-church/alpha-wrapper/pull/54). |
| H-02 | High | Resolved | Zero-destination live unwraps are rejected by [PR #55](https://github.com/bittensor-church/alpha-wrapper/pull/55). |
| M-01 | Medium | Accepted | The complete lockout requires an oversized position in a degenerate pool while the in-kind alpha rail is also unavailable. The runtime, not the wrapper, rejects the oversized sale. |
| L-01 | Low | Accepted | The final alpha unwrapper's virtual-share cut is negligible under expected backing growth. A remediation was evaluated and deliberately not adopted in [PR #56](https://github.com/bittensor-church/alpha-wrapper/pull/56). |

## H-01: ownerless hotkey after a `keep_stake` swap

### Response

The wrapper now records the physical key and last observed backing for each
validator slot, follows one chain-recorded hotkey successor, freezes pricing
when backing cannot be accounted for, and exposes permissionless recovery with
a bounded write-off window. That work shipped in
[PR #53](https://github.com/bittensor-church/alpha-wrapper/pull/53).

An all-subnets `keep_stake` swap is a different case: the stake remains under
the old key while Subtensor removes that key's owner. The backing is still
visible, so no accounting shortfall opens, but the runtime refuses stake
operations until an owner is associated again. The wrapper cannot prevent the
runtime from removing that record.

The selected recovery is operational. A watcher calls
`try_associate_hotkey(hotkey)` without re-registering the key, which restores
the owner record required by stake operations. [PR #54](https://github.com/bittensor-church/alpha-wrapper/pull/54)
documents the procedure and validates end to end that exits work afterwards.
The full procedure is maintained in
[backing-resolution.md](design/backing-resolution.md#what-a-watcher-does).

### Residual risk

Association is not a permanent protocol repair. The first claimant owns the
hotkey and can swap it again, so watchers must claim promptly, retain the key,
and monitor it until the backing has moved or holders have exited. Eliminating
the trigger requires a Subtensor change that preserves an owner while delegated
stake remains. The project accepts this watcher dependency and repeat-griefing
risk rather than making the vault or its clones own validator hotkeys.

## H-02: live unwrap to the zero Substrate coldkey

### Response

[PR #55](https://github.com/bittensor-church/alpha-wrapper/pull/55) adds a
`ZeroColdkey` check inside the live-subnet branch of `unwrap`, before shares are
burned or backing is moved. A malformed destination therefore reverts while the
holder's shares and the vault backing remain unchanged. Dissolved-subnet
redemption is unaffected because it does not use the coldkey argument.

**Disposition:** resolved.

## M-01: oversized stake cannot be sold through the TAO rail

### Response

Subtensor rejects a dynamic-subnet swap input greater than 1,000 times the
pool's alpha input reserve. Once one validator slot exceeds that limit, both a
full removal and the wrapper's full-balance simulation can revert. The wrapper
cannot force the runtime to quote or execute an unsupported swap.

The user loses no shares or backing when this happens: the transaction reverts
atomically. The in-kind `unwrap` rail remains available while alpha transfers
are enabled. A complete exit lock therefore needs both an exceptionally
oversized position relative to pool liquidity and an unavailable alpha-transfer
rail. The condition can also clear when liquidity returns, transfers are
enabled, or subnet dissolution moves the position onto its refund path.

Chunking was considered but does not provide an unconditional remedy: each
sale changes the pool, the runtime may still refuse later chunks, and the vault
must not sell backing belonging to holders who remain. The caller's
`minTaoOut` protects against accepting an unexpectedly poor successful fill,
but no wrapper-side parameter can make an unquotable pool liquid.

**Disposition:** accepted as a liveness risk of a degenerate subnet state. The
project prefers atomic reversion and preservation of the position over adding
complex partial-sale machinery that still cannot guarantee an exit.

## L-01: terminal alpha burn leaves the virtual-share cut

### Response

For backing `B`, outstanding supply `S`, and `1e9` virtual shares, the final
holder's loss under the live-alpha exit is exactly:

```text
loss = ceil(1e9 * (B + 1) / (S + 1e9)) - 1 alpha RAO
```

In the ordinary first-deposit-plus-emissions case, this is the cumulative
backing-per-share growth rounded up, minus one:

| Backing-per-share growth | Final unwrapper's virtual-share cut |
| --- | --- |
| 1x | 0 alpha RAO |
| 2x | 1 alpha RAO |
| 10x | 9 alpha RAO |
| 100x | 99 alpha RAO (`0.000000099` alpha) |
| 1,000x | 999 alpha RAO (`0.000000999` alpha) |

The amount is not formally capped: backing-per-share growth is unbounded, and
Subtensor's movement thresholds are TAO-denominated, so whether an alpha amount
is dust also depends on the subnet price. At a 1:1 alpha/TAO price, however, the
cut does not reach the runtime's 100,000-RAO transfer floor until more than
roughly 100,000x growth, or its 2,000,000-RAO unstaking floor until more than
roughly 2,000,000x growth. Expected losses are therefore far below an
operationally movable amount.

[PR #56](https://github.com/bittensor-church/alpha-wrapper/pull/56) implemented
and reviewed an exact terminal claim, but was closed without merging. The
direct economic benefit to the final holder did not justify retaining the
additional terminal-path quote semantics, documentation, tests, and gas
snapshot surface. Existing chain-side move rounding is separate from this
virtual-share cut.

**Disposition:** accepted. Integrators and holders should treat the final
live-alpha exit as forfeiting the virtual-share cut quantified above, rather
than assuming a hard zero-residue invariant.

## Overall disposition

- H-02 is resolved in the repository source.
- H-01 has a tested operational recovery, with its upstream trigger and watcher
  dependency explicitly accepted.
- M-01 and L-01 are accepted residual risks with their preconditions and user
  impact recorded above.

This response does not re-rate or erase the original findings. It records which
changes shipped and where the project consciously chose operational recovery or
risk acceptance instead.

## Verification note

This response was prepared by inspecting the response snapshot and the linked
pull requests. It changes no contract code. No tests, builds, deployments, or
RPC calls were run for this documentation-only change; remediation-specific
validation is recorded in the linked pull requests.
