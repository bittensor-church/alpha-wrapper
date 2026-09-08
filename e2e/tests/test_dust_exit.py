"""A slot the pool will not pay for is excluded from a TAO exit instead of blocking it.

On a pool deepened to where most subnets trade, a single-validator position is reduced
to a leftover the pool refuses to quote, and the plain TAO exit burns its gas at that
slot. Live backing, sized from what the pool sold Alice, then lands on a second attested
hotkey that no emissions touch, and the exit that excludes the leftover pays a partial
and then a full exit for exactly what that backing was worth.
"""
import pytest

from alpha_e2e import checks, config, extrinsics
from alpha_e2e.environment import largest_burn_leaving_alpha

# The localnet prices alpha above one TAO, where the pool refuses no sale; most subnets trade
# far below that. Deepening the pool's alpha side by this much puts a few RAO of alpha under
# one RAO of TAO.
POOL_DEEPENING = 100
# An owned hotkey with no subnet membership earns nothing, so the backing it holds is exact.
LIVE_HOTKEY_URI = "//DustExitLive"
LIVE_FUNDING_TAO_RAO = 3_000_000_000
# The partial sale, half the live deposit, must clear the chain's stake floor with room.
FLOOR_MARGIN = 10
# The exit leaves one RAO plus whatever chain rounding adds; the pool must refuse all of it.
REFUSED_LEFTOVER_RAO = 1 + config.ROUNDING_DUST_SLOT_RAO


def _leave_a_refused_leftover(env, netuid: int, token_id: int, hotkey: str, clone_coldkey: str) -> int:
    total = env.vault_total_stake(token_id)
    shares = largest_burn_leaving_alpha(total, env.vault_shares(token_id))
    assert env.preview_unwrap(token_id, shares)[0] < env.vault_total_stake(token_id), "the burn should leave alpha"
    env.vault_send(
        2_500_000, "Dust exit: the alpha exit leaving a leftover failed",
        "unwrap(uint256,uint256,bytes32,uint256)", token_id, shares, env.wrapper_substrate_coldkey, 0,
    )
    leftover = env.stake(hotkey, clone_coldkey, netuid)
    assert 0 < leftover <= REFUSED_LEFTOVER_RAO, f"the exit left {leftover} RAO behind"
    assert env.tao_quote(netuid, leftover) is None, "the pool should refuse to quote the leftover"
    return leftover


@pytest.mark.scenario
def test_tao_exit_sells_around_a_slot_the_pool_refuses(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)
    clone_coldkey = env.clone_coldkey(token_id)

    deepened_alpha = env.alpha_in_pool(netuid) * POOL_DEEPENING
    extrinsics.set_subnet_alpha_in(netuid, deepened_alpha)
    assert env.alpha_in_pool(netuid) >= deepened_alpha, "the pool's alpha side should read back deepened"
    assert env.tao_quote(netuid, REFUSED_LEFTOVER_RAO) is None, "a few RAO of alpha should now be worth no TAO"

    live_pubkey = extrinsics.keypair_pubkey(LIVE_HOTKEY_URI)
    live_ss58 = extrinsics.keypair_ss58(LIVE_HOTKEY_URI)
    extrinsics.associate_hotkey(live_ss58)
    extrinsics.add_stake(live_ss58, netuid, LIVE_FUNDING_TAO_RAO)
    assert not extrinsics.hotkey_is_registered(live_ss58, netuid), "the live hotkey must stay outside the metagraph"
    # Sized from the alpha the pool actually sold, with half left behind for the chain's rounding.
    live_deposit = env.stake(live_pubkey, config.ALICE_COLDKEY_PUBKEY, netuid) // 2
    assert env.alpha_value_tao(netuid, live_deposit // 2) >= FLOOR_MARGIN * env.chain_min_stake_tao(), (
        f"a live deposit of {live_deposit} RAO leaves the partial sale too close to the floor"
    )

    env.set_validators(netuid, [hotkeys[0]], [10000])
    env.deposit_and_wrap(
        netuid, hotkeys[0], env.hotkey_ss58s[0],
        config.PER_HOTKEY_TRANSFER_RAO, 1_500_000, "Dust exit: wrap failed",
    )
    leftover = _leave_a_refused_leftover(env, netuid, token_id, hotkeys[0], clone_coldkey)

    stranded_shares = env.vault_shares(token_id)
    assert stranded_shares > 0, "the shaving burn should leave shares behind"
    burned = env.vault_send_expect_revert(
        2_500_000, "Dust exit: the plain TAO exit should fail at the refused slot",
        "unwrapForTao(uint256,uint256,uint256)", token_id, stranded_shares, 0,
    )
    checks.assert_gas_exceeds(burned, config.REVERT_GAS_BOUND, "the refused sale should have burned its gas")

    env.set_validators(netuid, [live_pubkey, hotkeys[0]], [9999, 1])
    env.deposit_and_wrap(
        netuid, live_pubkey, live_ss58, live_deposit, 1_500_000, "Dust exit: the live deposit failed",
    )
    assert env.stake(hotkeys[0], clone_coldkey, netuid) == leftover, "the leftover should sit beside live backing"
    assert env.stake(live_pubkey, clone_coldkey, netuid) >= live_deposit - config.ROUNDING_DUST_SLOT_RAO, (
        "the live deposit should have landed"
    )
    exclude_leftover = 1 << env.recorded_slot_index(token_id, hotkeys[0])

    partial_shares = env.vault_shares(token_id) // 2
    quoted_alpha, _ = env.preview_unwrap(token_id, partial_shares)
    assert env.tao_quote(netuid, leftover) is None, "the pool should still refuse the excluded slot"
    live_before = env.stake(live_pubkey, clone_coldkey, netuid)
    tao_before = env.user_tao_wei()
    receipt = env.vault_send(
        2_500_000, "Dust exit: the masked partial exit failed",
        "unwrapForTao(uint256,uint256,uint256,uint256)", token_id, partial_shares, 0, exclude_leftover,
        label="unwrapForTao [masked partial]",
    )
    checks.assert_gas_within(receipt, config.UNWRAP_GAS_BOUND, "the masked partial exit burned gas")
    sold = checks.assert_payout_near_quote(
        tao_before, env.user_tao_wei(), receipt, netuid, quoted_alpha, "masked partial payout off the quote",
    )
    live_delta = live_before - env.stake(live_pubkey, clone_coldkey, netuid)
    assert abs(live_delta - sold) <= config.ROUNDING_DUST_SLOT_RAO, f"the live slot gave {live_delta}, sold {sold}"
    assert env.stake(hotkeys[0], clone_coldkey, netuid) == leftover, "the excluded slot should be untouched"

    assert env.tao_quote(netuid, leftover) is None, "the pool should still refuse the excluded slot"
    live_before = env.stake(live_pubkey, clone_coldkey, netuid)
    tao_before = env.user_tao_wei()
    receipt = env.vault_send(
        2_500_000, "Dust exit: the masked full exit failed",
        "unwrapForTao(uint256,uint256,uint256,uint256)", token_id, env.vault_shares(token_id), 0, exclude_leftover,
        label="unwrapForTao [masked full]",
    )
    checks.assert_gas_within(receipt, config.UNWRAP_GAS_BOUND, "the masked full exit burned gas")
    checks.assert_payout_near_quote(
        tao_before, env.user_tao_wei(), receipt, netuid, live_before, "masked full payout off the live slot",
    )
    assert env.vault_shares(token_id) == 0, "the full exit should burn every share"
    assert env.stake(live_pubkey, clone_coldkey, netuid) <= config.ROUNDING_DUST_SLOT_RAO, "and drain the live slot"
    assert env.stake(hotkeys[0], clone_coldkey, netuid) == leftover, "while the refused slot stays where it is"
