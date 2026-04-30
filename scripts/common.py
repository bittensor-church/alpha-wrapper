"""Common utilities for Alpha-Wrapper observability scripts."""

import csv
import json
import pathlib
import sys
from collections.abc import Iterator
from dataclasses import asdict, fields
from typing import Any, TextIO

from eth_utils import function_signature_to_4byte_selector
from web3 import Web3
from web3.contract import Contract
from web3.exceptions import ContractLogicError


def get_web3_connection(rpc_url: str) -> Web3:
    """Get a Web3 connection to a Subtensor EVM HTTP RPC endpoint."""
    if not rpc_url.startswith(("http://", "https://")):
        raise ValueError(f"--rpc-url must be http(s), got: {rpc_url}")
    w3 = Web3(Web3.HTTPProvider(rpc_url))
    if not w3.is_connected():
        raise ConnectionError(f"Failed to connect to {rpc_url}")
    return w3


def load_abi(contract_name: str) -> list[dict[str, Any]]:
    """Load a contract's ABI"""
    abi = pathlib.Path(__file__).parent.parent / "out" / f"{contract_name}.sol" / f"{contract_name}.json"
    if not abi.exists():
        raise FileNotFoundError(
            f"ABI not found at {abi}. Run `forge build` from the repo root first."
        )
    return json.loads(abi.read_text())["abi"]


def make_csv_writer(stream: TextIO, fieldnames: list[str]) -> csv.DictWriter:
    writer = csv.DictWriter(stream, fieldnames=fieldnames)
    writer.writeheader()
    return writer


def extract_error_name(exc: Exception, abi: list[dict]) -> str:
    """Match the exception's revert-data 4-byte selector against custom errors in the ABI.

    Falls back to the raw selector (e.g. ``0xf2b8b360``) if the selector is not
    declared in the ABI, and to the exception class name if no selector is present.
    """
    data = getattr(exc, "data", None)
    if isinstance(data, dict):
        data = data.get("data")  # web3.py sometimes wraps as {"data": "0x..."}
    if not isinstance(data, str) or not data.startswith("0x") or len(data) < 10:
        return type(exc).__name__
    selector = data[:10].lower()
    for item in abi:
        if item.get("type") != "error":
            continue
        sig = f"{item['name']}({','.join(i['type'] for i in item['inputs'])})"
        if "0x" + function_signature_to_4byte_selector(sig).hex() == selector:
            return item["name"]
    return selector


def lookup_token_id(vault: Contract, netuid: int) -> int:
    """Resolve `netuid` to its current packed tokenId via `vault.currentTokenId`.

    Exits with a friendly error if the call reverts (e.g. `SubnetNotRegistered`
    for a netuid that was never registered or has been fully dissolved).
    """
    try:
        return vault.functions.currentTokenId(netuid).call()
    except ContractLogicError as e:
        sys.exit(f"netuid {netuid}: {extract_error_name(e, vault.abi)}")


def fetch_event_logs(
    w3: Web3,
    address: str,
    contract_name: str,
    event_name: str,
    block_start: int,
    block_end: int,
) -> Iterator[tuple[dict, dict]]:
    """Yield (log, decoded_args) for `event_name` from `contract_name` in the block range."""
    checksummed = w3.to_checksum_address(address)
    contract = w3.eth.contract(address=checksummed, abi=load_abi(contract_name))
    event_handle = contract.events[event_name]()
    logs = w3.eth.get_logs({
        "fromBlock": block_start,
        "toBlock": block_end,
        "address": checksummed,
        "topics": [event_handle.topic],
    })
    for log in logs:
        yield log, event_handle.process_log(log)["args"]


def write_dataclass_csv(stream: TextIO, rows: list, dataclass_type: type, event_name: str) -> None:
    """Write dataclass rows as CSV (header + rows) and log a count to stderr."""
    fieldnames = [f.name for f in fields(dataclass_type)]
    writer = make_csv_writer(stream, fieldnames)
    for row in rows:
        writer.writerow(asdict(row))
    print(f"Found {len(rows)} {event_name} events", file=sys.stderr)
