#!/usr/bin/env python3

"""Print a one-row CSV summary of an AlphaVault token's on-chain state."""

import argparse
import sys

from web3.contract import Contract
from web3.exceptions import ContractLogicError

from common import (
    extract_error_name,
    get_web3_connection,
    load_abi,
    lookup_token_id,
    make_csv_writer,
)


def _validator_columns(registry: Contract | None, netuid: int) -> dict:
    """One (hotkey, weight) column pair per configured validator, plus the count."""
    cols: dict = {"validators_count": ""}
    if registry is None:
        return cols
    hotkeys, weights = registry.functions.getValidators(netuid).call()
    cols["validators_count"] = len(hotkeys)
    for i, (hotkey, weight) in enumerate(zip(hotkeys, weights)):
        cols[f"validator_{i+1}_hotkey"] = "0x" + hotkey.hex()
        cols[f"validator_{i+1}_weight"] = weight
    return cols


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault-address", required=True, help="AlphaVault contract address")
    parser.add_argument("--lens-address", required=True,
                        help="AlphaVaultLens contract address, from the same trusted source as the vault")
    parser.add_argument("--registry-address", help="Optional ValidatorRegistry address (enables validator columns)")
    parser.add_argument("--rpc-url", required=True, help="HTTP RPC URL of the Subtensor EVM endpoint")
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--token-id", type=int, help="Packed tokenId")
    target.add_argument("--netuid", type=int, help="Subnet netuid")
    args = parser.parse_args()

    w3 = get_web3_connection(args.rpc_url)
    vault = w3.eth.contract(
        address=w3.to_checksum_address(args.vault_address),
        abi=load_abi("AlphaVault"),
    )
    lens = w3.eth.contract(
        address=w3.to_checksum_address(args.lens_address),
        abi=load_abi("AlphaVaultLens"),
    )
    # A row assembled from a mismatched pair would mix one vault's supply with another's backing.
    # This catches the wrong lens, not a dishonest one: the address still has to be trusted.
    lens_vault = lens.functions.vault().call()
    if lens_vault != w3.to_checksum_address(args.vault_address):
        sys.exit(f"lens {args.lens_address} reads vault {lens_vault}, not {args.vault_address}")
    registry = None
    if args.registry_address:
        registry = w3.eth.contract(
            address=w3.to_checksum_address(args.registry_address),
            abi=load_abi("ValidatorRegistry"),
        )

    token_id = args.token_id if args.token_id is not None else lookup_token_id(vault, args.netuid)
    netuid = token_id & 0xFFFF

    try:
        share_price = lens.functions.sharePrice(token_id).call()
        share_price_error = ""
    except ContractLogicError as e:
        share_price = ""
        share_price_error = extract_error_name(e, lens.abi)

    # A token holding backing it cannot account for refuses to be valued; what it can locate is
    # still readable, and the error names why the two are not the same number.
    try:
        total_stake = lens.functions.totalStake(token_id).call()
        total_stake_error = ""
    except ContractLogicError as e:
        total_stake = lens.functions.locatedStake(token_id).call()
        total_stake_error = extract_error_name(e, lens.abi)

    row = {
        "token_id": token_id,
        "total_supply": vault.functions.totalSupply(token_id).call(),
        "total_stake": total_stake,
        "total_stake_error": total_stake_error,
        "frozen_until": lens.functions.frozenUntil(token_id).call(),
        "share_price": share_price,
        "share_price_error": share_price_error,
        "subnet_clone": vault.functions.subnetClone(token_id).call(),
        **_validator_columns(registry, netuid),
    }

    writer = make_csv_writer(sys.stdout, list(row))
    writer.writerow(row)

    print(f"Fetched state for token {token_id}", file=sys.stderr)


if __name__ == "__main__":
    main()
