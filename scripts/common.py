"""
Common Utilities for Alpha-Wrapper Observability

Shared helpers for the read-only AlphaVault / ValidatorRegistry inspection scripts.
Modeled on collateral/scripts/common.py, stripped of every signing / transaction path.
"""

import csv
import json
import pathlib
from dataclasses import asdict
from typing import Any, TextIO

from web3 import Web3


# Canonical event signatures. Kept here so scripts stay in lockstep if an event
# ever changes on-chain.
DEPOSITED_SIG = "Deposited(address,uint256,uint256,uint256,bytes32)"
WITHDRAWN_SIG = "Withdrawn(address,uint256,uint256,uint256,bytes32)"
REBALANCED_SIG = "Rebalanced(uint256,uint8)"
SUBNET_PROXY_CREATED_SIG = "SubnetProxyCreated(uint256,address)"
VALIDATORS_UPDATED_SIG = "ValidatorsUpdated(uint256,uint8,uint256)"
VALIDATORS_BATCH_UPDATED_SIG = "ValidatorsBatchUpdated(uint256,uint256)"

# Canonical event argument names (ABI input names, in order). Each fetch_* caller
# asserts the compiled ABI still matches these — catches a new/removed/renamed
# field that would otherwise silently vanish from the CSV.
DEPOSITED_ARGS = ["user", "tokenId", "assets", "shares", "hotkey"]
WITHDRAWN_ARGS = ["user", "tokenId", "shares", "assets", "hotkey"]
REBALANCED_ARGS = ["tokenId", "moveCount"]
SUBNET_PROXY_CREATED_ARGS = ["tokenId", "clone"]
VALIDATORS_UPDATED_ARGS = ["netuid", "count", "timestamp"]
VALIDATORS_BATCH_UPDATED_ARGS = ["subnetCount", "timestamp"]


def get_web3_connection(rpc_url: str) -> Web3:
    """Get a Web3 connection to a Subtensor EVM HTTP RPC endpoint.

    Only http(s) URLs are accepted — the observability scripts do one-shot reads
    (block number, event logs, contract calls), so there's no reason to support
    a WebSocket transport here.
    """
    if not rpc_url.startswith(("http://", "https://")):
        raise ValueError(f"--rpc-url must be http(s), got: {rpc_url}")
    w3 = Web3(Web3.HTTPProvider(rpc_url))
    if not w3.is_connected():
        raise ConnectionError(f"Failed to connect to {rpc_url}")
    return w3


def load_abi(contract_name: str) -> list[dict]:
    """Load a contract's ABI from forge build output (`out/{Name}.sol/{Name}.json`).

    Raises a clear FileNotFoundError if forge hasn't built yet.
    """
    forge_out = pathlib.Path(__file__).parent.parent / "out" / f"{contract_name}.sol" / f"{contract_name}.json"
    if not forge_out.exists():
        raise FileNotFoundError(
            f"ABI not found at {forge_out}. Run `forge build` from the repo root first."
        )
    return json.loads(forge_out.read_text())["abi"]


def assert_event_abi(abi: list[dict], event_name: str, expected_args: list[str]) -> None:
    """Verify an event's input-name list matches `expected_args`, raise if not.

    Guards against silent drift: if the Solidity event gains, loses, renames,
    or reorders a field, the CSV-emitting script would otherwise keep producing
    the old schema. Call once per event-consuming fetch.
    """
    for item in abi:
        if item.get("type") == "event" and item.get("name") == event_name:
            actual = [inp["name"] for inp in item["inputs"]]
            if actual != expected_args:
                raise RuntimeError(
                    f"{event_name} ABI drift: expected {expected_args}, got {actual}. "
                    f"Update the script's field mapping."
                )
            return
    raise RuntimeError(f"Event '{event_name}' not found in ABI")


def make_csv_writer(stream: TextIO, fieldnames: list[str]) -> csv.DictWriter:
    """Create a csv.DictWriter, write the header, return it."""
    writer = csv.DictWriter(stream, fieldnames=fieldnames)
    writer.writeheader()
    return writer


def dataclass_to_csv_row(row: Any) -> dict[str, Any]:
    """Convert a dataclass instance to a csv.DictWriter-friendly dict.

    `None` is rendered as an empty cell — used by rows that mix event types
    with disjoint field sets, or view calls that can revert.
    """
    return {k: ("" if v is None else v) for k, v in asdict(row).items()}
