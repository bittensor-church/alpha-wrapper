"""A slot the pool will not pay for is excluded from a TAO exit instead of blocking it.

A single-validator position is reduced to a leftover the pool refuses to quote. The
plain TAO exit burns its gas at that slot. A second validator then carries the live
backing, and the exit that excludes the leftover pays a partial and then a full exit.
"""
import pytest

from alpha_e2e import checks, config

LIVE_DEPOSIT_RAO = 1_000_000_000


def _shares_leaving_one_rao(env, token_id: int) -> int:
    total = env.vault_total_stake(token_id)
    supply = env.vault_shares(token_id)
    shares = (total - 1) * (supply + 10**9) // (total + 1)
    while env.preview_unwrap(token_id, shares + 1)[0] <= total - 1:
        shares += 1
    while env.preview_unwrap(token_id, shares)[0] > total - 1:
        shares -= 1
    return shares


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
    env.vault_send(
        2_500_000, "Dust exit: the alpha exit leaving one RAO failed",
        "unwrap(uint256,uint256,bytes32,uint256)", token_id, _shares_leaving_one_rao(env, token_id),
        env.wrapper_substrate_coldkey, 0,
    )
    leftover = env.stake(hotkeys[0], clone_coldkey, netuid)
    assert 0 < leftover <= config.ROUNDING_DUST_SLOT_RAO, f"the exit left {leftover} RAO behind, wanted a RAO or two"
    assert env.tao_quote_refused(netuid, leftover), "the pool should refuse to quote the leftover"

    stranded_shares = env.vault_shares(token_id)
    burned = env.vault_send_expect_revert(
        2_500_000, "Dust exit: the plain TAO exit should fail at the refused slot",
        "unwrapForTao(uint256,uint256,uint256)", token_id, stranded_shares, 0,
    )
    assert chain_gas(burned) > config.REVERT_GAS_BOUND, "the refused sale should have burned the forwarded gas"

    env.set_validators(netuid, [hotkeys[1], hotkeys[0]], [9999, 1])
    env.deposit_and_wrap(
        netuid, hotkeys[1], env.hotkey_ss58s[1], LIVE_DEPOSIT_RAO, 1_500_000, "Dust exit: the live deposit failed",
    )
    assert env.stake(hotkeys[0], clone_coldkey, netuid) == leftover, "the leftover should sit beside live backing"
    shares = env.vault_shares(token_id)
    exclude_leftover = 1 << 1

    tao_before = env.user_tao_wei()
    receipt = env.vault_send(
        2_500_000, "Dust exit: the masked partial exit failed",
        "unwrapForTao(uint256,uint256,uint256,uint256)", token_id, shares // 2, 0, exclude_leftover,
        label="unwrapForTao [masked partial]",
    )
    checks.assert_gas_within(receipt, config.UNWRAP_GAS_BOUND, "the masked partial exit burned gas")
    assert env.user_tao_wei() > tao_before, "the partial exit should pay TAO"
    assert env.stake(hotkeys[0], clone_coldkey, netuid) == leftover, "the excluded slot should be untouched"

    receipt = env.vault_send(
        2_500_000, "Dust exit: the masked full exit failed",
        "unwrapForTao(uint256,uint256,uint256,uint256)", token_id, env.vault_shares(token_id), 0, exclude_leftover,
        label="unwrapForTao [masked full]",
    )
    checks.assert_gas_within(receipt, config.UNWRAP_GAS_BOUND, "the masked full exit burned gas")
    assert env.vault_shares(token_id) == 0, "the full exit should burn every share"
    assert env.stake(hotkeys[0], clone_coldkey, netuid) == leftover, "and leave the refused slot where it is"


def chain_gas(receipt: dict) -> int:
    from alpha_e2e import chain

    gas_used = chain.receipt_gas_used(receipt)
    assert gas_used is not None, "could not parse gasUsed"
    return gas_used
