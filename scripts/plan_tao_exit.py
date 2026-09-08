#!/usr/bin/env python3

"""Plan a TAO exit: quote every recorded slot, build the exclusion mask, dry-run the call.

A slot the pool will not pay for makes the plain `unwrapForTao` fail and burn its
gas, while the same quote costs nothing through `eth_call`. This asks the pool about
each slot, excludes the ones it refuses, and dry-runs the masked exit.
"""

import argparse
import hashlib
import sys

from web3.exceptions import ContractLogicError

from common import extract_error_name, get_web3_connection, load_abi, lookup_token_id

STAKING_PRECOMPILE = "0x0000000000000000000000000000000000000805"
ALPHA_PRECOMPILE = "0x0000000000000000000000000000000000000808"
STAKING_ABI = [{
    "name": "getStake", "type": "function", "stateMutability": "view",
    "inputs": [
        {"name": "hotkey", "type": "bytes32"},
        {"name": "coldkey", "type": "bytes32"},
        {"name": "netuid", "type": "uint256"},
    ],
    "outputs": [{"name": "", "type": "uint256"}],
}]
ALPHA_ABI = [{
    "name": "simSwapAlphaForTao", "type": "function", "stateMutability": "view",
    "inputs": [{"name": "netuid", "type": "uint16"}, {"name": "alpha", "type": "uint64"}],
    "outputs": [{"name": "", "type": "uint256"}],
}]


def coldkey_of(address: str) -> bytes:
    """The coldkey the chain derives for an EVM account."""
    return hashlib.blake2b(b"evm:" + bytes.fromhex(address[2:]), digest_size=32).digest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault-address", required=True, help="AlphaVault contract address")
    parser.add_argument("--rpc-url", required=True, help="HTTP RPC URL of the Subtensor EVM endpoint")
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--netuid", type=int, help="Subnet id; resolves the live token id")
    target.add_argument("--token-id", type=int, help="Token id, for a position on a retired generation")
    parser.add_argument("--holder", required=True, help="EVM address whose shares would be burned")
    parser.add_argument("--shares", required=True, type=int, help="Shares to burn, raw ERC-1155 units")
    parser.add_argument("--min-tao-out", type=int, default=0, help="Minimum TAO out in wei for the dry run")
    args = parser.parse_args()

    w3 = get_web3_connection(args.rpc_url)
    vault = w3.eth.contract(address=w3.to_checksum_address(args.vault_address), abi=load_abi("AlphaVault"))
    token_id = args.token_id if args.token_id is not None else lookup_token_id(vault, args.netuid)
    netuid = token_id & 0xFFFF
    clone = vault.functions.subnetClone(token_id).call()
    if int(clone, 16) == 0:
        sys.exit(f"token {token_id} has no position")
    coldkey = coldkey_of(clone)
    staking = w3.eth.contract(address=STAKING_PRECOMPILE, abi=STAKING_ABI)
    alpha = w3.eth.contract(address=ALPHA_PRECOMPILE, abi=ALPHA_ABI)

    mask = 0
    for index, (_logical, active, _tracked) in enumerate(vault.functions.recordedSlots(token_id).call()):
        balance = staking.functions.getStake(active, coldkey, netuid).call()
        if balance == 0:
            print(f"slot {index}: 0x{active.hex()} holds nothing on the recorded key; a renamed slot sells "
                  "from its successor, which the dry run covers")
            continue
        try:
            quote = alpha.functions.simSwapAlphaForTao(netuid, balance).call()
        except Exception:  # noqa: BLE001 - any failure means the pool refused the quote
            quote = None
        verdict = "sellable"
        if not quote:
            mask |= 1 << index
            verdict = "EXCLUDED: the pool refused the quote" if quote is None else "EXCLUDED: quotes zero"
        print(f"slot {index}: 0x{active.hex()} balance {balance} RAO quote {quote} {verdict}")
    print(f"excludedSlots mask: {mask}")

    masked_exit = vault.get_function_by_signature("unwrapForTao(uint256,uint256,uint256,uint256)")
    try:
        masked_exit(token_id, args.shares, args.min_tao_out, mask).call({"from": w3.to_checksum_address(args.holder)})
    except ContractLogicError as error:
        sys.exit(f"dry run reverted: {extract_error_name(error, vault.abi)}")
    print(f"dry run ok: unwrapForTao({token_id}, {args.shares}, {args.min_tao_out}, {mask})")


if __name__ == "__main__":
    main()
