#!/usr/bin/env python3

"""Fetch ValidatorRegistry `ValidatorsUpdated` events within a block range and print as CSV."""

import argparse
import sys
from dataclasses import asdict, dataclass, fields

from web3 import Web3

from common import (
    get_web3_connection,
    load_abi,
    make_csv_writer,
)


@dataclass
class ValidatorsUpdatedEvent:
    tx_hash: str
    netuid: int
    count: int
    timestamp: int


FIELDNAMES = [f.name for f in fields(ValidatorsUpdatedEvent)]


def fetch_validator_updates(
    w3: Web3,
    registry_address: str,
    block_start: int,
    block_end: int,
) -> list[ValidatorsUpdatedEvent]:
    address = w3.to_checksum_address(registry_address)
    abi = load_abi("ValidatorRegistry")
    registry = w3.eth.contract(address=address, abi=abi)

    logs = w3.eth.get_logs({
        "fromBlock": block_start,
        "toBlock": block_end,
        "address": address,
        "topics": [registry.events.ValidatorsUpdated().topic],
    })

    events = []
    for log in logs:
        args = registry.events.ValidatorsUpdated().process_log(log)["args"]
        events.append(ValidatorsUpdatedEvent(
            tx_hash=log["transactionHash"].hex(),
            netuid=args["netuid"],
            count=args["count"],
            timestamp=args["timestamp"],
        ))
    return events


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry-address", required=True, help="ValidatorRegistry contract address")
    parser.add_argument("--block-start", required=True, type=int, help="Starting block (inclusive)")
    parser.add_argument("--block-end", required=True, type=int, help="Ending block (inclusive)")
    parser.add_argument("--rpc-url", required=True, help="HTTP RPC URL of the Subtensor EVM endpoint")
    args = parser.parse_args()

    w3 = get_web3_connection(args.rpc_url)
    events = fetch_validator_updates(w3, args.registry_address, args.block_start, args.block_end)

    writer = make_csv_writer(sys.stdout, FIELDNAMES)
    for event in events:
        writer.writerow(asdict(event))

    print(f"Found {len(events)} ValidatorsUpdated events", file=sys.stderr)


if __name__ == "__main__":
    main()
