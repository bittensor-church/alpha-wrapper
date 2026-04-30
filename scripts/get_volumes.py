#!/usr/bin/env python3

"""Print a one-row CSV summary of deposit + withdrawal volumes for an AlphaVault token."""

import argparse
import sys
from typing import Any

from common import get_web3_connection, load_abi, lookup_token_id, make_csv_writer


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault-address", required=True, help="AlphaVault contract address")
    parser.add_argument("--block-start", required=True, type=int, help="Starting block (inclusive)")
    parser.add_argument("--block-end", required=True, type=int, help="Ending block (inclusive)")
    parser.add_argument("--user", help="Optional user address; restricts volumes to this user")
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

    token_id = args.token_id if args.token_id is not None else lookup_token_id(vault, args.netuid)
    user_filter = w3.to_checksum_address(args.user) if args.user is not None else None

    arg_filters: dict[str, Any] = {"tokenId": token_id}
    if user_filter is not None:
        arg_filters["user"] = user_filter

    deposit_logs = vault.events.Deposited.get_logs(
        from_block=args.block_start,
        to_block=args.block_end,
        argument_filters=arg_filters,
    )
    withdraw_logs = vault.events.Withdrawn.get_logs(
        from_block=args.block_start,
        to_block=args.block_end,
        argument_filters=arg_filters,
    )

    row = {
        "token_id": token_id,
        "user": user_filter if user_filter is not None else "",
        "deposit_count": len(deposit_logs),
        "total_assets_in": sum(log["args"]["assets"] for log in deposit_logs),
        "total_shares_minted": sum(log["args"]["shares"] for log in deposit_logs),
        "withdraw_count": len(withdraw_logs),
        "total_shares_burned": sum(log["args"]["shares"] for log in withdraw_logs),
        "total_assets_out": sum(log["args"]["assets"] for log in withdraw_logs),
    }

    writer = make_csv_writer(sys.stdout, list(row))
    writer.writerow(row)

    label = f"token {token_id}" + (f" / user {user_filter}" if user_filter is not None else "")
    print(f"Aggregated volumes for {label}", file=sys.stderr)


if __name__ == "__main__":
    main()
