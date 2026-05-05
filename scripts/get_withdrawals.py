#!/usr/bin/env python3

"""Fetch AlphaVault `Withdrawn` events within a block range and print as CSV."""

import argparse
import sys
from dataclasses import dataclass

from common import fetch_event_logs, get_web3_connection, write_dataclass_csv


@dataclass
class WithdrawnEvent:
    tx_hash: str
    user: str
    token_id: int
    shares: int
    assets: int


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault-address", required=True, help="AlphaVault contract address")
    parser.add_argument("--block-start", required=True, type=int, help="Starting block (inclusive)")
    parser.add_argument("--block-end", required=True, type=int, help="Ending block (inclusive)")
    parser.add_argument("--rpc-url", required=True, help="HTTP RPC URL of the Subtensor EVM endpoint")
    args = parser.parse_args()

    w3 = get_web3_connection(args.rpc_url)
    rows = [
        WithdrawnEvent(
            tx_hash=log["transactionHash"].to_0x_hex(),
            user=ev_args["user"],
            token_id=ev_args["tokenId"],
            shares=ev_args["shares"],
            assets=ev_args["assets"],
        )
        for log, ev_args in fetch_event_logs(
            w3, args.vault_address, "AlphaVault", "Withdrawn",
            args.block_start, args.block_end,
        )
    ]
    write_dataclass_csv(sys.stdout, rows, WithdrawnEvent, "Withdrawn")


if __name__ == "__main__":
    main()
