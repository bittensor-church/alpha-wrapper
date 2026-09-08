# User guide

Use an EVM account on Bittensor with TAO for gas. Send transactions to the vault
and read quotes from its trusted `AlphaVaultLens`. Check that the lens's `vault()`
matches your vault; this detects a mismatched pair, not a dishonest lens.
See [How it works](overview.md) for the contract layout.

Alpha amounts use 9 decimals (RAO); native TAO amounts, including `minTaoOut`,
use 18-decimal EVM wei. One native RAO is 1e9 wei.

## Wrap staked alpha

1. Read `getCurrentValidators(netuid)` on the lens. The deposit must sit under a
   currently attested hotkey; move your stake there first if needed.
2. Get `getDepositAddress(you, netuid)` from the vault.
3. Convert that EVM address to its Substrate coldkey using
   `addressMapping(address)` at `0x080C` (Frontier HashedAddressMapping).
4. Use Subtensor's `transfer_stake` to send alpha to that coldkey on the same
   subnet, retaining the chosen hotkey.
5. Call `wrap(netuid, chosenHotkey, minSharesOut)` from the EVM account in step 2.

One wrap collects one mailbox hotkey's balance. Use
`previewWrap(tokenId, assets)` to choose your minimum shares; a lower mint reverts
`SlippageExceeded`, leaving the deposit intact. Chain rounding can make execution
differ slightly from the preview. Zero waives the minimum.

A deposit below the vault's conservative stake floor reverts `DepositTooSmall`;
top up the mailbox before retrying. Swaps and registry changes may need recovery
first; a quote alone does not check every transaction prerequisite.

## Shares and exits

Shares transfer as ERC-1155 balances. Keep the token id from `Deposited`:
`currentTokenId(netuid)` only identifies the live subnet generation.
`sharePrice(tokenId)` is alpha per share scaled by 1e18; use
`previewUnwrap(tokenId, shares)` for a specific burn.

### Staked alpha: the default exit

Call `unwrap(tokenId, shares, yourColdkey, minAlphaOut)`. The vault consolidates
dropped validators, pays staked alpha in one transfer, and aligns the remainder
toward current weights. This does not trade against the pool; chain rounding can
still cost a few RAO. Verify the destination coldkey: the chain pays the key you supply.

Choose `minAlphaOut` from `previewUnwrap` with only the rounding tolerance you
accept. It bounds actual recipient credit. Use at least `1` to refuse a zero-alpha
exit. Zero explicitly permits either:

- Burning shares for no alpha after a complete write-off, giving up their claim
  on later-recovered backing. Accrued TAO remains claimable.
- Receiving TAO instead after subnet dissolution.

### Native TAO: market sale

Call `unwrapForTao(tokenId, shares, minTaoOut)`. It sells backing from its actual
recorded keys, ignores registry weights, and pays your EVM account. Pool fees and
price impact reduce proceeds; sales also lower the pool price for remaining holders.
Prefer the alpha exit when available.

There is no TAO market-sale preview. `minTaoOut` bounds execution proceeds in wei.
Unsold alpha is refunded as shares, except that a burn of the entire token supply
discards a sub-floor remainder. A sale yielding nothing reverts `WithdrawTooSmall`.

A full-supply burn uses floor-exempt full stake drains. This is not an unconditional
exit guarantee: ownership, backing, pool execution and slippage checks still apply.
A small holder with co-holders may need a top-up or combine shares with another
holder to clear minimums. Top-ups themselves may need watcher recovery first.

### Dissolved subnet

After cleanup, `unwrap(tokenId, shares, anything, 0)` pays your share of the clone's
TAO refund; the coldkey argument is unused. `previewUnwrap` quotes that TAO amount.
Payouts floor to whole RAO; a smaller slice reverts `ClaimBelowNativePrecision`.
A positive alpha minimum prevents a transaction prepared for alpha from unexpectedly
burning for TAO. See [dissolution](edge-cases.md#subnet-dissolution).

## Recovery status

On a live subnet, `BackingShortfall` blocks wraps, rebalances, both exits and value
quotes until the position parks or the loss is written off. It means expected
alpha is unlocated, not proof it was destroyed. While a loss is on file the
token stays shut (`ShortfallOnFile`) until a `syncBacking` observes full
coverage. Shares still transfer and accrued TAO stays claimable.

The lens exposes:

- `locatedStake(tokenId)`: alpha currently found.
- `isBackingIntact(tokenId)`: whether all recorded expectations are covered and
  no loss is on file.
- `frozenUntil(tokenId)`: zero while the position accounts for itself, the
  maximum value while a shortfall is still undeclared, otherwise the deadline
  at which `syncBacking` can write the loss off.
- `awaitingAttestation(tokenId)`: whether the position rests on the vault's
  parking hotkey.

A parked position pays alpha exits from the parking hotkey: the alpha arrives
delegated to that hotkey and earns nothing until you move it to a validator
with your own `moveStake`. TAO exits, transfers and claims work as usual.
Deposits (`Parked`) and weight alignment wait for the attesters to publish a
new validator set; the first wrap or rebalance after that lands the parked alpha
on the new set.

Passing the deadline does not reopen anything by itself. A further `syncBacking`
parks what is located and writes off the rest, reducing current holders' backing.
An intact backing report does not guarantee an exit either. See the
[watcher runbook](hotkey-swaps.md).

## Claim TAO and reclaim deposits

Native TAO received by a live clone outside exits is indexed to holders when
synchronized. Read `claimableTaoOf(you, tokenId)`; call
`claimTao(tokenId, recipient)` to collect it. Claims survive share transfers and
full exits; sub-RAO residue stays reserved.

Mailbox recovery always acts on your own mailbox:

- `reclaimAlphaFromMailbox(netuid, hotkey, destColdkey)`: return staked alpha,
  including from unlisted hotkeys.
- `reclaimMailboxAlphaAsTao(netuid, hotkey, minTaoOut)`: sell it for native TAO.
- `reclaimTaoFromMailbox(netuid)`: collect native TAO, including dissolution refunds.

Stake recovery still depends on source ownership and chain rules. Disabled alpha
transfers prevent the first method, not the TAO sale itself.

If a swap moved your deposit, wrapping the old key can revert `ZeroAmount`.
Locate the mailbox's stake from chain state/history, reclaim from its actual key,
then redeposit under a currently attested hotkey.
