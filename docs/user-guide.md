# User guide

You need an EVM account on the Bittensor chain with TAO for gas, and alpha
already staked on the subnet you want to wrap. Read
[overview.md](overview.md) first if the vault is new to you.

## Wrapping

1. Check the validator set: `getCurrentValidators(netuid)` returns up to
   three hotkeys. Pick one; the deposit must sit under a hotkey from this
   set or `wrap` refuses it.
2. Get your deposit address: `getDepositAddress(you, netuid)`. This is an
   EVM address controlled by the vault, unique to you and the subnet.
3. Convert that address to a substrate coldkey. On-chain, the
   address-mapping precompile at 0x0000...080C returns it via
   `addressMapping(address)`. Off-chain it is Frontier's
   HashedAddressMapping; `e2e/alpha_e2e/substrate.py` has a reference
   implementation.
4. Transfer your staked alpha to that coldkey with a substrate
   transfer_stake call, same subnet, keeping it under the hotkey you
   picked.
5. Call `wrap(netuid, chosenHotkey)` from the same EVM account you used in
   step 2. The vault collects the mailbox balance under that hotkey and
   mints shares to you.

One `wrap` collects one hotkey's balance, so stake parked under several
hotkeys takes one call each. A deposit whose TAO value is below the
chain's minimum stake size is refused (`DepositTooSmall`); top the mailbox
up and wrap once. `previewWrap(tokenId, assets)` quotes the share amount
beforehand.

## What you hold

Shares are ERC-1155 balances under `currentTokenId(netuid)`. They transfer
like any ERC-1155 token. `sharePrice(tokenId)` gives alpha per share
(1e18-scaled), so your alpha is `balance * sharePrice / 1e18`. Keep note
of your token id (it is indexed in the `Deposited` event): if the subnet
is ever dissolved you will need it, because `currentTokenId` only answers
for live subnets.

## Exiting

There are two exits from a live subnet, and a third path once a subnet is
gone.

`unwrap(tokenId, shares, yourColdkey)` returns staked alpha. The vault
burns the shares and transfers your pro-rata alpha to `yourColdkey` in a
single transfer. The alpha arrives still staked on the subnet, under one
of the current validators; unstake it yourself if you want liquid TAO.
Delivery is all-or-nothing: you receive the full quote, to within a few
RAO of chain-side rounding, or the call reverts. A request below the
chain's minimum stake size reverts (`WithdrawTooSmall`); use the TAO exit
for those. Double-check the coldkey argument - the chain delivers to
whatever key you name.

`unwrapForTao(tokenId, shares, minTaoOut)` sells your share of the backing
into the subnet's pool and pays you native TAO on your EVM address. This
is a market order: the payout depends on pool depth and fees, and there is
no preview, so protect yourself with `minTaoOut`. If the chain will not
take part of the sale cleanly, that part stays staked and comes back to
you as shares; you only burn what actually sold. This exit also works for
positions too small for `unwrap`: a burn of your full balance drains every
slot completely, and the chain exempts full drains from its minimum.

After a subnet dissolves, `unwrap(tokenId, shares, anything)` pays your
pro-rata part of the subnet's TAO refund in native TAO; the coldkey
argument is unused there. See [edge-cases.md](edge-cases.md) for the
dissolution timeline.

`previewUnwrap(tokenId, shares)` quotes the alpha exit on a live subnet
and the TAO payout on a dissolved one. It never quotes `unwrapForTao`.

## Claimable TAO

The vault's clone can receive native TAO that is not part of any exit -
the chain force-selling dust, or a plain donation. That TAO is credited
pro-rata to the holders of the token at that moment and does not move the
share price. `claimableTaoOf(you, tokenId)` shows your balance;
`claimTao(tokenId, recipient)` pays it out. The entitlement survives
transfers and full exits, so unwrapping does not forfeit it.

## Fixing mistakes

Alpha in your mailbox is yours until wrapped, and the vault hands it back
on request:

- `reclaimAlphaFromMailbox(netuid, hotkey, destColdkey)` transfers it to
  any coldkey. Use this if you parked stake under a hotkey outside the
  validator set, or changed your mind before wrapping.
- `reclaimMailboxAlphaAsTao(netuid, hotkey, minTaoOut)` sells it and pays
  you native TAO instead.
- `reclaimTaoFromMailbox(netuid)` recovers native TAO sitting on the
  mailbox address, such as a dissolution refund that arrived before you
  wrapped.
