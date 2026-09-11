"""Chainless unit tests for alpha_e2e.substrate address derivation."""
import hashlib

import pytest

from alpha_e2e import config, substrate


def test_h160_to_substrate_b32_matches_blake2_evm_mapping():
    # blake2b("evm:" + h160, 32) -- the address mapping the chain uses.
    got = substrate.h160_to_substrate_b32(config.WRAPPER_USER_ADDRESS)
    assert got.startswith("0x") and len(got) == 66
    h160_bytes = bytes.fromhex(config.WRAPPER_USER_ADDRESS[2:])
    expected = "0x" + hashlib.blake2b(b"evm:" + h160_bytes, digest_size=32).hexdigest()
    assert got == expected


def test_h160_to_ss58_matches_known_mirrors():
    assert substrate.h160_to_ss58(config.WRAPPER_USER_ADDRESS) == config.WRAPPER_USER_SS58
    assert substrate.h160_to_ss58(config.DEPLOYER_ADDRESS) == config.DEPLOYER_SS58


def test_account_id_to_ss58_matches_the_dev_alice_key():
    alice_public_key = bytes.fromhex(config.ALICE_COLDKEY_PUBKEY.removeprefix("0x"))
    assert substrate.account_id_to_ss58(alice_public_key) == config.ALICE_COLDKEY_SS58


@pytest.mark.parametrize("h160", ["0x", "0x1234", config.WRAPPER_USER_ADDRESS + "ab", "0xzz" + "11" * 19])
def test_h160_to_account_id_rejects_anything_but_twenty_bytes(h160):
    with pytest.raises(ValueError, match="40 hex characters"):
        substrate.h160_to_account_id(h160)


@pytest.mark.parametrize("account_id", [b"", bytes(31), bytes(33)])
def test_account_id_to_ss58_rejects_anything_but_thirty_two_bytes(account_id):
    with pytest.raises(ValueError, match="32 bytes"):
        substrate.account_id_to_ss58(account_id)
