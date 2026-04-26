#!/usr/bin/env python3

"""Fetch AlphaVault `SubnetProxyCreated` events within a block range and print as CSV."""

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
class SubnetProxyCreatedEvent:
    tx_hash: str
    token_id: int
    clone: str


FIELDNAMES = [f.name for f in fields(SubnetProxyCreatedEvent)]


def fetch_subnet_proxies(
    w3: Web3,
    vault_address: str,
    block_start: int,
    block_end: int,
) -> list[SubnetProxyCreatedEvent]:
    address = w3.to_checksum_address(vault_address)
    abi = load_abi("AlphaVault")
    vault = w3.eth.contract(address=address, abi=abi)

    logs = w3.eth.get_logs({
        "fromBlock": block_start,
        "toBlock": block_end,
        "address": address,
        "topics": [vault.events.SubnetProxyCreated().topic],
    })

    events = []
    for log in logs:
        args = vault.events.SubnetProxyCreated().process_log(log)["args"]
        events.append(SubnetProxyCreatedEvent(
            tx_hash=log["transactionHash"].hex(),
            token_id=args["tokenId"],
            clone=args["clone"],
        ))
    return events


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault-address", required=True, help="AlphaVault contract address")
    parser.add_argument("--block-start", required=True, type=int, help="Starting block (inclusive)")
    parser.add_argument("--block-end", required=True, type=int, help="Ending block (inclusive)")
    parser.add_argument("--rpc-url", required=True, help="HTTP RPC URL of the Subtensor EVM endpoint")
    args = parser.parse_args()

    w3 = get_web3_connection(args.rpc_url)
    events = fetch_subnet_proxies(w3, args.vault_address, args.block_start, args.block_end)

    writer = make_csv_writer(sys.stdout, FIELDNAMES)
    for event in events:
        writer.writerow(asdict(event))

    print(f"Found {len(events)} SubnetProxyCreated events", file=sys.stderr)


if __name__ == "__main__":
    main()
