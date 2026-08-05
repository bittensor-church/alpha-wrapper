#!/usr/bin/env python3

"""Print unit-safe deposit and unwrap metrics for an AlphaVault token as one CSV row."""

import argparse
import sys
from collections.abc import Mapping, Sequence
from typing import Any

from common import get_web3_connection, load_abi, lookup_token_id, make_csv_writer


EventLog = Mapping[str, Any]


def _sum(logs: Sequence[EventLog], field: str) -> int:
    return sum(log["args"][field] for log in logs)


def build_volume_row(
    token_id: int,
    user: str,
    deposit_logs: Sequence[EventLog],
    alpha_unwrap_logs: Sequence[EventLog],
    tao_unwrap_logs: Sequence[EventLog],
    dissolved_unwrap_logs: Sequence[EventLog],
) -> dict[str, int | str]:
    """Aggregate events without combining alpha RAO and TAO wei."""
    alpha_sold = _sum(tao_unwrap_logs, "alphaSold")
    tao_from_alpha_sales = _sum(tao_unwrap_logs, "taoOut")
    tao_from_dissolutions = _sum(dissolved_unwrap_logs, "taoOut")
    unwrap_count = len(alpha_unwrap_logs) + len(tao_unwrap_logs) + len(dissolved_unwrap_logs)
    shares_burned = (
        _sum(alpha_unwrap_logs, "shares")
        + _sum(tao_unwrap_logs, "shares")
        + _sum(dissolved_unwrap_logs, "shares")
    )

    return {
        "token_id": token_id,
        "user": user,
        "deposit_count": len(deposit_logs),
        "alpha_deposited_rao": _sum(deposit_logs, "assets"),
        "shares_minted": _sum(deposit_logs, "shares"),
        "alpha_unwrap_count": len(alpha_unwrap_logs),
        "alpha_unwrap_shares_burned": _sum(alpha_unwrap_logs, "shares"),
        "alpha_unwrapped_rao": _sum(alpha_unwrap_logs, "alphaOut"),
        "tao_unwrap_count": len(tao_unwrap_logs),
        "tao_unwrap_shares_burned": _sum(tao_unwrap_logs, "shares"),
        "alpha_sold_for_tao_rao": alpha_sold,
        "tao_from_alpha_sales_wei": tao_from_alpha_sales,
        "dissolved_unwrap_count": len(dissolved_unwrap_logs),
        "dissolved_unwrap_shares_burned": _sum(dissolved_unwrap_logs, "shares"),
        "tao_from_dissolutions_wei": tao_from_dissolutions,
        "unwrap_count": unwrap_count,
        "shares_burned": shares_burned,
        "tao_received_wei": tao_from_alpha_sales + tao_from_dissolutions,
    }


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
    unwrap_logs = vault.events.Unwrapped.get_logs(
        from_block=args.block_start,
        to_block=args.block_end,
        argument_filters=arg_filters,
    )
    tao_unwrap_logs = vault.events.UnwrappedForTao.get_logs(
        from_block=args.block_start,
        to_block=args.block_end,
        argument_filters=arg_filters,
    )
    dissolved_unwrap_logs = vault.events.DissolvedSubnetUnwrapped.get_logs(
        from_block=args.block_start,
        to_block=args.block_end,
        argument_filters=arg_filters,
    )

    row = build_volume_row(
        token_id,
        user_filter if user_filter is not None else "",
        deposit_logs,
        unwrap_logs,
        tao_unwrap_logs,
        dissolved_unwrap_logs,
    )

    writer = make_csv_writer(sys.stdout, list(row))
    writer.writerow(row)

    label = f"token {token_id}" + (f" / user {user_filter}" if user_filter is not None else "")
    print(f"Aggregated volumes for {label}", file=sys.stderr)


if __name__ == "__main__":
    main()
