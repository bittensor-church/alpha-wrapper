#!/usr/bin/env python3

"""
Fetch AlphaVault `Withdrawn` events within a block range and print as CSV.

Event signature:
    Withdrawn(address indexed user, uint256 indexed tokenId, uint256 shares, uint256 assets, bytes32 hotkey)
"""

import argparse
import sys
from dataclasses import asdict, dataclass, fields

from web3 import Web3

from common import (
    WITHDRAWN_ARGS,
    WITHDRAWN_SIG,
    assert_event_abi,
    get_web3_connection,
    load_abi,
    make_csv_writer,
)


@dataclass
class WithdrawnEvent:
    tx_hash: str
    user: str
    token_id: int
    shares: int
    assets: int
    hotkey: str


FIELDNAMES = [f.name for f in fields(WithdrawnEvent)]


def fetch_withdrawals(
    w3: Web3,
    vault_address: str,
    block_start: int,
    block_end: int,
) -> list[WithdrawnEvent]:
    address = w3.to_checksum_address(vault_address)
    abi = load_abi("AlphaVault")
    assert_event_abi(abi, "Withdrawn", WITHDRAWN_ARGS)
    vault = w3.eth.contract(address=address, abi=abi)

    logs = w3.eth.get_logs({
        "fromBlock": block_start,
        "toBlock": block_end,
        "address": address,
        "topics": [w3.keccak(text=WITHDRAWN_SIG).hex()],
    })

    events = []
    for log in logs:
        args = vault.events.Withdrawn().process_log(log)["args"]
        events.append(WithdrawnEvent(
            tx_hash=log["transactionHash"].hex(),
            user=args["user"],
            token_id=args["tokenId"],
            shares=args["shares"],
            assets=args["assets"],
            hotkey="0x" + args["hotkey"].hex(),
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
    events = fetch_withdrawals(w3, args.vault_address, args.block_start, args.block_end)

    writer = make_csv_writer(sys.stdout, FIELDNAMES)
    for event in events:
        writer.writerow(asdict(event))

    print(f"Found {len(events)} Withdrawn events", file=sys.stderr)


if __name__ == "__main__":
    main()
