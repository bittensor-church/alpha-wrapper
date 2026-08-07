# How the alpha wrapper works

The wrapper turns staked alpha on a Bittensor subnet into ERC-1155 tokens
on the same chain's EVM. You hand it alpha that is already staked; it keeps
that alpha staked under its own coldkeys and mints you shares. Shares are
fungible and transferable, and can be redeemed at any time for the staked
alpha or for its TAO value.

## The contracts

`AlphaVault` is the only contract users talk to. It is an ERC-1155 with one
token id per subnet position and holds all the logic. It has no owner, no
admin and no upgrade path.

Each subnet position gets its own `SubnetClone`, a minimal proxy whose EVM
address maps to a substrate coldkey. All alpha backing a token id is staked
under that one coldkey, so positions on different subnets can never mix.
Only the vault can drive a clone.

Each (user, subnet) pair gets a `DepositMailbox` at a deterministic
address. You deposit by transferring staked alpha to the mailbox's coldkey
and then telling the vault to collect it. The mailbox is what makes a
deposit attributable: the vault only ever credits you for stake sitting in
your own mailbox.

`ValidatorRegistry` says which validators the vault should stake under,
per subnet, and in what proportions. Its entries are set by a threshold of
off-chain signers (see [attester-guide.md](attester-guide.md)). The vault
reads the registry and nothing else; there is no fallback source of
validator sets.

## Token ids

A token id encodes the subnet and its registration block: the low 16 bits
are the netuid, the bits above are the block the subnet was registered at.
`currentTokenId(netuid)` computes the id for the currently live subnet.

If a subnet is dissolved and its netuid later reused, the new subnet gets
a new token id. Old shares keep pointing at the old position and its TAO
refund; they do not carry over.

There is no setup call. The first `wrap` on a subnet deploys the clone and
opens the position.

## Share price

Shares are priced by the ratio of staked alpha to share supply.
`sharePrice(tokenId)` returns alpha per share, scaled by 1e18. Staking
emissions accrue to the clone's stake, so the price rises over time and
later depositors mint fewer shares per alpha. Native TAO sitting on the
clone is never part of this price; it is owed to specific holders and
tracked separately (see [edge-cases.md](edge-cases.md)).

## Where the stake sits

The registry lists up to three validator hotkeys per subnet, with weights
in basis points. Deposits and withdrawals rebalance the clone's stake
toward those weights as a side effect, and anyone may call
`rebalance(netuid)` to realign immediately, for example right after the
registry changes. Moves the chain would reject as too small are skipped;
a drifted split is harmless because share value depends on the total
stake, not on how it is split.

When the registry drops a validator, the next state-changing call first
rolls the stake off it onto the current set. The vault remembers which
hotkeys it last used (`lastSeenHotkeys`), so backing is never forgotten on
a rotated-out validator.
