#!/usr/bin/env python3

"""
Aggregate AlphaVault Deposited + Withdrawn events over a block range and print a rollup CSV.

Group keys (--by):
    user      -> one row per user
    token_id  -> one row per token_id
    both      -> one row per (user, token_id)
"""

import argparse
import sys
from collections import defaultdict
from dataclasses import asdict, dataclass, fields
from typing import Any

from web3 import Web3

from common import (
    DEPOSITED_ARGS,
    DEPOSITED_SIG,
    WITHDRAWN_ARGS,
    WITHDRAWN_SIG,
    assert_event_abi,
    get_web3_connection,
    load_abi,
    make_csv_writer,
)


@dataclass
class VolumeTotals:
    deposit_count: int = 0
    total_assets_in: int = 0
    total_shares_minted: int = 0
    withdraw_count: int = 0
    total_shares_burned: int = 0
    total_assets_out: int = 0


TOTALS_FIELDS = [f.name for f in fields(VolumeTotals)]


def _key(group_by: str, user: str, token_id: int) -> tuple:
    if group_by == "user":
        return (user,)
    if group_by == "token_id":
        return (token_id,)
    return (user, token_id)


def fetch_volumes(
    w3: Web3,
    vault_address: str,
    block_start: int,
    block_end: int,
    group_by: str,
) -> dict[tuple, VolumeTotals]:
    address = w3.to_checksum_address(vault_address)
    abi = load_abi("AlphaVault")
    assert_event_abi(abi, "Deposited", DEPOSITED_ARGS)
    assert_event_abi(abi, "Withdrawn", WITHDRAWN_ARGS)
    vault = w3.eth.contract(address=address, abi=abi)

    deposit_topic = w3.keccak(text=DEPOSITED_SIG)
    withdraw_topic = w3.keccak(text=WITHDRAWN_SIG)

    logs = w3.eth.get_logs({
        "fromBlock": block_start,
        "toBlock": block_end,
        "address": address,
        "topics": [[deposit_topic.hex(), withdraw_topic.hex()]],
    })

    acc: dict[tuple, VolumeTotals] = defaultdict(VolumeTotals)

    for log in logs:
        if log["topics"][0] == deposit_topic:
            args = vault.events.Deposited().process_log(log)["args"]
            totals = acc[_key(group_by, args["user"], args["tokenId"])]
            totals.deposit_count += 1
            totals.total_assets_in += args["assets"]
            totals.total_shares_minted += args["shares"]
        elif log["topics"][0] == withdraw_topic:
            args = vault.events.Withdrawn().process_log(log)["args"]
            totals = acc[_key(group_by, args["user"], args["tokenId"])]
            totals.withdraw_count += 1
            totals.total_shares_burned += args["shares"]
            totals.total_assets_out += args["assets"]

    return acc


def _dimension_row(group_by: str, key: tuple) -> dict[str, Any]:
    if group_by == "user":
        return {"user": key[0]}
    if group_by == "token_id":
        return {"token_id": key[0]}
    user, token_id = key
    return {"user": user, "token_id": token_id}


def _fieldnames(group_by: str) -> list[str]:
    if group_by == "user":
        return ["user"] + TOTALS_FIELDS
    if group_by == "token_id":
        return ["token_id"] + TOTALS_FIELDS
    return ["user", "token_id"] + TOTALS_FIELDS


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault-address", required=True, help="AlphaVault contract address")
    parser.add_argument("--block-start", required=True, type=int, help="Starting block (inclusive)")
    parser.add_argument("--block-end", required=True, type=int, help="Ending block (inclusive)")
    parser.add_argument("--by", choices=["user", "token_id", "both"], required=True, help="Rollup grouping key")
    parser.add_argument("--rpc-url", required=True, help="HTTP RPC URL of the Subtensor EVM endpoint")
    args = parser.parse_args()

    w3 = get_web3_connection(args.rpc_url)
    acc = fetch_volumes(w3, args.vault_address, args.block_start, args.block_end, args.by)

    writer = make_csv_writer(sys.stdout, _fieldnames(args.by))
    for key, totals in acc.items():
        writer.writerow({**_dimension_row(args.by, key), **asdict(totals)})

    print(f"Aggregated {len(acc)} rows (grouped by {args.by})", file=sys.stderr)


if __name__ == "__main__":
    main()
