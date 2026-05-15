#!/usr/bin/env python3

"""Print a one-row CSV summary of an AlphaVault token's on-chain state."""

import argparse
import sys

from web3.contract import Contract
from web3.exceptions import ContractLogicError

from common import (
    extract_error_name,
    get_web3_connection,
    load_abi,
    lookup_token_id,
    make_csv_writer,
)


def _validator_columns(registry: Contract | None, netuid: int) -> dict:
    """Three (hotkey, weight) slots + count; empty for unused slots or no registry."""
    cols: dict = {"validators_count": ""}
    for i in range(3):
        cols[f"validator_{i+1}_hotkey"] = ""
        cols[f"validator_{i+1}_weight"] = ""
    if registry is None:
        return cols
    hotkeys, weights = registry.functions.getValidators(netuid).call()
    count = sum(1 for w in weights if w != 0)
    cols["validators_count"] = count
    for i in range(count):
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

    token_id = args.token_id if args.token_id is not None else lookup_token_id(vault, args.netuid)
    netuid = token_id & 0xFFFF

    try:
        share_price = vault.functions.sharePrice(token_id).call()
        share_price_error = ""
    except ContractLogicError as e:
        share_price = ""
        share_price_error = extract_error_name(e, vault.abi)

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
