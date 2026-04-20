#!/usr/bin/env python3

"""
Fetch ValidatorRegistry `ValidatorsBatchUpdated` events within a block range and print as CSV.

Event signature:
    ValidatorsBatchUpdated(uint256 subnetCount, uint256 timestamp)
"""

import argparse
import sys
from dataclasses import asdict, dataclass, fields

from web3 import Web3

from common import (
    VALIDATORS_BATCH_UPDATED_ARGS,
    VALIDATORS_BATCH_UPDATED_SIG,
    assert_event_abi,
    get_web3_connection,
    load_abi,
    make_csv_writer,
)


@dataclass
class ValidatorsBatchUpdatedEvent:
    tx_hash: str
    subnet_count: int
    timestamp: int


FIELDNAMES = [f.name for f in fields(ValidatorsBatchUpdatedEvent)]


def fetch_validator_batch_updates(
    w3: Web3,
    registry_address: str,
    block_start: int,
    block_end: int,
) -> list[ValidatorsBatchUpdatedEvent]:
    address = w3.to_checksum_address(registry_address)
    abi = load_abi("ValidatorRegistry")
    assert_event_abi(abi, "ValidatorsBatchUpdated", VALIDATORS_BATCH_UPDATED_ARGS)
    registry = w3.eth.contract(address=address, abi=abi)

    logs = w3.eth.get_logs({
        "fromBlock": block_start,
        "toBlock": block_end,
        "address": address,
        "topics": [w3.keccak(text=VALIDATORS_BATCH_UPDATED_SIG).hex()],
    })

    events = []
    for log in logs:
        args = registry.events.ValidatorsBatchUpdated().process_log(log)["args"]
        events.append(ValidatorsBatchUpdatedEvent(
            tx_hash=log["transactionHash"].hex(),
            subnet_count=args["subnetCount"],
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
    events = fetch_validator_batch_updates(w3, args.registry_address, args.block_start, args.block_end)

    writer = make_csv_writer(sys.stdout, FIELDNAMES)
    for event in events:
        writer.writerow(asdict(event))

    print(f"Found {len(events)} ValidatorsBatchUpdated events", file=sys.stderr)


if __name__ == "__main__":
    main()
