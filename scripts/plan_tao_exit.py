#!/usr/bin/env python3

"""Plan a TAO exit: quote every recorded slot, build the exclusion mask, dry-run the call.

A slot the pool will not pay for makes the plain `unwrapForTao` fail and burn its
gas, while the same quote costs nothing through `eth_call`. This reads each slot's
balance from the lens, at the key the vault would sell it from, asks the pool about
it, excludes the ones the pool refuses, and dry-runs the masked exit.
"""

import argparse
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from typing import Optional

from web3.exceptions import ContractLogicError, Web3RPCError

from common import (
    add_block_argument,
    extract_error_name,
    get_web3_connection,
    load_abi,
    lookup_token_id,
    resolve_block,
)

ALPHA_PRECOMPILE = "0x0000000000000000000000000000000000000808"
# Frontier reports a call the EVM refused (as opposed to one that reverted) with this message.
EVM_ERROR = "evm error"
ALPHA_ABI = [{
    "name": "simSwapAlphaForTao", "type": "function", "stateMutability": "view",
    "inputs": [{"name": "netuid", "type": "uint16"}, {"name": "alpha", "type": "uint64"}],
    "outputs": [{"name": "", "type": "uint256"}],
}]


@dataclass
class ExitPlan:
    """The mask to pass to the exit, one verdict line per slot, and the reason the
    vault would refuse the exit outright, if it would."""

    mask: int
    verdicts: list[str]
    refusal: Optional[str]


def plan_exit(
    keys: Sequence[bytes],
    balances: Sequence[int],
    short: Sequence[bool],
    quote_of: Callable[[int], Optional[int]],
) -> ExitPlan:
    """Decide each slot: a slot the vault reads as short blocks the exit, an empty one
    sells nothing, and the rest are excluded when the pool will not pay for them."""
    mask = 0
    verdicts: list[str] = []
    for index, (key, balance, is_short) in enumerate(zip(keys, balances, short)):
        name = "0x" + key.hex()
        if is_short:
            return ExitPlan(mask, verdicts, (
                f"slot {index}: {name} does not cover what the record expects; "
                "the vault would refuse the exit, recover first"
            ))
        if balance == 0:
            verdicts.append(f"slot {index}: {name} is empty")
            continue
        answer = quote_of(balance)
        verdict = "sellable"
        if not answer:
            mask |= 1 << index
            verdict = "EXCLUDED: the pool refused the quote" if answer is None else "EXCLUDED: quotes zero"
        verdicts.append(f"slot {index}: {name} balance {balance} RAO quote {answer} {verdict}")
    return ExitPlan(mask, verdicts, None)


def is_execution_failure(error: Exception) -> bool:
    """An answer from the EVM refusing the call, as opposed to a transport or node problem."""
    if isinstance(error, ContractLogicError):
        return True
    if not isinstance(error, Web3RPCError):
        return False
    rpc_error = (error.rpc_response or {}).get("error") or {}
    return EVM_ERROR in str(rpc_error.get("message", "")).lower()


def quote(alpha_precompile, netuid: int, balance: int, block: int | str = "latest") -> Optional[int]:
    """The pool's TAO quote, or None when the pool refuses; a transport failure propagates."""
    try:
        return alpha_precompile.functions.simSwapAlphaForTao(netuid, balance).call(
            block_identifier=block,
        )
    except (ContractLogicError, Web3RPCError) as error:
        if is_execution_failure(error):
            return None
        raise


def dry_run(exit_call, holder: str, block: int | str, abi: list) -> Optional[str]:
    """The error the exit would revert with at `block`, or None when it would go through."""
    try:
        exit_call.call({"from": holder}, block_identifier=block)
        return None
    except ContractLogicError as error:
        return extract_error_name(error, abi)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault-address", required=True, help="AlphaVault contract address")
    parser.add_argument("--lens-address", required=True,
                        help="AlphaVaultLens contract address, from the same trusted source as the vault")
    parser.add_argument("--rpc-url", required=True, help="HTTP RPC URL of the Subtensor EVM endpoint")
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--netuid", type=int, help="Subnet id; resolves the live token id")
    target.add_argument("--token-id", type=int, help="Token id, for a position on a retired generation")
    parser.add_argument("--holder", required=True, help="EVM address whose shares would be burned")
    parser.add_argument("--shares", required=True, type=int, help="Shares to burn, raw ERC-1155 units")
    parser.add_argument("--min-tao-out", type=int, default=0, help="Minimum TAO out in wei for the dry run")
    add_block_argument(parser)
    args = parser.parse_args()

    w3 = get_web3_connection(args.rpc_url)
    # One block for the whole plan, so the mask matches the balances it was built from.
    block = resolve_block(w3, args.block)
    print(f"planning at block {block}", file=sys.stderr)
    vault = w3.eth.contract(address=w3.to_checksum_address(args.vault_address), abi=load_abi("AlphaVault"))
    lens = w3.eth.contract(address=w3.to_checksum_address(args.lens_address), abi=load_abi("AlphaVaultLens"))
    # A plan built from a mismatched pair would mask one vault's slots on another's backing.
    # This catches the wrong lens, not a dishonest one: the address still has to be trusted.
    lens_vault = lens.functions.vault().call(block_identifier=block)
    if lens_vault != w3.to_checksum_address(args.vault_address):
        sys.exit(f"lens {args.lens_address} reads vault {lens_vault}, not {args.vault_address}")

    token_id = (
        args.token_id if args.token_id is not None
        else lookup_token_id(vault, args.netuid, block)
    )
    netuid = token_id & 0xFFFF
    clone = vault.functions.subnetClone(token_id).call(block_identifier=block)
    if int(clone, 16) == 0:
        sys.exit(f"token {token_id} has no position")

    alpha = w3.eth.contract(address=ALPHA_PRECOMPILE, abi=ALPHA_ABI)
    keys, balances, short, _total = lens.functions.resolvedBacking(token_id).call(block_identifier=block)
    plan = plan_exit(keys, balances, short, lambda balance: quote(alpha, netuid, balance, block))
    for verdict in plan.verdicts:
        print(verdict)
    if plan.refusal is not None:
        sys.exit(plan.refusal)
    print(f"excludedSlots mask: {plan.mask}")

    masked_exit = vault.get_function_by_signature("unwrapForTao(uint256,uint256,uint256,uint256)")
    exit_call = masked_exit(token_id, args.shares, args.min_tao_out, plan.mask)
    holder = w3.to_checksum_address(args.holder)
    # The plan is pinned to one block; the exit itself would run against the head, so
    # both answers matter and a disagreement is the state moving underneath it.
    outcomes = {
        f"block {block}": dry_run(exit_call, holder, block, vault.abi),
        "latest": dry_run(exit_call, holder, "latest", vault.abi),
    }
    call_text = f"unwrapForTao({token_id}, {args.shares}, {args.min_tao_out}, {plan.mask})"
    for label, revert in outcomes.items():
        print(f"dry run {call_text} at {label}: " + (f"reverted: {revert}" if revert else "ok"))
    if any(outcomes.values()):
        sys.exit("the exit would revert")


if __name__ == "__main__":
    main()
