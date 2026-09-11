"""A stranger cuts the trail behind a validator's rename; the watcher parks the position.

A validator renames its hotkey on every subnet, which moves the vault's alpha to the
new name and records the edge the vault follows. Before the vault records that, a
stranger renames a junk key onto the vacated name: the chain lets anyone claim a name
with no owner, and the rename erases the name's own edge. The vault can no longer find
the alpha and refuses every priced operation.

The watcher calls `syncBacking`, recovers the successor with `recoverStray`, and syncs
again. Backing rests on the vault's parking hotkey, and the vault holds
deposits and weight alignment shut until the attesters publish a set without the
vacated name. Exits keep working from the parking hotkey throughout.
"""
import pytest

from alpha_e2e import config, incidents


@pytest.mark.scenario
def test_watcher_parks_a_position_whose_trail_a_stranger_cut(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)
    clone_coldkey = env.clone_coldkey(token_id)
    parking_hotkey = env.parking_hotkey()

    env.deposit_and_wrap(
        netuid, hotkeys[0], env.hotkey_ss58s[0],
        config.PER_HOTKEY_TRANSFER_RAO, 1_500_000, "Parked recovery: wrap failed",
    )
    shares = env.vault_shares(token_id)
    assert shares != 0, "no shares minted by the setup wrap"

    stranding = incidents.cut_trail(env, 0, 0, "//ParkedSuccessor", "//ParkedJunk", "Parked recovery")
    lost_pubkey, successor_pubkey = stranding.lost_pubkey, stranding.successor_pubkey
    env.assert_vault_reverts_with(
        "BackingShortfall(uint16,bytes32,uint256)", 1_500_000,
        "Parked recovery: a priced operation should refuse while the alpha is unlocated",
        "rebalance(uint256)", netuid,
    )

    # Sync declares the loss, recovery collects the successor, and a final sync clears it.
    parked = incidents.park(env, token_id, stranding, "Parked recovery")
    assert env.total_stake_across(clone_coldkey, netuid, hotkeys + [successor_pubkey]) <= (
        config.ROUNDING_DUST_TOTAL_RAO
    ), "alpha stayed behind on validator keys after parking"
    assert env.vault_total_stake(token_id) == parked, "the quote prices the parked alpha"

    # Deposits and alignment wait; exits do not.
    env.assert_vault_reverts_with(
        "Parked()", 1_500_000,
        "Parked recovery: a deposit should be refused while parked",
        "wrap(uint256,bytes32,uint256)", netuid, hotkeys[1], 0,
    )
    exit_shares = shares // 4
    quoted_alpha, _ = env.preview_unwrap(token_id, exit_shares)
    delivered_before = env.stake(parking_hotkey, env.wrapper_substrate_coldkey, netuid)
    env.vault_send(
        2_500_000, "Parked recovery: the exit should pay from the parking hotkey",
        "unwrap(uint256,uint256,bytes32,uint256)", token_id, exit_shares, env.wrapper_substrate_coldkey, 1,
    )
    delivered = env.stake(parking_hotkey, env.wrapper_substrate_coldkey, netuid) - delivered_before
    assert delivered >= quoted_alpha - config.ROUNDING_DUST_TOTAL_RAO, (
        f"the parked exit delivered {delivered} alpha against a quote of {quoted_alpha}"
    )
    assert env.awaiting_attestation(token_id), "an exit does not release the position"

    # The attesters replace the vacated name with the successor; the next rebalance releases the position.
    env.set_validators(netuid, [successor_pubkey, hotkeys[1], hotkeys[2]], [5000, 3000, 2000])
    assert not env.awaiting_attestation(token_id), "a newer attestation lifts the hold"
    env.vault_send(
        4_000_000, "Parked recovery: the release rebalance failed", "rebalance(uint256)", netuid,
        label="rebalance [release parked]",
    )

    assert env.stake(parking_hotkey, clone_coldkey, netuid) <= config.ROUNDING_DUST_SLOT_RAO, (
        "the parking hotkey should be empty after the release"
    )
    assert env.stake(lost_pubkey, clone_coldkey, netuid) == 0, "nothing should go back to the stranger's name"
    assert env.stake(successor_pubkey, clone_coldkey, netuid) > 0, "the successor should carry its weight"
    assert env.backing_intact(token_id), "the record follows the new set"
    assert not env.awaiting_attestation(token_id), "and the position is ordinary again"
    env.deposit_and_wrap(
        netuid, hotkeys[1], env.hotkey_ss58s[1],
        config.PER_HOTKEY_TRANSFER_RAO // 10, 1_500_000, "Parked recovery: deposits should resume",
    )
