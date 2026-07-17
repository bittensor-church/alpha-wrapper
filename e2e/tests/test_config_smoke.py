"""Chainless smoke test: the dev constants keep their well-known values."""
from alpha_e2e import config


def test_core_constants_present_and_typed():
    assert config.RPC_URL == "http://127.0.0.1:9944"
    assert config.CHAIN_ENDPOINT == "ws://127.0.0.1:9944"
    assert config.CHAIN_ID == 42
    assert config.DEPLOYER_ADDRESS.startswith("0x") and len(config.DEPLOYER_ADDRESS) == 42
    assert config.WRAPPER_USER_PRIVATE_KEY.startswith("0x")
    assert len(config.WRAPPER_USER_PRIVATE_KEY) == 66
    assert config.VALIDATOR_STAKE_TAO == (600, 400, 200)
    assert config.HOTKEY_SUFFIXES == ("a", "b", "c")
    assert config.VALIDATORS_PER_SUBNET == 3
    assert config.PER_HOTKEY_TRANSFER_RAO == 100 * 10**9 // 3
    assert config.ROUNDING_DUST_TOTAL_RAO == 6 * config.ROUNDING_DUST_SLOT_RAO
    assert config.REVERT_GAS_BOUND < config.WRAP_GAS_BOUND < config.UNWRAP_GAS_BOUND
