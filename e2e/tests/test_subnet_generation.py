"""A token follows the chain's registration counter, not the registration block.

Chain migrations have rewritten live subnets' registration blocks. A position must
survive that untouched, while a subnet dissolved and registered again must get a new
token with the old one still redeemable.
"""
import pytest

from alpha_e2e import bootstrap, config, extrinsics

IMMUNITY_EXTENSION_BLOCKS = 13 * 7200


@pytest.mark.scenario
def test_token_follows_the_registration_counter_not_the_block(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)

    env.deposit_and_wrap(
        netuid, hotkeys[0], env.hotkey_ss58s[0],
        config.PER_HOTKEY_TRANSFER_RAO, 1_500_000, "Generation: wrap failed",
    )
    shares = env.vault_shares(token_id)
    assert shares != 0, "no shares minted by the setup wrap"
    registrations = env.registration_counter(netuid)
    assert token_id == netuid | (registrations << 16), "the token id carries the registration counter"

    block_before = extrinsics.network_registration_block(netuid)
    extrinsics.set_network_registration_block(netuid, block_before + IMMUNITY_EXTENSION_BLOCKS)

    assert env.current_token_id(netuid) == token_id, "a rewritten registration block changes nothing"
    assert env.backing_intact(token_id), "the record is untouched"
    exit_shares = shares // 4
    quoted_alpha, _ = env.preview_unwrap(token_id, exit_shares)
    delivered_before = env.total_stake_across(env.wrapper_substrate_coldkey, netuid, hotkeys)
    env.vault_send(
        2_500_000, "Generation: the exit should pay in alpha after the rewrite",
        "unwrap(uint256,uint256,bytes32,uint256)", token_id, exit_shares, env.wrapper_substrate_coldkey, 1,
        label="unwrap [after block rewrite]",
    )
    delivered = env.total_stake_across(env.wrapper_substrate_coldkey, netuid, hotkeys) - delivered_before
    assert delivered >= quoted_alpha - config.ROUNDING_DUST_TOTAL_RAO, (
        f"the exit delivered {delivered} alpha against a quote of {quoted_alpha}"
    )
    env.deposit_and_wrap(
        netuid, hotkeys[1], env.hotkey_ss58s[1],
        config.PER_HOTKEY_TRANSFER_RAO // 10, 1_500_000, "Generation: deposits should land on the same token",
    )
    assert env.vault_shares(token_id) > shares - exit_shares, "the deposit joined the existing position"

    extrinsics.dissolve_network(netuid)
    env.wait_for_dissolution_cleanup(netuid)
    assert bootstrap.create_subnet() == netuid, "the chain hands the freed netuid back"

    assert env.registration_counter(netuid) == registrations + 1, "the counter stepped with the registration"
    assert env.current_token_id(netuid) == netuid | ((registrations + 1) << 16), "so the new subnet has a new token"
    alpha_quote, tao_quote = env.preview_unwrap(token_id, env.vault_shares(token_id))
    assert alpha_quote == 0 and tao_quote > 0, "while the old token redeems its dissolution refund"
