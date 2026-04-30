#!/usr/bin/env python3

"""Fetch AlphaVault `SubnetProxyCreated` events within a block range and print as CSV."""

import argparse
import sys
from dataclasses import dataclass

from common import fetch_event_logs, get_web3_connection, write_dataclass_csv


@dataclass
class SubnetProxyCreatedEvent:
    tx_hash: str
    token_id: int
    clone: str


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault-address", required=True, help="AlphaVault contract address")
    parser.add_argument("--block-start", required=True, type=int, help="Starting block (inclusive)")
    parser.add_argument("--block-end", required=True, type=int, help="Ending block (inclusive)")
    parser.add_argument("--rpc-url", required=True, help="HTTP RPC URL of the Subtensor EVM endpoint")
    args = parser.parse_args()

    w3 = get_web3_connection(args.rpc_url)
    rows = [
        SubnetProxyCreatedEvent(
            tx_hash=log["transactionHash"].to_0x_hex(),
            token_id=ev_args["tokenId"],
            clone=ev_args["clone"],
        )
        for log, ev_args in fetch_event_logs(
            w3, args.vault_address, "AlphaVault", "SubnetProxyCreated",
            args.block_start, args.block_end,
        )
    ]
    write_dataclass_csv(sys.stdout, rows, SubnetProxyCreatedEvent, "SubnetProxyCreated")


if __name__ == "__main__":
    main()
