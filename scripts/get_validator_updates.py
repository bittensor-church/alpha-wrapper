#!/usr/bin/env python3

"""Fetch ValidatorRegistry `ValidatorsUpdated` events within a block range and print as CSV."""

import argparse
import sys
from dataclasses import dataclass

from common import fetch_event_logs, get_web3_connection, write_dataclass_csv


@dataclass
class ValidatorsUpdatedEvent:
    tx_hash: str
    netuid: int
    nonce: int
    count: int
    timestamp: int


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry-address", required=True, help="ValidatorRegistry contract address")
    parser.add_argument("--block-start", required=True, type=int, help="Starting block (inclusive)")
    parser.add_argument("--block-end", required=True, type=int, help="Ending block (inclusive)")
    parser.add_argument("--rpc-url", required=True, help="HTTP RPC URL of the Subtensor EVM endpoint")
    args = parser.parse_args()

    w3 = get_web3_connection(args.rpc_url)
    rows = [
        ValidatorsUpdatedEvent(
            tx_hash=log["transactionHash"].to_0x_hex(),
            netuid=ev_args["netuid"],
            nonce=ev_args["nonce"],
            count=len(ev_args["hotkeys"]),
            timestamp=w3.eth.get_block(log["blockNumber"]).timestamp,
        )
        for log, ev_args in fetch_event_logs(
            w3, args.registry_address, "ValidatorRegistry", "ValidatorsUpdated",
            args.block_start, args.block_end,
        )
    ]
    write_dataclass_csv(sys.stdout, rows, ValidatorsUpdatedEvent, "ValidatorsUpdated")


if __name__ == "__main__":
    main()
