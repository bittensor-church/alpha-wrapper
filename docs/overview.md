# How the alpha wrapper works

The wrapper turns staked alpha on a Bittensor subnet into ERC-1155 tokens
on the same chain's EVM. You hand it alpha that is already staked; it keeps
that alpha staked under its own coldkeys and mints you shares. Shares are
fungible and transferable, and can normally be redeemed for the staked
alpha or for its TAO value.

## The contracts

`AlphaVault` is the contract users send transactions to. It is an ERC-1155
with one token id per subnet position and holds all the logic,
permissionless and final at deployment.

`AlphaVaultLens` answers the questions: how much alpha backs a position,
what a share is worth, what a deposit or an exit would pay, and how much
TAO you can claim. It is deployed alongside a vault, stores nothing, and
can only read, so there is nothing to trust it with. It reads the same
chain state the vault reads, so its answers are the ones the vault acts on.

Each subnet position gets its own `SubnetClone`, a minimal proxy whose EVM
address maps to a substrate coldkey. All alpha backing a token id is staked
under that one coldkey, so each position's backing stays isolated. Only
the vault can drive a clone.

Each (user, subnet) pair gets a `DepositMailbox` at a deterministic
address. You deposit by transferring staked alpha to the mailbox's coldkey
and then telling the vault to collect it. The mailbox is what makes a
deposit attributable: the vault only ever credits you for stake sitting in
your own mailbox.

`ValidatorRegistry` says which validators the vault should stake under,
per subnet, and in what proportions. Its entries are set by a threshold of
off-chain signers (see [attester-guide.md](attester-guide.md)), and the
vault takes its validator sets from the registry alone.

## Token ids

A token id encodes the subnet and its registration block: the low 16 bits
are the netuid, the bits above are the block the subnet was registered at.
`currentTokenId(netuid)` computes the id for the currently live subnet.

If a subnet is dissolved and its netuid later reused, the new subnet gets
a new token id. Old shares keep pointing at the old position and its TAO
refund.

The first `wrap` on a subnet deploys the clone and opens the position;
`createSubnetProxy(netuid)` deploys it ahead of time.

## Share price

Shares are priced by the ratio of staked alpha to share supply, with the
same virtual offsets every rail applies. The lens call `sharePrice(tokenId)`
returns alpha per share, scaled by 1e18, matching what a live unwrap of one
share unit pays. A written-off position recapitalized at the virtual rate
can leave a share unit worth less than that scale expresses; the call then
reverts `SharePriceBelowPrecision` instead of answering zero, and
`previewUnwrap` still prices any burn. Staking
emissions accrue to the clone's stake, so the price rises over time and
later depositors mint fewer shares per alpha. The price counts staked
alpha only; native TAO sitting on the clone is owed to specific holders
and tracked separately (see [edge-cases.md](edge-cases.md)).

## Where the stake sits

The registry lists between one and 64 validator hotkeys per subnet, with weights
in basis points. Deposits and alpha exits rebalance the clone's stake
toward those weights as a side effect, and anyone may call
`rebalance(netuid)` to realign immediately, for example right after the
registry changes; the TAO exit sells from wherever the stake sits.
Moves the chain would reject as too small are skipped; a
drifted split is harmless because share value depends on the total stake
alone.

When the registry drops a validator, the next deposit, alpha exit or
`rebalance` first rolls the stake off it onto the current set. The vault
remembers where it put every validator's alpha, so the roll finds stake on
validators the registry has since dropped.

## Backing the vault cannot find

That record is also how the vault notices backing going missing. A
validator swapping its hotkey carries the vault's alpha to a new key, and
the chain sweeps small stake entries without recording why - neither
involves a vault call. The vault follows the chain's own successor edge one
hop, which resolves the ordinary swap unaided; anything deeper shuts the
token for a recovery window fixed at deployment, in which anyone may point
the vault back at the alpha. Whatever is still missing at the deadline is
written off across the holders of the moment. The operational behavior is in
[edge-cases.md](edge-cases.md#a-validator-swaps-its-hotkey); the late-recovery
ownership and adversarial ordering are in
[security-model.md](security-model.md#recovery-window-tradeoff-and-late-recovery-attack).
