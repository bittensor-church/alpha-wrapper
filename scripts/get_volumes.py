#!/usr/bin/env python3

"""Print unit-safe deposit and unwrap metrics for an AlphaVault token as one CSV row."""

import argparse
import sys
from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Any

from common import (
    add_block_range_arguments,
    fetch_event_logs,
    get_web3_connection,
    load_abi,
    lookup_token_id,
    make_csv_writer,
)


@dataclass
class EventTotals:
    """Count and running sums of the named amount fields of one event stream."""

    summed: tuple[str, ...]
    count: int = 0
    sums: dict[str, int] = field(default_factory=dict)

    def add(self, args: Mapping[str, Any]) -> None:
        self.count += 1
        for name in self.summed:
            self.sums[name] = self.sums.get(name, 0) + args[name]

    def total(self, name: str) -> int:
        return self.sums.get(name, 0)


def build_volume_row(
    token_id: int,
    user: str,
    deposits: EventTotals,
    alpha_unwraps: EventTotals,
    tao_unwraps: EventTotals,
    dissolved_unwraps: EventTotals,
) -> dict[str, int | str]:
    """Aggregate events without combining alpha RAO and TAO wei."""
    tao_from_alpha_sales = tao_unwraps.total("taoOut")
    tao_from_dissolutions = dissolved_unwraps.total("taoOut")

    return {
        "token_id": token_id,
        "user": user,
        "deposit_count": deposits.count,
        "alpha_deposited_rao": deposits.total("assets"),
        "shares_minted": deposits.total("shares"),
        "alpha_unwrap_count": alpha_unwraps.count,
        "alpha_unwrap_shares_burned": alpha_unwraps.total("shares"),
        "alpha_unwrapped_rao": alpha_unwraps.total("alphaOut"),
        "tao_unwrap_count": tao_unwraps.count,
        "tao_unwrap_shares_burned": tao_unwraps.total("shares"),
        "alpha_sold_for_tao_rao": tao_unwraps.total("alphaSold"),
        "tao_from_alpha_sales_wei": tao_from_alpha_sales,
        "dissolved_unwrap_count": dissolved_unwraps.count,
        "dissolved_unwrap_shares_burned": dissolved_unwraps.total("shares"),
        "tao_from_dissolutions_wei": tao_from_dissolutions,
        "unwrap_count": alpha_unwraps.count + tao_unwraps.count + dissolved_unwraps.count,
        "shares_burned": (
            alpha_unwraps.total("shares")
            + tao_unwraps.total("shares")
            + dissolved_unwraps.total("shares")
        ),
        "tao_received_wei": tao_from_alpha_sales + tao_from_dissolutions,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault-address", required=True, help="AlphaVault contract address")
    add_block_range_arguments(parser)
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

    def totals_for(event_name: str, *summed: str) -> EventTotals:
        totals = EventTotals(summed)
        for _log, ev_args in fetch_event_logs(
            w3, args.vault_address, "AlphaVault", event_name,
            args.block_start, args.block_end,
            argument_filters=arg_filters, chunk_size=args.chunk_size,
        ):
            totals.add(ev_args)
        return totals

    row = build_volume_row(
        token_id,
        user_filter if user_filter is not None else "",
        totals_for("Deposited", "assets", "shares"),
        totals_for("Unwrapped", "shares", "alphaOut"),
        totals_for("UnwrappedForTao", "shares", "alphaSold", "taoOut"),
        totals_for("DissolvedSubnetUnwrapped", "shares", "taoOut"),
    )

    writer = make_csv_writer(sys.stdout, list(row))
    writer.writerow(row)

    label = f"token {token_id}" + (f" / user {user_filter}" if user_filter is not None else "")
    print(f"Aggregated volumes for {label}", file=sys.stderr)


if __name__ == "__main__":
    main()
