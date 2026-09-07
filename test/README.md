# Testing the wrapper

Exercise production behavior through `AlphaVault`, `AlphaVaultLens`, the registry,
and the clones' supported external interfaces. Configure external conditions at
the precompile mocks. Do not expose an internal library through a test-only
external shim or call production arithmetic to calculate its own expected result.
Public return types such as `recordedSlots()` remain part of the wrapper API.

## What the invariant campaigns establish

| Campaign | Independent observation | Scope |
| --- | --- | --- |
| `AlphaAccountingInvariantTest` | Deposited alpha equals mock stake still held plus alpha delivered or sold; observed native payouts match sales; holder balances sum to supply. | One healthy validator, no emissions, losses, or dust sweeping. Deposits must mint shares, calls must succeed, and every run ends by exiting all holders with residue bounded by the number of share conversions. |
| `ClaimableTaoInvariantTest` | Each donation is allocated to the balances that existed when it arrived. Each holder's payouts plus remaining public quote match that historical allocation. Every donated wei is paid or remains on the clone. | Three holders, donations, new deposits, share transfers, claims, and attempted partial TAO exits. Tiny partial exits may fail; this campaign does not establish withdrawal liveness. |
| `BackingInvariantTest` | Public located/tracked backing is bounded by precompile balances across every touched hotkey. A successful recovery preserves previously covered slots and heals a short slot when backing was short. | Validator changes, successor responses, moved stake, attempted deposits and exits. Refusals are allowed in this fault campaign; these bounds alone cannot establish conservation or liveness. |

All three campaigns reject unexpected handler reverts. Expected wrapper refusals
are caught explicitly in the fault and partial-exit actions.

The healthy campaign tops up a holder through `wrap` when transfers leave their
position below the mocked exit minimum. Its exit guarantee therefore applies to
adequately funded positions. This is an explicit precondition, not a claim that
arbitrarily small holdings can always exit. Integer rounding can accumulate over
repeated deposit/exit cycles. The closing residue budget allows one alpha RAO
per successful mint or exit in this bounded, constant-price campaign; the exact
conservation check still accounts for that entire residue as held alpha.

The donation model keeps a simple ledger per arrival, without reconstructing the
vault's index or debt checkpoints. The campaign asserts supply stays below `1e36`,
so each index-truncation step changes a holder's entitlement by less than one wei.
For each holder, a donation has two rounding steps (allocation and index truncation);
an exit with a share refund has at most four checkpoint/debt floors. Four wei per
action cover either case, with one extra action's allowance for the pending read
and one native transfer quantum for quote truncation. The exact cash-conservation
assertion has no tolerance. Donations received at zero supply are assigned when
the next holders enter. The separate near-cap fuzz case below permits the larger
index-rounding residue at that supply.

Reserve bounds detect overpayment but cannot detect missing accrual. The holder
entitlement check also requires earned donations to remain claimable. Backing
bounds cannot detect a vault that refuses every exit; the healthy campaign
requires withdrawals to succeed and closes every holder's position.

## Fixtures and expectations

- The accounting campaigns use alpha quantities in RAO and enable native
  precompile payouts at `1e9` wei per TAO RAO. Arithmetic stress fixtures
  deliberately retain their simplified one-wei payout scale. They test wrapper
  arithmetic, not the fidelity of a blockchain implementation.
- The staking mock controls observable precompile responses: balances, ownership,
  successors, quotes, rounding, partial fills, and failures. It is not a second
  implementation of the chain. Live scenarios cover actual precompile behavior.
- Deposit helpers add to existing mailbox balances. A failed wrap must not make a
  later simulated deposit erase the earlier one. Balance helpers whose names end
  in `AndWriteOffShortfalls` also synchronize and expire recovery; recovery tests
  should set the precompile response directly instead.
- A configured zero-loss transfer supports exact balance assertions. Use a named
  tolerance only when the scenario actually enables rounding or allows emissions.
- The rounding regression uses named actors and effective transaction inputs from
  the saved trace. Changing a fuzz handler's bounds cannot silently change it.
- Gas snapshots distinguish twenty repeated token IDs from twenty distinct
  positions. Only deterministic tests contribute to `.gas-snapshot`; fuzz and
  invariant campaigns run separately in CI. See the root README for regeneration.

## Public API coverage

The public suites cover first deposits, zero deposits, share round trips,
token generation, validator validation, successor recovery, dissolution phases,
reserved claims, and supply bounds. `AlphaVaultPublicPropertiesTest` additionally
checks claim quantization, the backing-slack boundary and full error payload,
and a full deposit/exit with configured transfer losses. Its near-cap fuzz grows
supply through finalized losses and recapitalization to 90–100% of the share cap,
then exercises public quotes, exits, donations, and claims against 64 validators
with individual stake balances bounded by `uint64`. Pure array helpers and
duplicated arithmetic formulas are intentionally not independent test targets.

## Live scenarios

E2E revert assertions require a mined receipt with status `0x0`; a command or RPC
failure must fail setup rather than masquerade as the expected contract refusal.
For native payouts, add the transaction's gas cost back to the caller's balance
change. Compare sales to the precompile quote and the reported event; compare
dissolution refunds to the holders' shares of the available pot.

The emissions-enabled liveness scenario exercises two specified cycles of dust
and validator rotation. Its closing lower bound is not a conservation invariant,
since emissions can increase backing between observations. Exact conservation is
covered by the isolated healthy campaign above. Live gas and precompile rounding
must still be checked by the fresh-localnet E2E matrix.
