#!/usr/bin/env python3

"""
Fetch AlphaVault `Rebalanced` events within a block range and print as CSV.

Event signature:
    Rebalanced(uint256 indexed tokenId, uint8 moveCount)
"""

import argparse
import sys
from dataclasses import asdict, dataclass, fields

from web3 import Web3

from common import (
    REBALANCED_ARGS,
    REBALANCED_SIG,
    assert_event_abi,
    get_web3_connection,
    load_abi,
    make_csv_writer,
)


@dataclass
class RebalancedEvent:
    tx_hash: str
    token_id: int
    move_count: int


FIELDNAMES = [f.name for f in fields(RebalancedEvent)]


def fetch_rebalances(
    w3: Web3,
    vault_address: str,
    block_start: int,
    block_end: int,
) -> list[RebalancedEvent]:
    address = w3.to_checksum_address(vault_address)
    abi = load_abi("AlphaVault")
    assert_event_abi(abi, "Rebalanced", REBALANCED_ARGS)
    vault = w3.eth.contract(address=address, abi=abi)

    logs = w3.eth.get_logs({
        "fromBlock": block_start,
        "toBlock": block_end,
        "address": address,
        "topics": [w3.keccak(text=REBALANCED_SIG).hex()],
    })

    events = []
    for log in logs:
        args = vault.events.Rebalanced().process_log(log)["args"]
        events.append(RebalancedEvent(
            tx_hash=log["transactionHash"].hex(),
            token_id=args["tokenId"],
            move_count=args["moveCount"],
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
    events = fetch_rebalances(w3, args.vault_address, args.block_start, args.block_end)

    writer = make_csv_writer(sys.stdout, FIELDNAMES)
    for event in events:
        writer.writerow(asdict(event))

    print(f"Found {len(events)} Rebalanced events", file=sys.stderr)


if __name__ == "__main__":
    main()
