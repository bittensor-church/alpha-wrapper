"""Scenario: smoke test -- the `env` fixture builds a fresh localnet fixture.

Runs the whole bootstrap (subnets, validators, staking, contract deploy,
funding) and checks the resulting environment is shaped the way every other
scenario assumes.
"""
import pytest

from alpha_e2e import chain, config


@pytest.mark.scenario
def test_environment_builds(env):
    assert len(env.netuids) == 3
    assert len(env.token_ids) == 3
    assert len(env.hotkey_pubkeys) == 9
    assert len(env.hotkey_ss58s) == 9
    assert len(set(env.token_ids)) == 3, "token ids are not distinct"
    for token_id in env.token_ids:
        assert token_id > 0, f"token id {token_id} is not positive"

    # Validators staked at ratio 3:2:1 during bootstrap must be visible on chain.
    for subnet_index, netuid in enumerate(env.netuids):
        for hotkey_pubkey in env.subnet_hotkey_pubkeys(subnet_index):
            stake = env.stake(hotkey_pubkey, config.ALICE_COLDKEY_PUBKEY, netuid)
            assert stake > 0, f"validator {hotkey_pubkey[:18]}... has no stake on netuid {netuid}"

    # The vault deployed with a nonzero min-stake floor, and both funded accounts
    # can pay for transactions.
    assert env.min_stake_tao_floor() > 0
    assert chain.cast_balance_wei(config.DEPLOYER_ADDRESS) > 0
    assert chain.cast_balance_wei(config.WRAPPER_USER_ADDRESS) > 0

    # Deploy-time observability windows captured.
    assert env.observation_block_start > 0
    assert env.registry_block_start >= env.observation_block_start
    assert env.registry_block_end >= env.registry_block_start
