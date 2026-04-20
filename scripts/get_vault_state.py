#!/usr/bin/env python3

"""
Print on-chain state of one or more AlphaVault positions, as CSV.

Token discovery (mutually exclusive - exactly one required):
    --token-ids 12345,67890        explicit packed tokenId list
    --netuids 12,42                netuids; script computes currentTokenId(netuid) for each
    --from-events                  scan SubnetProxyCreated logs in [--block-start, --block-end]

Optional:
    --registry-address ADDR        also fetch ValidatorRegistry.getValidators(netuid)
                                   per token; populates validator_* columns

For each token: totalSupply, totalStake, sharePrice (revert-safe), subnetClone.

With --netuids, any netuid whose currentTokenId() reverts (e.g. SubnetNotRegistered)
is logged to stderr and skipped from the output.
"""

import argparse
import sys
from dataclasses import dataclass, fields

from web3 import Web3
from web3.contract import Contract
from web3.exceptions import ContractLogicError

from common import (
    SUBNET_PROXY_CREATED_ARGS,
    SUBNET_PROXY_CREATED_SIG,
    assert_event_abi,
    dataclass_to_csv_row,
    get_web3_connection,
    load_abi,
    make_csv_writer,
)


@dataclass
class VaultStateRow:
    token_id: int
    total_supply: int
    total_stake: int
    share_price: int | None
    share_price_error: str
    subnet_clone: str
    validators_count: int | None
    validator_1_hotkey: str
    validator_1_weight: int | None
    validator_2_hotkey: str
    validator_2_weight: int | None
    validator_3_hotkey: str
    validator_3_weight: int | None


FIELDNAMES = [f.name for f in fields(VaultStateRow)]

KNOWN_VAULT_REVERT_ERRORS = (
    "SubnetInDissolutionBlackoutPeriod",
    "SubnetDissolved",
    "NoSharesOutstanding",
    "SubnetNotRegistered",
)


def _extract_error_name(exc: Exception) -> str:
    msg = str(exc)
    for name in KNOWN_VAULT_REVERT_ERRORS:
        if name in msg:
            return name
    return type(exc).__name__


def _resolve_token_ids_from_netuids(vault: Contract, netuids: list[int]) -> list[int]:
    token_ids: list[int] = []
    for netuid in netuids:
        try:
            token_ids.append(vault.functions.currentTokenId(netuid).call())
        except ContractLogicError as e:
            print(
                f"Warning: skipping netuid {netuid}: {_extract_error_name(e)}",
                file=sys.stderr,
            )
    return token_ids


def _resolve_token_ids_from_events(
    w3: Web3,
    vault: Contract,
    block_start: int,
    block_end: int,
) -> list[int]:
    assert_event_abi(vault.abi, "SubnetProxyCreated", SUBNET_PROXY_CREATED_ARGS)
    logs = w3.eth.get_logs({
        "fromBlock": block_start,
        "toBlock": block_end,
        "address": vault.address,
        "topics": [w3.keccak(text=SUBNET_PROXY_CREATED_SIG).hex()],
    })
    token_ids = (
        vault.events.SubnetProxyCreated().process_log(log)["args"]["tokenId"]
        for log in logs
    )
    return list(dict.fromkeys(token_ids))


def _validators_for(
    registry: Contract | None,
    netuid: int,
) -> tuple[int | None, list[str], list[int | None]]:
    """Return (count, [hotkey_1, hotkey_2, hotkey_3], [weight_1, weight_2, weight_3]).

    Unused slots are empty string / None. count is None if no registry was given.
    """
    if registry is None:
        return None, ["", "", ""], [None, None, None]
    hotkeys, weights, count = registry.functions.getValidators(netuid).call()
    hotkey_slots = ["", "", ""]
    weight_slots: list[int | None] = [None, None, None]
    for i in range(min(count, 3)):
        hotkey_slots[i] = "0x" + hotkeys[i].hex()
        weight_slots[i] = weights[i]
    return count, hotkey_slots, weight_slots


def fetch_state(
    vault: Contract,
    registry: Contract | None,
    token_ids: list[int],
) -> list[VaultStateRow]:
    rows = []
    for token_id in token_ids:
        netuid = token_id & 0xFFFF

        total_supply = vault.functions.totalSupply(token_id).call()
        total_stake = vault.functions.totalStake(token_id).call()
        subnet_clone = vault.functions.subnetClone(token_id).call()

        try:
            share_price = vault.functions.sharePrice(token_id).call()
            share_price_error = ""
        except ContractLogicError as e:
            share_price = None
            share_price_error = _extract_error_name(e)

        validators_count, hotkey_slots, weight_slots = _validators_for(registry, netuid)

        rows.append(VaultStateRow(
            token_id=token_id,
            total_supply=total_supply,
            total_stake=total_stake,
            share_price=share_price,
            share_price_error=share_price_error,
            subnet_clone=subnet_clone,
            validators_count=validators_count,
            validator_1_hotkey=hotkey_slots[0],
            validator_1_weight=weight_slots[0],
            validator_2_hotkey=hotkey_slots[1],
            validator_2_weight=weight_slots[1],
            validator_3_hotkey=hotkey_slots[2],
            validator_3_weight=weight_slots[2],
        ))

    return rows


def _parse_int_list(s: str) -> list[int]:
    return [int(x.strip()) for x in s.split(",") if x.strip()]


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--vault-address", required=True, help="AlphaVault contract address")
    parser.add_argument("--registry-address", help="Optional ValidatorRegistry address (enables validator columns)")
    parser.add_argument("--rpc-url", required=True, help="HTTP RPC URL of the Subtensor EVM endpoint")

    discovery = parser.add_mutually_exclusive_group(required=True)
    discovery.add_argument("--token-ids", help="Comma-separated packed tokenIds (e.g. 12345,67890)")
    discovery.add_argument("--netuids", help="Comma-separated netuids; resolved via currentTokenId()")
    discovery.add_argument(
        "--from-events",
        action="store_true",
        help="Discover tokenIds from SubnetProxyCreated logs (requires --block-start/--block-end)",
    )

    parser.add_argument("--block-start", type=int, help="Starting block (inclusive); required with --from-events")
    parser.add_argument("--block-end", type=int, help="Ending block (inclusive); required with --from-events")
    args = parser.parse_args()

    if args.from_events and (args.block_start is None or args.block_end is None):
        parser.error("--from-events requires --block-start and --block-end")

    w3 = get_web3_connection(args.rpc_url)
    vault = w3.eth.contract(
        address=w3.to_checksum_address(args.vault_address),
        abi=load_abi("AlphaVault"),
    )
    registry = None
    if args.registry_address:
        registry = w3.eth.contract(
            address=w3.to_checksum_address(args.registry_address),
            abi=load_abi("ValidatorRegistry"),
        )

    if args.token_ids:
        token_ids = _parse_int_list(args.token_ids)
    elif args.netuids:
        token_ids = _resolve_token_ids_from_netuids(vault, _parse_int_list(args.netuids))
    else:
        token_ids = _resolve_token_ids_from_events(w3, vault, args.block_start, args.block_end)

    rows = fetch_state(vault, registry, token_ids)

    writer = make_csv_writer(sys.stdout, FIELDNAMES)
    for row in rows:
        writer.writerow(dataclass_to_csv_row(row))

    print(f"Fetched state for {len(rows)} tokens", file=sys.stderr)


if __name__ == "__main__":
    main()
