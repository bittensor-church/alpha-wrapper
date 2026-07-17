"""Typed subprocess wrappers over cast/forge/btcli.

One run() chokepoint; everything else is a thin typed shim. cast output is
parsed by taking the first whitespace token per line, because cast appends a
bracketed scientific suffix to numeric values.
"""
import json
import os
import subprocess
from functools import lru_cache
from typing import List, Optional

from . import config


class ChainError(RuntimeError):
    pass


def _first_token(line: str) -> str:
    return line.strip().split()[0] if line.strip() else ""


def _tokens_per_line(raw: str) -> List[str]:
    return [_first_token(line) for line in raw.splitlines() if line.strip()]


def _array_items(raw: str) -> List[str]:
    inner = raw.strip().strip("[]").strip()
    return [_first_token(item) for item in inner.split(",")] if inner else []


def run(
    cmd: List[str], *, check: bool = True, capture: bool = True,
    input: Optional[str] = None,
) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    # Subtensor's EVM omits mixHash from eth_getBlockByNumber, so forge/cast's
    # receipt-wait block poller logs a benign deserialization ERROR per broadcast.
    # Silence that module; keep error-level logging otherwise.
    env.setdefault("RUST_LOG", "error,alloy_provider::blocks=off")
    completed = subprocess.run(
        cmd, capture_output=capture, text=True, env=env, input=input,
    )
    if check and completed.returncode != 0:
        raise ChainError(
            f"command failed ({completed.returncode}): {' '.join(cmd)}\n"
            f"stdout: {completed.stdout}\nstderr: {completed.stderr}"
        )
    return completed


def _cast_call_stdout(to: str, signature: str, *args, rpc: str) -> str:
    return run(["cast", "call", to, signature, *[str(a) for a in args], "--rpc-url", rpc]).stdout


def cast_call(to: str, signature: str, *args, rpc: str = config.RPC_URL) -> str:
    return _first_token(_cast_call_stdout(to, signature, *args, rpc=rpc))


def cast_call_lines(to: str, signature: str, *args, rpc: str = config.RPC_URL) -> List[str]:
    return _tokens_per_line(_cast_call_stdout(to, signature, *args, rpc=rpc))


def cast_call_array(to: str, signature: str, *args, rpc: str = config.RPC_URL) -> List[str]:
    """Elements of an array return like "[0x..., 0x...]"."""
    return _array_items(_cast_call_stdout(to, signature, *args, rpc=rpc))


def cast_send(
    to: str, signature: str, *args,
    private_key: str, gas_limit: int, rpc: str = config.RPC_URL,
) -> dict:
    completed = run(
        ["cast", "send", to, signature, *[str(a) for a in args],
         "--private-key", private_key, "--rpc-url", rpc,
         *config.EVM_TX_FLAGS, "--gas-limit", str(gas_limit), "--json"],
        check=False,
    )
    try:
        return json.loads(completed.stdout)
    except (json.JSONDecodeError, ValueError):
        # A revert / send failure leaves non-JSON on stdout+stderr; surface it as
        # a receipt without a success status so receipt_ok() returns False.
        return {"status": "0x0", "raw": completed.stdout + completed.stderr}


def receipt_ok(receipt: dict) -> bool:
    return receipt.get("status") == "0x1"


def receipt_gas_used(receipt: dict) -> Optional[int]:
    """gasUsed as an int, or None when the receipt carries none (call sites
    validate, so a bad receipt cannot pass a gas assertion vacuously)."""
    value = receipt.get("gasUsed")
    if isinstance(value, int):
        return value
    try:
        return int(str(value), 0)
    except (TypeError, ValueError):
        return None


def forge_create(
    contract: str, *, private_key: str,
    constructor_args: Optional[List[str]] = None, rpc: str = config.RPC_URL,
) -> str:
    cmd = ["forge", "create", contract, "--private-key", private_key, "--rpc-url", rpc,
           *config.FORGE_CREATE_FLAGS, "--json"]
    if constructor_args:
        cmd += ["--constructor-args", *[str(a) for a in constructor_args]]
    completed = run(cmd)
    return json.loads(completed.stdout)["deployedTo"]


@lru_cache(maxsize=None)
def cast_sig(signature: str) -> str:
    return run(["cast", "sig", signature]).stdout.strip()


def cast_block_number(rpc: str = config.RPC_URL) -> int:
    return int(run(["cast", "block-number", "--rpc-url", rpc]).stdout.strip())


def cast_chain_id(rpc: str = config.RPC_URL) -> int:
    return int(run(["cast", "chain-id", "--rpc-url", rpc]).stdout.strip())


def cast_balance_ether(address: str, rpc: str = config.RPC_URL) -> float:
    return float(run(["cast", "balance", address, "--rpc-url", rpc, "--ether"]).stdout.strip())


def cast_balance_wei(address: str, rpc: str = config.RPC_URL) -> int:
    """Native balance in raw wei (int) -- the balance form all deltas must use."""
    return int(run(["cast", "balance", address, "--rpc-url", rpc]).stdout.strip())


def cast_code(address: str, rpc: str = config.RPC_URL) -> str:
    return run(["cast", "code", address, "--rpc-url", rpc]).stdout.strip()


def cast_wallet_address(private_key: str) -> str:
    return run(["cast", "wallet", "address", private_key]).stdout.strip()


def btcli(
    args: List[str], *, input: Optional[str] = None, check: bool = False,
) -> subprocess.CompletedProcess:
    """Run btcli against the localnet. Callers that read the output back (netuid
    extraction, registration grep, wallet files) keep check=False; steps with no
    read-back (funding transfers, subnet start, sudo set) pass check=True so a
    failure aborts the run at its cause, not at a confusing later step."""
    return run(["btcli", *args, "--network", config.CHAIN_ENDPOINT], check=check, input=input)
