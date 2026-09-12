#!/usr/bin/env python3

"""Fetch attested or Basic validator registry updates within a block range and print as CSV."""

import argparse
import sys
from dataclasses import dataclass

from common import (
    add_block_range_arguments,
    fetch_event_logs,
    get_web3_connection,
    write_dataclass_csv,
)


@dataclass
class ValidatorsUpdatedEvent:
    tx_hash: str
    netuid: int
    nonce: int
    count: int
    timestamp: int


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry-address", required=True, help="Validator registry contract address")
    parser.add_argument("--registry-type", choices=("attested", "basic"), default="attested")
    add_block_range_arguments(parser)
    parser.add_argument("--rpc-url", required=True, help="HTTP RPC URL of the Subtensor EVM endpoint")
    args = parser.parse_args()

    w3 = get_web3_connection(args.rpc_url)
    rows = (
        ValidatorsUpdatedEvent(
            tx_hash=log["transactionHash"].to_0x_hex(),
            netuid=ev_args["netuid"],
            nonce=ev_args["nonce"],
            count=1 if args.registry_type == "basic" else len(ev_args["hotkeys"]),
            timestamp=w3.eth.get_block(log["blockNumber"]).timestamp,
        )
        for log, ev_args in fetch_event_logs(
            w3, args.registry_address,
            "BasicValidatorRegistry" if args.registry_type == "basic" else "ValidatorRegistry",
            "ValidatorUpdated" if args.registry_type == "basic" else "ValidatorsUpdated",
            args.block_start, args.block_end, chunk_size=args.chunk_size,
        )
    )
    write_dataclass_csv(sys.stdout, rows, ValidatorsUpdatedEvent, "ValidatorsUpdated")


if __name__ == "__main__":
    main()
