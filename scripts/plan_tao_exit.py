#!/usr/bin/env python3

"""Plan a TAO exit: quote every recorded slot, build the exclusion mask, dry-run the call.

A slot the pool will not pay for makes the plain `unwrapForTao` fail and burn its
gas, while the same quote costs nothing through `eth_call`. This resolves each slot to
the key the vault would sell from, asks the pool about it, excludes the ones it refuses,
and dry-runs the masked exit.
"""

import argparse
import hashlib
import sys
from typing import Callable, Optional

from web3.exceptions import ContractLogicError, Web3RPCError

from common import extract_error_name, get_web3_connection, load_abi, lookup_token_id

STAKING_PRECOMPILE = "0x0000000000000000000000000000000000000805"
ALPHA_PRECOMPILE = "0x0000000000000000000000000000000000000808"
# The vault forgives this much accounting dust when it decides a key still covers its slot.
TRACKED_SLACK_RAO = 1_000
# Frontier reports a call the EVM refused (as opposed to one that reverted) with this message.
EVM_ERROR = "evm error"
STAKING_ABI = [
    {
        "name": "getStake", "type": "function", "stateMutability": "view",
        "inputs": [
            {"name": "hotkey", "type": "bytes32"},
            {"name": "coldkey", "type": "bytes32"},
            {"name": "netuid", "type": "uint256"},
        ],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "name": "getHotkeySuccessor", "type": "function", "stateMutability": "view",
        "inputs": [{"name": "hotkey", "type": "bytes32"}, {"name": "netuid", "type": "uint16"}],
        "outputs": [{"name": "exists", "type": "bool"}, {"name": "successor", "type": "bytes32"}],
    },
]
ALPHA_ABI = [{
    "name": "simSwapAlphaForTao", "type": "function", "stateMutability": "view",
    "inputs": [{"name": "netuid", "type": "uint16"}, {"name": "alpha", "type": "uint64"}],
    "outputs": [{"name": "", "type": "uint256"}],
}]


class Unresolved(Exception):
    """The vault could not locate a slot's backing either; recover before exiting."""


def coldkey_of(address: str) -> bytes:
    """The coldkey the chain derives for an EVM account."""
    return hashlib.blake2b(b"evm:" + bytes.fromhex(address[2:]), digest_size=32).digest()


def resolve_slot(
    active: bytes, tracked: int, balance_of: Callable[[bytes], int], successor_of: Callable[[bytes], Optional[bytes]],
) -> tuple[bytes, int]:
    """The key and balance the vault sells this slot from: the recorded key while it covers the
    slot, otherwise its one-hop successor when that one does."""
    balance = balance_of(active)
    if balance + TRACKED_SLACK_RAO >= tracked:
        return active, balance
    successor = successor_of(active)
    if successor is not None:
        successor_balance = balance_of(successor)
        if successor_balance + TRACKED_SLACK_RAO >= tracked:
            return successor, successor_balance
    raise Unresolved(f"0x{active.hex()} holds {balance} RAO against {tracked} expected and no successor covers it")


def is_execution_failure(error: Exception) -> bool:
    """An answer from the EVM refusing the call, as opposed to a transport or node problem."""
    if isinstance(error, ContractLogicError):
        return True
    if not isinstance(error, Web3RPCError):
        return False
    rpc_error = (error.rpc_response or {}).get("error") or {}
    return EVM_ERROR in str(rpc_error.get("message", "")).lower()


def quote(alpha_precompile, netuid: int, balance: int) -> Optional[int]:
    """The pool's TAO quote, or None when the pool refuses; a transport failure propagates."""
    try:
        return alpha_precompile.functions.simSwapAlphaForTao(netuid, balance).call()
    except (ContractLogicError, Web3RPCError) as error:
        if is_execution_failure(error):
            return None
        raise


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

    def balance_of(hotkey: bytes) -> int:
        return staking.functions.getStake(hotkey, coldkey, netuid).call()

    def successor_of(hotkey: bytes) -> Optional[bytes]:
        exists, successor = staking.functions.getHotkeySuccessor(hotkey, netuid).call()
        return successor if exists else None

    mask = 0
    for index, (_logical, active, tracked) in enumerate(vault.functions.recordedSlots(token_id).call()):
        try:
            key, balance = resolve_slot(active, tracked, balance_of, successor_of)
        except Unresolved as error:
            sys.exit(f"slot {index} is unresolved ({error}); the vault would refuse the exit, recover first")
        if balance == 0:
            print(f"slot {index}: 0x{key.hex()} is empty")
            continue
        answer = quote(alpha, netuid, balance)
        verdict = "sellable"
        if not answer:
            mask |= 1 << index
            verdict = "EXCLUDED: the pool refused the quote" if answer is None else "EXCLUDED: quotes zero"
        print(f"slot {index}: 0x{key.hex()} balance {balance} RAO quote {answer} {verdict}")
    print(f"excludedSlots mask: {mask}")

    masked_exit = vault.get_function_by_signature("unwrapForTao(uint256,uint256,uint256,uint256)")
    try:
        masked_exit(token_id, args.shares, args.min_tao_out, mask).call({"from": w3.to_checksum_address(args.holder)})
    except ContractLogicError as error:
        sys.exit(f"dry run reverted: {extract_error_name(error, vault.abi)}")
    print(f"dry run ok: unwrapForTao({token_id}, {args.shares}, {args.min_tao_out}, {mask})")


if __name__ == "__main__":
    main()
