"""Chainless unit tests for alpha_e2e.substrate address derivation."""
import hashlib

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
