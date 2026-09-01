# User guide

You need an EVM account on the Bittensor chain with TAO for gas, and alpha
already staked on the subnet you want to wrap. Read
[overview.md](overview.md) first if the vault is new to you.

Two addresses matter. You send every transaction to the vault. You read
every quote - backing, share price, deposit and exit previews, claimable
TAO, and the validator set - from the lens deployed alongside it. Take the
lens address from the same place you took the vault address from. A lens is
ordinary code that anyone can deploy, and the chain marks none of them as
official.

Then check that the two agree: `vault()` on the lens returns the vault it
reads, and it must equal the address you send transactions to. That catches
a lens left over from an earlier vault, which would keep answering with
that vault's numbers. It tells you the two addresses agree, and that is all
it tells you - any contract can return the right address from `vault()` and
still invent every quote it gives you. What makes the quotes real is where
the address came from.

If you are building a contract on top of the vault, pin the lens address at
deployment and compare its runtime code against the lens you reviewed. A
quote that sizes a slippage bound is worth attacking, so accepting a lens
address as a call argument is a way to be paid less than you asked for.

## Wrapping

1. Check the validator set: `getCurrentValidators(netuid)` on the lens
   returns the subnet's hotkeys, one to 64. The vault only accepts deposits sitting under one of
   them; if your stake is delegated elsewhere, first move it under one
   of these with the chain's move_stake call.
2. Get your deposit address: `getDepositAddress(you, netuid)`. This is an
   EVM address controlled by the vault, unique to you and the subnet.
3. Convert that address to a substrate coldkey. On-chain, the
   address-mapping precompile at 0x0000...080C returns it via
   `addressMapping(address)`; off-chain it is Frontier's
   HashedAddressMapping.
4. Transfer your staked alpha to that coldkey with a substrate
   transfer_stake call, same subnet. The stake stays under its hotkey,
   which is why that hotkey must be one of the validators from step 1.
5. Call `wrap(netuid, chosenHotkey, minSharesOut)` from the same EVM
   account you used in step 2, naming the hotkey your deposit sits under.
   The vault collects the mailbox balance under that hotkey and mints
   shares to you.

One `wrap` collects one hotkey's balance, so stake parked under several
hotkeys takes one call each. A deposit whose TAO value is below the
chain's minimum stake size is refused (`DepositTooSmall`); top the mailbox
up and wrap once. `previewWrap(tokenId, assets)` quotes the share amount
beforehand, and `minSharesOut` is the floor you will accept if the rate
moves between that quote and your call: under it the wrap reverts
`SlippageExceeded` and your deposit stays in the mailbox, untouched. The
quote is exact bar the RAO or so the chain keeps while moving your deposit,
so a bound a hair below it is enough; `0` waives the check.

## What you hold

Shares are ERC-1155 balances under `currentTokenId(netuid)`. They transfer
like any ERC-1155 token. `sharePrice(tokenId)` gives alpha per share
(1e18-scaled), so `balance * sharePrice / 1e18` estimates your alpha; the
exact quote for a given burn comes from `previewUnwrap`, whose rounding
differs a little. Keep note
of your token id (it is indexed in the `Deposited` event): if the subnet
is ever dissolved you will need it, because `currentTokenId` only answers
for live subnets.

## Exiting

There are two exits from a live subnet, and a third path once a subnet is
gone. **`unwrap` is the default - use `unwrapForTao` only when `unwrap`
cannot serve you.**

`unwrap(tokenId, shares, yourColdkey)` returns staked alpha. The vault
burns the shares and transfers your pro-rata alpha to `yourColdkey` in a
single transfer. The alpha arrives still staked on the subnet, under one
of the current validators; unstake it yourself if you want liquid TAO.
Because nothing here trades against the subnet's pool, an exit through
this rail costs exactly your pro-rata share and leaves every other
holder's backing untouched. Delivery is all-or-nothing: you receive the
full quote, to within a few RAO of chain-side rounding, or the call
reverts. A request below the chain's minimum stake size reverts
(`WithdrawTooSmall`); see the TAO exit below for the way out. Double-check
the coldkey argument - the chain delivers to whatever key you name.

`unwrapForTao(tokenId, shares, minTaoOut)` sells your share of the backing
into the subnet's pool and pays you native TAO on your EVM address. Treat
this as an opt-in, risk-on exit, not a convenience rail: it is a market
order executed against the pool, and your sells move that pool's price
permanently - the proceeds (up to your `minTaoOut`) are yours, but the
depressed price stays with everyone still holding the token. An exit
through `unwrap` has no such side effect, so this rail earns its place
only when `unwrap` is unavailable - the subnet owner has disabled alpha
transfers (see [edge-cases.md](edge-cases.md)), or your position is below
the chain's floor for `unwrap`. The payout itself depends on pool depth
and fees at execution, and `minTaoOut` is your only protection. Mind the
units: native TAO amounts, `minTaoOut` included, are 18-decimal EVM wei,
while alpha amounts use the chain's 9 decimals - a floor quoted in alpha
units is a billion times too low. Whatever the chain leaves unsold stays
staked and comes back to you as shares, so you only burn what actually
sold. The exception is a burn of the token's entire supply, which drops a
leftover below the chain's minimum.

This is also the exit for positions too small for `unwrap`: a burn of
the token's entire supply is exempt from the chain's minimum, so the
last holder can always sell - at worst the pool fills short and part
comes back as shares for another try. With other holders in the token a
sub-minimum burn is refused (`WithdrawTooSmall`); top your position up
with one more deposit, then exit.

After a subnet dissolves, `unwrap(tokenId, shares, anything)` pays your
pro-rata part of the subnet's TAO refund in native TAO; the coldkey
argument is unused there. See [edge-cases.md](edge-cases.md) for the
dissolution timeline.

`previewUnwrap(tokenId, shares)` quotes the alpha exit on a live subnet
and the TAO payout on a dissolved one; the TAO market order is priced
only at execution, bounded by your `minTaoOut`.

## When the vault refuses to quote

Every quote and every alpha-moving call can revert `BackingShortfall`.
That means the vault is holding alpha it cannot currently account for -
usually a validator hotkey swap it could not follow - and it will not
value or move the position until the alpha is found or a recovery
window runs out (its length is fixed at deployment; the vault's
`recoveryWindow` reports it). Your shares still transfer and your claimable
TAO still pays out throughout.

`isBackingIntact(tokenId)` and `frozenUntil(tokenId)` on the lens report
the state without reverting, and `locatedStake(tokenId)` reports what the
vault can currently find. `frozenUntil` returns zero when nothing is
missing, the maximum uint256 when the loss has no clock yet - anyone can
start one with `syncBacking(tokenId)` on the vault - and otherwise the
unix time from which a further `syncBacking` can write the loss off.
That call reopens the token, and whatever is still missing falls on
everyone holding shares at that moment. See
[edge-cases.md](edge-cases.md).

## Claimable TAO

The vault's clone can receive native TAO outside any exit - the chain
force-selling dust, or a plain donation. That TAO is credited pro-rata
to the holders of the token at that moment and leaves the share price
untouched. `claimableTaoOf(you, tokenId)` shows your balance;
`claimTao(tokenId, recipient)` pays it out. The entitlement survives
transfers and full exits.

## Fixing mistakes

Alpha in your mailbox is yours until wrapped, and the vault hands it back
on request:

- `reclaimAlphaFromMailbox(netuid, hotkey, destColdkey)` transfers it to
  any coldkey. Use this if you parked stake under a hotkey outside the
  validator set, or changed your mind before wrapping. It moves stake
  between coldkeys, so it reverts while the subnet owner has alpha
  transfers disabled ([edge-cases.md](edge-cases.md)); the TAO variant
  below keeps working.
- `reclaimMailboxAlphaAsTao(netuid, hotkey, minTaoOut)` sells it and pays
  you native TAO instead.
- `reclaimTaoFromMailbox(netuid)` recovers native TAO sitting on the
  mailbox address, such as a dissolution refund that arrived before you
  wrapped.

If your `wrap` reverts `ZeroAmount` even though you deposited, the
validator likely swapped its hotkey after your deposit arrived - the
swap carries mailbox stake to the new key along with everything else.
Retry in three steps: find the key holding your deposit (the chain
records the swap, and any block explorer shows where your mailbox's
stake sits), call `reclaimAlphaFromMailbox(netuid, thatKey, yourColdkey)`
to take it back, then stake it toward a validator currently in the
attested set and `wrap` again.
