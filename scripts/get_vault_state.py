#!/usr/bin/env python3

"""Print a one-row CSV summary of an AlphaVault token's on-chain state."""

import argparse
import sys

from eth_utils import function_signature_to_4byte_selector
from web3.contract import Contract
from web3.exceptions import ContractLogicError

from common import get_web3_connection, load_abi, make_csv_writer


def _extract_error_name(exc: Exception, abi: list[dict]) -> str:
    """Match the exception's revert-data 4-byte selector against custom errors in the ABI.

    Falls back to the raw selector (e.g. ``0xf2b8b360``) if the selector is not
    declared in the ABI, and to the exception class name if no selector is present.
    """
    data = getattr(exc, "data", None)
    if isinstance(data, dict):
        data = data.get("data")  # web3.py sometimes wraps as {"data": "0x..."}
    if not isinstance(data, str) or not data.startswith("0x") or len(data) < 10:
        return type(exc).__name__
    selector = data[:10].lower()
    for item in abi:
        if item.get("type") != "error":
            continue
        sig = f"{item['name']}({','.join(i['type'] for i in item['inputs'])})"
        if "0x" + function_signature_to_4byte_selector(sig).hex() == selector:
            return item["name"]
    return selector


def _validator_columns(registry: Contract | None, netuid: int) -> dict:
    """Three (hotkey, weight) slots + count; empty for unused slots or no registry."""
    cols: dict = {"validators_count": ""}
    for i in range(3):
        cols[f"validator_{i+1}_hotkey"] = ""
        cols[f"validator_{i+1}_weight"] = ""
    if registry is None:
        return cols
    hotkeys, weights, count = registry.functions.getValidators(netuid).call()
    cols["validators_count"] = count
    for i in range(min(count, 3)):
        cols[f"validator_{i+1}_hotkey"] = "0x" + hotkeys[i].hex()
        cols[f"validator_{i+1}_weight"] = weights[i]
    return cols


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault-address", required=True, help="AlphaVault contract address")
    parser.add_argument("--registry-address", help="Optional ValidatorRegistry address (enables validator columns)")
    parser.add_argument("--rpc-url", required=True, help="HTTP RPC URL of the Subtensor EVM endpoint")
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--token-id", type=int, help="Packed tokenId")
    target.add_argument("--netuid", type=int, help="Subnet netuid")
    args = parser.parse_args()

    w3 = get_web3_connection(args.rpc_url)
    vault = w3.eth.contract(
        address=w3.to_checksum_address(args.vault_address),
        abi=load_abi("AlphaVault"),
    )
    registry = None
    if args.registry_address:
        registry = w3.eth.contract(
            address=w3.to_checksum_address(args.registry_address),
            abi=load_abi("ValidatorRegistry"),
        )

    token_id = (
        args.token_id if args.token_id is not None
        else vault.functions.currentTokenId(args.netuid).call()
    )
    netuid = token_id & 0xFFFF

    try:
        share_price = vault.functions.sharePrice(token_id).call()
        share_price_error = ""
    except ContractLogicError as e:
        share_price = ""
        share_price_error = _extract_error_name(e, vault.abi)

    row = {
        "token_id": token_id,
        "total_supply": vault.functions.totalSupply(token_id).call(),
        "total_stake": vault.functions.totalStake(token_id).call(),
        "share_price": share_price,
        "share_price_error": share_price_error,
        "subnet_clone": vault.functions.subnetClone(token_id).call(),
        **_validator_columns(registry, netuid),
    }

    writer = make_csv_writer(sys.stdout, list(row))
    writer.writerow(row)

    print(f"Fetched state for token {token_id}", file=sys.stderr)


if __name__ == "__main__":
    main()
