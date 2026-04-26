"""Common utilities for Alpha-Wrapper observability scripts."""

import csv
import json
import pathlib
from typing import Any, TextIO

from web3 import Web3


def get_web3_connection(rpc_url: str) -> Web3:
    """Get a Web3 connection to a Subtensor EVM HTTP RPC endpoint.
    """
    if not rpc_url.startswith(("http://", "https://")):
        raise ValueError(f"--rpc-url must be http(s), got: {rpc_url}")
    w3 = Web3(Web3.HTTPProvider(rpc_url))
    if not w3.is_connected():
        raise ConnectionError(f"Failed to connect to {rpc_url}")
    return w3


def load_abi(contract_name: str) -> list[dict[str, Any]]:
    """Load a contract's ABI from forge build output (`out/{Name}.sol/{Name}.json`).
    """
    forge_out = pathlib.Path(__file__).parent.parent / "out" / f"{contract_name}.sol" / f"{contract_name}.json"
    if not forge_out.exists():
        raise FileNotFoundError(
            f"ABI not found at {forge_out}. Run `forge build` from the repo root first."
        )
    return json.loads(forge_out.read_text())["abi"]


def make_csv_writer(stream: TextIO, fieldnames: list[str]) -> csv.DictWriter:
    writer = csv.DictWriter(stream, fieldnames=fieldnames)
    writer.writeheader()
    return writer
