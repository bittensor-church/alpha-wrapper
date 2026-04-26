#!/usr/bin/env python3

"""Decode `setValidators(uint256,bytes32[],uint16[])` arguments from a transaction hash."""

import argparse
import json
import sys

from common import get_web3_connection, load_abi


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tx-hash", required=True, help="Transaction hash")
    parser.add_argument("--rpc-url", required=True, help="HTTP RPC URL of the Subtensor EVM endpoint")
    args = parser.parse_args()

    w3 = get_web3_connection(args.rpc_url)
    registry = w3.eth.contract(abi=load_abi("ValidatorRegistry"))

    tx = w3.eth.get_transaction(args.tx_hash)
    func, params = registry.decode_function_input(tx["input"])
    if func.fn_name != "setValidators":
        sys.exit(f"tx {args.tx_hash} called {func.fn_name}, not setValidators")

    out = {
        "tx_hash": args.tx_hash,
        "netuid": params["netuid"],
        "hotkeys": ["0x" + h.hex() for h in params["hotkeys"]],
        "weights": list(params["weights"]),
    }
    json.dump(out, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
