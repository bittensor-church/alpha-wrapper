#!/usr/bin/env python3

"""
Helper subcommands for `localnet-e2e.sh`.

Each subcommand prints its result to stdout; errors go to stderr and exit 1.

Subcommands:
    h160_to_substrate_b32 <0x-h160>
        Map an H160 EVM address to the substrate AccountId (32-byte hex) via
        Frontier's HashedAddressMapping (`blake2b("evm:" + h160)`). This is the
        coldkey the staking precompile sees for an EVM-owned clone.

    h160_to_ss58 <0x-h160>
        Same mapping, but encoded as SS58 with network prefix 42 (Bittensor).

    transfer_stake --chain-endpoint URL --dest-ss58 ... --hotkey-ss58 ...
                   --netuid N --alpha-amount RAW
        Submit `SubtensorModule.transfer_stake` signed by //Alice. Works around
        btcli's SignedExtension mismatch with recent subtensor builds.
"""

import argparse
import hashlib
import sys


SS58_ALPHABET = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def h160_to_account_id(h160_hex: str) -> bytes:
    h160 = bytes.fromhex(h160_hex.removeprefix("0x"))
    return hashlib.blake2b(b"evm:" + h160, digest_size=32).digest()


def h160_to_substrate_b32(h160_hex: str) -> str:
    return "0x" + h160_to_account_id(h160_hex).hex()


def h160_to_ss58(h160_hex: str, prefix: int = 42) -> str:
    account_id = h160_to_account_id(h160_hex)
    if prefix < 64:
        prefix_bytes = bytes([prefix])
    else:
        prefix_bytes = bytes([((prefix & 0xFC) >> 2) | 0x40, (prefix >> 8) | ((prefix & 3) << 6)])
    checksum = hashlib.blake2b(b"SS58PRE" + prefix_bytes + account_id, digest_size=64).digest()[:2]
    payload = prefix_bytes + account_id + checksum

    n = int.from_bytes(payload, "big")
    result = b""
    while n > 0:
        n, rem = divmod(n, 58)
        result = bytes([SS58_ALPHABET[rem]]) + result
    for byte in payload:
        if byte == 0:
            result = bytes([SS58_ALPHABET[0]]) + result
        else:
            break
    return result.decode()


def transfer_stake(
    chain_endpoint: str,
    dest_ss58: str,
    hotkey_ss58: str,
    netuid: int,
    alpha_amount: int,
) -> None:
    from substrateinterface import Keypair, SubstrateInterface

    sub = SubstrateInterface(url=chain_endpoint)
    alice = Keypair.create_from_uri("//Alice")
    call = sub.compose_call(
        call_module="SubtensorModule",
        call_function="transfer_stake",
        call_params={
            "destination_coldkey": dest_ss58,
            "hotkey": hotkey_ss58,
            "origin_netuid": netuid,
            "destination_netuid": netuid,
            "alpha_amount": alpha_amount,
        },
    )
    extrinsic = sub.create_signed_extrinsic(call=call, keypair=alice)
    receipt = sub.submit_extrinsic(extrinsic, wait_for_inclusion=True)
    if not receipt.is_success:
        print(f"FAIL: {receipt.error_message}", file=sys.stderr)
        sys.exit(1)
    print(f"ok block={receipt.block_hash}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("h160_to_substrate_b32")
    p.add_argument("h160")

    p = sub.add_parser("h160_to_ss58")
    p.add_argument("h160")

    p = sub.add_parser("transfer_stake")
    p.add_argument("--chain-endpoint", required=True)
    p.add_argument("--dest-ss58", required=True)
    p.add_argument("--hotkey-ss58", required=True)
    p.add_argument("--netuid", required=True, type=int)
    p.add_argument("--alpha-amount", required=True, type=int)

    args = parser.parse_args()

    if args.cmd == "h160_to_substrate_b32":
        print(h160_to_substrate_b32(args.h160))
    elif args.cmd == "h160_to_ss58":
        print(h160_to_ss58(args.h160))
    elif args.cmd == "transfer_stake":
        transfer_stake(
            chain_endpoint=args.chain_endpoint,
            dest_ss58=args.dest_ss58,
            hotkey_ss58=args.hotkey_ss58,
            netuid=args.netuid,
            alpha_amount=args.alpha_amount,
        )


if __name__ == "__main__":
    main()
