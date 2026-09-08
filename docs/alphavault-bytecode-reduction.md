# AlphaVault bytecode reduction

Base: freshly fetched `origin/main`, `2c3a63067d7d4c048f4fdb6dc1eea26497b24653`
(8 September 2026). Implementation branch: `codex/alphavault-bytecode`.

Move the stake-movement routines into the already linked `VaultAllocation`
library. The measured AlphaVault runtime falls from **24,355 to 22,488 bytes**:
**1,867 bytes saved (7.67%)**, with **2,088 bytes** below the 24,576-byte EIP-170
limit instead of 221 bytes. This exceeds both a decimal kilobyte and 1 KiB.

## Measurements

All variants use the committed compiler settings: Solidity 0.8.28, Cancun,
`via_ir = true`, optimizer enabled with 200 runs, and the default IPFS metadata.
Foundry is v1.7.1; dependencies match the pinned submodule commits.
Sizes count the entire deployed-bytecode object, including metadata and the
20-byte library-address placeholders. Linking fills those addresses without
changing the length. These are compiled measurements, not source-map estimates.

| Variant | AlphaVault runtime | Saved vs main | VaultAllocation runtime |
| --- | ---: | ---: | ---: |
| Latest main | 24,355 B | — | 2,797 B |
| Extract weight-alignment loop only | 23,811 B | 544 B | 4,119 B |
| Also extract rotated-stake consolidation | 23,344 B | 1,011 B | 4,891 B |
| Also extract payout gathering and rebalance balance reads (implementation) | 22,488 B | **1,867 B** | 6,434 B |

AlphaVault creation bytecode also falls from 25,631 to 23,764 bytes, excluding
constructor arguments. Runtime size is the metric relevant to EIP-170.

## What changes

The vault delegates three operations to `VaultAllocation`:

- `consolidateRotatedStake`: bring balances from dropped validators onto the
  current destinations, including the existing dust and write-off behavior.
- `rebalance`: read balances and execute the existing bounded weight-alignment loop.
- `deliverAndAlign`: gather an alpha payout, measure recipient credit, and align
  the remainder.

The algorithm bodies are copied from main. Sixteen moved/copied function bodies
were compared mechanically after ignoring whitespace, comments, and the change
from an external to an internal `chooseRichestSlot` call. The latter is now
`public` in the library so consolidation can call it internally.

Shares, the TAO index, backing gates, recovery state, slippage checks, and the
reentrancy guard remain in AlphaVault. The moved routines do not access storage.
They change clone/precompile state through the same calls and in the same order.
The caller does not consume mutations to the memory arrays after these library
calls; accounting still reads actual balances when settling.

This is an **external, deployed Solidity library**, already part of main's
architecture. Solidity uses `DELEGATECALL` for its external library functions,
preserving the vault's execution context. Consequently the clones and neuron
precompile still see the vault as caller, and `Rebalanced` still emits from the
vault. The two event regression tests now explicitly assert that emitter address.
See the [Solidity 0.8.28 library documentation](https://docs.soliditylang.org/en/v0.8.28/contracts.html#libraries).

The existing deployment script and E2E bootstrap already deploy and link
`VaultAllocation`. A new deployment must use the rebuilt library, whose address
is fixed in the linked vault bytecode. This does not add upgradeability or change
an existing on-chain vault.

## Tradeoffs

This moves code across contract boundaries; it does not reduce total deployed
code. The library grows by 3,637 bytes, so vault-plus-library runtime grows by
1,770 bytes. Both contracts fit comfortably under the individual size limit.
The library incurs extra one-time deployment cost, and delegated operations pay
for argument encoding, memory copies, and call overhead. Gas forwarding also
crosses an additional call boundary on some paths. Small ownership/move/flush
helpers remain in both contracts because the vault's mailbox and sale paths
still need them.

No feature removal or compiler-setting change is needed. The older repository
notes proposing a lens split concern an earlier branch; main already has that
split, so those old savings cannot be claimed again.

## Validation and reproduction

Solidity's ABI and storage-layout outputs were compared against the pinned base:
all 93 ABI entries are identical, including errors and events, and all 14 storage
entries have identical slots, offsets and recursively resolved types. The two
errors emitted only by moved routines are explicitly declared on AlphaVault so
they remain in its ABI. All 49 remaining vault function bodies match main after
normalizing the three library-call substitutions.

The single final snapshot-regeneration run passed **503 tests across 17 suites**,
with zero failures or skips. It regenerated `.gas-snapshot` and
`snapshots/AlphaVault.json`. Fuzz and invariant tests were excluded and are left
to CI. `forge fmt --check` also passed. The final test-build artifacts confirm the
runtime sizes above and the identical ABI and function selectors.

The separately measured main-branch gas fixtures reproduced its committed
per-call snapshots exactly. Representative changes from those snapshots:

| Mocked operation | Main gas | New gas | Change |
| --- | ---: | ---: | ---: |
| First wrap | 732,952 | 738,286 | +0.73% |
| Subsequent wrap | 387,402 | 393,190 | +1.49% |
| Partial alpha unwrap | 327,550 | 334,085 | +2.00% |
| Full alpha unwrap | 264,488 | 271,447 | +2.63% |
| Rebalance after weight update | 239,908 | 245,694 | +2.41% |
| Full alpha unwrap, 64 validators | 3,498,647 | 3,551,718 | +1.52% |
| Partial alpha unwrap, 64 validators | 5,303,138 | 5,348,658 | +0.86% |
| Fully rotated rebalance, 64 validators | 10,776,335 | 10,769,690 | -0.06% |
| Recover and park one lost slot, 64 validators | 2,433,810 | 2,420,388 | -0.55% |

The largest measured per-call increase is 2.63%; the largest absolute increase
is 53,071 gas on a full alpha unwrap with 64 validators. All measured TAO exits,
shortfall sync and lens calls are unchanged. These figures do not include the
one-time deployment cost of the larger library.

From this worktree, build production contracts and inspect their runtime sizes:

```sh
forge build --sizes --skip test --skip script
forge inspect AlphaVault deployedBytecode | python3 -c 'import sys; print(len(sys.stdin.read().strip().removeprefix("0x")) // 2)'
FOUNDRY_PROFILE=ci FOUNDRY_GAS_SNAPSHOT_CHECK=false FOUNDRY_GAS_SNAPSHOT_EMIT=true \
  forge snapshot --tolerance 1 --no-match-contract Invariant --no-match-test testFuzz --threads 4
forge fmt --check
```

Build the pinned base in a separate worktree with the same dependency commits
and settings to reproduce the before measurement. Gas snapshots use the existing
`test/AlphaVault.gas.t.sol` suite on both versions. They use mocked precompiles;
live localnet E2E remains necessary for chain-level gas and rounding validation.
