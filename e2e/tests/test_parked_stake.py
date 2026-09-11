"""A funded hotkey loses its owner; the attesters replace the name and the vault claims the key.

A validator moves its identity to a new hotkey while its stake stays behind. The old
hotkey then has no owner record, so the chain would refuse to move alpha off it, and
the attested name no longer answers to the coldkey that was attested. The vault keeps
the position quotable but refuses partial exits until the attesters publish a set that
names the successor. The next exit then claims the abandoned key for the vault's own
coldkey, rolls the stake onto the successor and pays the holder, with no watcher and
no subnet re-registration involved.
"""
import pytest

from alpha_e2e import config, extrinsics, substrate


@pytest.mark.scenario
def test_holder_exits_after_attesters_replace_the_ownerless_name(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)
    hotkey_pubkey = env.hotkey_pubkeys[0]
    hotkey_ss58 = env.hotkey_ss58s[0]

    env.deposit_and_wrap(
        netuid, hotkey_pubkey, hotkey_ss58,
        config.PER_HOTKEY_TRANSFER_RAO, 1_500_000, "Parked: wrap failed",
    )
    shares = env.vault_shares(token_id)
    assert shares != 0, "no shares minted by the setup wrap"

    # A live subnet emits, so the position only ever grows between reads; the
    # comparisons below are floors rather than equalities for that reason.
    clone_coldkey = env.clone_coldkey(token_id)
    stranded = env.stake(hotkey_pubkey, clone_coldkey, netuid)
    assert stranded > 0, "the setup left no stake on the hotkey about to be stranded"

    successor_ss58 = extrinsics.keypair_ss58("//ParkedSuccessor")
    successor_pubkey = extrinsics.keypair_pubkey("//ParkedSuccessor")
    # The pinned runtime keeps the stake behind, which is the state this scenario needs.
    extrinsics.swap_hotkey_keep_stake(hotkey_ss58, successor_ss58)

    # The identity moved and the owner went with it; the alpha stayed put.
    assert extrinsics.hotkey_owner(hotkey_ss58) == "", "the swap left the hotkey owned"
    assert not extrinsics.hotkey_is_registered(hotkey_ss58, netuid), (
        "the old hotkey should no longer be registered after its identity moved"
    )
    assert env.stake(hotkey_pubkey, clone_coldkey, netuid) >= stranded, (
        "the swap was meant to leave the stake where it was"
    )

    # The record still finds the alpha where it expects it: nothing is missing and no
    # loss goes on file. What the vault refuses is allocating to a name nobody owns.
    assert env.backing_intact(token_id), "the backing check should be satisfied, not tripped"
    assert env.frozen_until(token_id) == 0, "an intact position must not be holding anything shut"
    assert env.vault_total_stake(token_id) > 0, "the vault stopped counting the stranded alpha"

    exit_shares = shares // 2
    env.assert_vault_reverts_with(
        "AttestedHotkeyRetired(bytes32)", 2_500_000,
        "Parked: a partial exit should be refused while the attested name has no owner",
        "unwrap(uint256,uint256,bytes32,uint256)", token_id, exit_shares, env.wrapper_substrate_coldkey, 1,
    )

    # The attesters name the successor in place of the abandoned key.
    env.set_validators(netuid, [successor_pubkey, hotkeys[1], hotkeys[2]], [5000, 3000, 2000])

    # The same exit, now paid: the vault claims the abandoned key, rolls the stake onto the
    # successor and delivers to the holder's own coldkey.
    quoted_alpha, _ = env.preview_unwrap(token_id, exit_shares)
    assert quoted_alpha > config.ROUNDING_DUST_TOTAL_RAO, "the retry must deliver a meaningful payout"
    delivery_keys = hotkeys + [successor_pubkey]
    delivered_before = env.total_stake_across(env.wrapper_substrate_coldkey, netuid, delivery_keys)
    env.vault_send(
        4_000_000, "Parked: the exit should succeed once the attesters replaced the name",
        "unwrap(uint256,uint256,bytes32,uint256)", token_id, exit_shares, env.wrapper_substrate_coldkey, 1,
        label="unwrap [claims the abandoned key]",
    )
    delivered = env.total_stake_across(env.wrapper_substrate_coldkey, netuid, delivery_keys) - delivered_before

    assert delivered >= quoted_alpha - config.ROUNDING_DUST_TOTAL_RAO, (
        f"the retry delivered {delivered} alpha against a quote of {quoted_alpha}"
    )
    assert env.vault_shares(token_id) == shares - exit_shares, "the exit burned the wrong shares"
    assert extrinsics.hotkey_owner(hotkey_ss58) == substrate.h160_to_ss58(env.vault_address), (
        "the vault should have claimed the abandoned key for its own coldkey"
    )
    assert not extrinsics.hotkey_is_registered(hotkey_ss58, netuid), (
        "claiming the key must not register it on the subnet"
    )
    assert env.stake(hotkey_pubkey, clone_coldkey, netuid) <= config.ROUNDING_DUST_SLOT_RAO, (
        "the stake should have left the abandoned key"
    )
    assert env.stake(successor_pubkey, clone_coldkey, netuid) > 0, "the successor should carry the position"
