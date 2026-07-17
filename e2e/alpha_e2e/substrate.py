"""Pure-Python substrate address derivation and wallet-file readers (no chain calls).

The byte layout of the address mapping must match the chain's exactly: these
values feed getStake and transferStake destination lookups.
"""
import hashlib
import json
import os

_SS58_ALPHABET = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def h160_to_account_id(h160: str) -> bytes:
    """blake2b("evm:" + h160_bytes, 32) -- Frontier's HashedAddressMapping. This is
    the coldkey the staking precompile sees for an EVM-owned account."""
    raw = bytes.fromhex(h160.removeprefix("0x"))
    return hashlib.blake2b(b"evm:" + raw, digest_size=32).digest()


def h160_to_substrate_b32(h160: str) -> str:
    return "0x" + h160_to_account_id(h160).hex()


def h160_to_ss58(h160: str, prefix: int = 42) -> str:
    """H160 -> substrate account id -> SS58 (network prefix 42 by default)."""
    account_id = h160_to_account_id(h160)
    if prefix < 64:
        prefix_bytes = bytes([prefix])
    else:
        prefix_bytes = bytes(
            [((prefix & 0xFC) >> 2) | 0x40, (prefix >> 8) | ((prefix & 3) << 6)]
        )
    checksum = hashlib.blake2b(
        b"SS58PRE" + prefix_bytes + account_id, digest_size=64
    ).digest()[:2]
    payload = prefix_bytes + account_id + checksum
    n = int.from_bytes(payload, "big")
    encoded = b""
    while n > 0:
        n, remainder = divmod(n, 58)
        encoded = bytes([_SS58_ALPHABET[remainder]]) + encoded
    for byte in payload:
        if byte == 0:
            encoded = bytes([_SS58_ALPHABET[0]]) + encoded
        else:
            break
    return encoded.decode()


def hotkey_file_path(wallet: str, hotkey: str) -> str:
    return os.path.expanduser(f"~/.bittensor/wallets/{wallet}/hotkeys/{hotkey}")


def _read_hotkey_field(wallet: str, hotkey: str, field: str) -> str:
    with open(hotkey_file_path(wallet, hotkey)) as hotkey_file:
        return json.load(hotkey_file).get(field, "")


def read_hotkey_pubkey(wallet: str, hotkey: str) -> str:
    """publicKey field from the local wallet's hotkey file."""
    return _read_hotkey_field(wallet, hotkey, "publicKey")


def read_hotkey_ss58(wallet: str, hotkey: str) -> str:
    """ss58Address field from the local wallet's hotkey file."""
    return _read_hotkey_field(wallet, hotkey, "ss58Address")
