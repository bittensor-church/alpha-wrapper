"""A slot the pool will not pay for is excluded from a TAO exit instead of blocking it.

A single-validator position is reduced to a leftover the pool refuses to quote. The
plain TAO exit burns its gas at that slot. A second validator then carries the live
backing, and the exit that excludes the leftover pays a partial and then a full exit.
"""
import pytest

from alpha_e2e import checks, config

LIVE_DEPOSIT_RAO = 1_000_000_000
# Emissions between reads can lift the leftover back above what the pool refuses.
LEFTOVER_ATTEMPTS = 5


def _largest_burn_paying_below(total: int, supply: int) -> int:
    """The most shares whose alpha payout stays below `total`, from one state snapshot; the
    vault pays `shares * (total + 1) // (supply + 1e9)`."""
    return min(supply, (total * (supply + 10**9) - 1) // (total + 1))


def _reduce_to_a_refused_leftover(env, netuid: int, token_id: int, hotkey: str, clone_coldkey: str) -> int:
    for _ in range(LEFTOVER_ATTEMPTS):
        total = env.vault_total_stake(token_id)
        shares = _largest_burn_paying_below(total, env.vault_shares(token_id))
        assert env.preview_unwrap(token_id, shares)[0] < env.vault_total_stake(token_id), "the burn should leave alpha"
        env.vault_send(
            2_500_000, "Dust exit: the alpha exit leaving one RAO failed",
            "unwrap(uint256,uint256,bytes32,uint256)", token_id, shares, env.wrapper_substrate_coldkey, 0,
        )
        leftover = env.stake(hotkey, clone_coldkey, netuid)
        assert leftover > 0, "the exit emptied the slot instead of leaving a leftover"
        if env.tao_quote(netuid, leftover) is None:
            return leftover
    pytest.fail(f"the pool kept quoting the leftover after {LEFTOVER_ATTEMPTS} attempts")


@pytest.mark.scenario
def test_tao_exit_sells_around_a_slot_the_pool_refuses(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)
    clone_coldkey = env.clone_coldkey(token_id)

    env.set_validators(netuid, [hotkeys[0]], [10000])
    env.deposit_and_wrap(
        netuid, hotkeys[0], env.hotkey_ss58s[0],
        config.PER_HOTKEY_TRANSFER_RAO, 1_500_000, "Dust exit: wrap failed",
    )
    leftover = _reduce_to_a_refused_leftover(env, netuid, token_id, hotkeys[0], clone_coldkey)

    stranded_shares = env.vault_shares(token_id)
    burned = env.vault_send_expect_revert(
        2_500_000, "Dust exit: the plain TAO exit should fail at the refused slot",
        "unwrapForTao(uint256,uint256,uint256)", token_id, stranded_shares, 0,
    )
    checks.assert_gas_exceeds(burned, config.REVERT_GAS_BOUND, "the refused sale should have burned its gas")

    env.set_validators(netuid, [hotkeys[1], hotkeys[0]], [9999, 1])
    env.deposit_and_wrap(
        netuid, hotkeys[1], env.hotkey_ss58s[1], LIVE_DEPOSIT_RAO, 1_500_000, "Dust exit: the live deposit failed",
    )
    assert env.stake(hotkeys[0], clone_coldkey, netuid) >= leftover, "the leftover should sit beside live backing"
    exclude_leftover = 1 << 1

    partial_shares = env.vault_shares(token_id) // 2
    quoted_alpha, _ = env.preview_unwrap(token_id, partial_shares)
    live_before = env.stake(hotkeys[1], clone_coldkey, netuid)
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
    assert live_before - env.stake(hotkeys[1], clone_coldkey, netuid) == sold, "the sale came from the live slot"
    assert env.stake(hotkeys[0], clone_coldkey, netuid) >= leftover, "the excluded slot should be untouched"

    live_before = env.stake(hotkeys[1], clone_coldkey, netuid)
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
    assert env.stake(hotkeys[1], clone_coldkey, netuid) <= config.ROUNDING_DUST_SLOT_RAO, "and drain the live slot"
    assert env.stake(hotkeys[0], clone_coldkey, netuid) >= leftover, "while the refused slot stays where it is"
