"""Common utilities for Alpha-Wrapper observability scripts."""

import argparse
import csv
import json
import pathlib
import sys
from collections.abc import Iterable, Iterator
from dataclasses import asdict, fields
from typing import Any, Optional, TextIO

from eth_utils import function_signature_to_4byte_selector
from web3 import Web3
from web3.contract import Contract
from web3.exceptions import ContractLogicError

# A node caps how much history one eth_getLogs may cover, so a long range is read
# in windows of this many blocks.
DEFAULT_CHUNK_SIZE = 10_000


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


def lookup_token_id(vault: Contract, netuid: int, block: int | str = "latest") -> int:
    """Resolve `netuid` to its current packed tokenId via `vault.currentTokenId`.

    Exits with a friendly error if the call reverts (e.g. `SubnetNotRegistered`
    for a netuid that was never registered or has been fully dissolved).
    """
    try:
        return vault.functions.currentTokenId(netuid).call(block_identifier=block)
    except ContractLogicError as e:
        sys.exit(f"netuid {netuid}: {extract_error_name(e, vault.abi)}")


def block_number(text: str) -> int:
    """argparse type for an absolute block number; a relative offset would be resolved
    against a fresh head on every call and the report would span several blocks."""
    value = int(text)
    if value < 0:
        raise argparse.ArgumentTypeError(f"block must be an absolute, non-negative number, got {value}")
    return value


def add_block_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--block", type=block_number, help="Block to read at (default: the current head)")


def resolve_block(w3: Web3, requested: Optional[int]) -> int:
    """The one block every read of a report is pinned to: the requested one, or the
    head read exactly once."""
    if requested is None:
        return w3.eth.block_number
    if requested < 0:
        raise ValueError(f"block must be an absolute, non-negative number, got {requested}")
    return requested


def add_block_range_arguments(parser: argparse.ArgumentParser) -> None:
    """The block window and per-request chunk size every event reader takes."""
    parser.add_argument("--block-start", required=True, type=int, help="Starting block (inclusive)")
    parser.add_argument("--block-end", required=True, type=int, help="Ending block (inclusive)")
    parser.add_argument("--chunk-size", type=int, default=DEFAULT_CHUNK_SIZE,
                        help=f"Blocks per log request (default {DEFAULT_CHUNK_SIZE})")


def block_chunks(start: int, end: int, size: int) -> Iterator[tuple[int, int]]:
    """Split an inclusive block range into inclusive windows of at most `size` blocks."""
    if size < 1:
        raise ValueError(f"--chunk-size must be at least 1 block, got {size}")
    for chunk_start in range(start, end + 1, size):
        yield chunk_start, min(chunk_start + size - 1, end)


def fetch_event_logs(
    w3: Web3,
    address: str,
    contract_name: str,
    event_name: str,
    block_start: int,
    block_end: int,
    argument_filters: Optional[dict[str, Any]] = None,
    chunk_size: int = DEFAULT_CHUNK_SIZE,
) -> Iterator[tuple[dict, dict]]:
    """Yield (log, decoded_args) for `event_name` from `contract_name` in the block
    range, one chunk of blocks per request."""
    if not 0 <= block_start <= block_end:
        raise ValueError(
            f"block range must satisfy 0 <= start <= end, got {block_start}..{block_end}"
        )
    contract = w3.eth.contract(
        address=w3.to_checksum_address(address), abi=load_abi(contract_name)
    )
    return _stream_event_logs(
        contract, event_name, block_start, block_end, argument_filters, chunk_size
    )


def _stream_event_logs(
    contract: Contract,
    event_name: str,
    block_start: int,
    block_end: int,
    argument_filters: Optional[dict[str, Any]],
    chunk_size: int,
) -> Iterator[tuple[dict, dict]]:
    event_handle = contract.events[event_name]()
    for from_block, to_block in block_chunks(block_start, block_end, chunk_size):
        for log in event_handle.get_logs(
            from_block=from_block, to_block=to_block, argument_filters=argument_filters,
        ):
            yield log, log["args"]


def write_dataclass_csv(
    stream: TextIO, rows: Iterable, dataclass_type: type, event_name: str,
) -> None:
    """Write dataclass rows as CSV (header + rows) as they arrive and log a count to stderr."""
    fieldnames = [f.name for f in fields(dataclass_type)]
    writer = make_csv_writer(stream, fieldnames)
    count = 0
    for row in rows:
        writer.writerow(asdict(row))
        count += 1
    print(f"Found {count} {event_name} events", file=sys.stderr)
