#!/usr/bin/env python3

"""
Helper subcommands for the localnet-e2e tests.

Each subcommand prints its result to stdout; errors go to stderr and exit 1.

Subcommands:
    h160_to_substrate_b32 <0x-h160>
        Map an H160 EVM address to the substrate AccountId (32-byte hex) via
        Frontier's HashedAddressMapping (`blake2b("evm:" + h160)`). This is the
        coldkey the staking precompile sees for an EVM-owned clone.

    h160_to_ss58 <0x-h160>
        Same mapping, but encoded as SS58 with network prefix 42 (Bittensor).

    transfer_stake --chain-endpoint URL --dest-ss58 ... --hotkey-ss58 ...
                   --netuid N --alpha-amount RAW
        Submit `SubtensorModule.transfer_stake` signed by //Alice. Works around
        btcli's SignedExtension mismatch with recent subtensor builds.

    set_validators --rpc-url URL --registry ADDR --signer-pk PK [--signer-pk PK ...]
                   --netuid N --hotkeys HK1,HK2,... --weights W1,W2,...
                   [--deadline-secs N]
        Build an EIP-712 WeightAttestation, sign it with every `--signer-pk`, sort
        signatures by recovered signer address ascending (contract requirement),
        and submit `updateValidators(att, sigs[])` to the ValidatorRegistry.
        The first signer-pk also pays for the transaction.

    toggle_transfer --chain-endpoint URL --netuid N --enabled true|false
                    [--attempts N]
        Flip a subnet's `TransferToggle` by submitting
        `Sudo.sudo(AdminUtils.sudo_set_toggle_transfer(netuid, toggle))` as //Alice
        (the dev sudo/root key). With transfers off, the staking precompile's
        `transferStake` reverts `TransferDisallowed` while `removeStake`/`moveStake`
        keep working. Retries across blocks because the call is rejected inside the
        per-tempo admin freeze window near each epoch boundary.
"""

import argparse
import hashlib
import sys
import time


SS58_ALPHABET = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def h160_to_account_id(h160_hex: str) -> bytes:
    h160 = bytes.fromhex(h160_hex.removeprefix("0x"))
    return hashlib.blake2b(b"evm:" + h160, digest_size=32).digest()


def h160_to_substrate_b32(h160_hex: str) -> str:
    return "0x" + h160_to_account_id(h160_hex).hex()


def h160_to_ss58(h160_hex: str, prefix: int = 42) -> str:
    account_id = h160_to_account_id(h160_hex)
    if prefix < 64:
        prefix_bytes = bytes([prefix])
    else:
        prefix_bytes = bytes([((prefix & 0xFC) >> 2) | 0x40, (prefix >> 8) | ((prefix & 3) << 6)])
    checksum = hashlib.blake2b(b"SS58PRE" + prefix_bytes + account_id, digest_size=64).digest()[:2]
    payload = prefix_bytes + account_id + checksum

    n = int.from_bytes(payload, "big")
    result = b""
    while n > 0:
        n, rem = divmod(n, 58)
        result = bytes([SS58_ALPHABET[rem]]) + result
    for byte in payload:
        if byte == 0:
            result = bytes([SS58_ALPHABET[0]]) + result
        else:
            break
    return result.decode()


def transfer_stake(
    chain_endpoint: str,
    dest_ss58: str,
    hotkey_ss58: str,
    netuid: int,
    alpha_amount: int,
) -> None:
    from substrateinterface import Keypair, SubstrateInterface

    sub = SubstrateInterface(url=chain_endpoint)
    alice = Keypair.create_from_uri("//Alice")
    call = sub.compose_call(
        call_module="SubtensorModule",
        call_function="transfer_stake",
        call_params={
            "destination_coldkey": dest_ss58,
            "hotkey": hotkey_ss58,
            "origin_netuid": netuid,
            "destination_netuid": netuid,
            "alpha_amount": alpha_amount,
        },
    )
    extrinsic = sub.create_signed_extrinsic(call=call, keypair=alice)
    receipt = sub.submit_extrinsic(extrinsic, wait_for_inclusion=True)
    if not receipt.is_success:
        print(f"FAIL: {receipt.error_message}", file=sys.stderr)
        sys.exit(1)
    print(f"ok block={receipt.block_hash}")


def _sudo_dispatch_error(receipt) -> "str | None":
    """Return the inner dispatch error of a `Sudo.sudo` receipt, or None on success.

    `submit_extrinsic` reports the OUTER `Sudo.sudo` call as successful even when the
    wrapped call reverts — the inner `DispatchResult` rides in the `Sudo.Sudid` event,
    serialized as `{'sudo_result': {'Ok': ...}}` or `{'sudo_result': {'Err': ...}}`.
    """
    for event in receipt.triggered_events:
        value = event.value
        record = value.get("event", value) if isinstance(value, dict) else {}
        if record.get("event_id") != "Sudid":
            continue
        attributes = record.get("attributes")
        # Prefer the structured `sudo_result` ({'Ok': ...} / {'Err': ...}); fall back to a
        # string scan only if the event shape differs across substrate-interface versions.
        result = attributes.get("sudo_result") if isinstance(attributes, dict) else attributes
        if isinstance(result, dict) and "Err" in result:
            return str(result["Err"])
        if not isinstance(result, dict) and ("'Err'" in str(attributes) or '"Err"' in str(attributes)):
            return str(attributes)
    return None


def toggle_transfer(
    chain_endpoint: str,
    netuid: int,
    enabled: bool,
    attempts: int,
) -> None:
    from substrateinterface import Keypair, SubstrateInterface

    sub = SubstrateInterface(url=chain_endpoint)
    alice = Keypair.create_from_uri("//Alice")
    inner = sub.compose_call(
        call_module="AdminUtils",
        call_function="sudo_set_toggle_transfer",
        call_params={"netuid": netuid, "toggle": enabled},
    )
    call = sub.compose_call(
        call_module="Sudo",
        call_function="sudo",
        call_params={"call": inner},
    )

    last_err = "unknown error"
    for attempt in range(attempts):
        extrinsic = sub.create_signed_extrinsic(call=call, keypair=alice)
        receipt = sub.submit_extrinsic(extrinsic, wait_for_inclusion=True)
        if not receipt.is_success:
            last_err = receipt.error_message
        else:
            inner_err = _sudo_dispatch_error(receipt)
            if inner_err is None:
                print(f"ok netuid={netuid} toggle={enabled} block={receipt.block_hash}")
                return
            last_err = inner_err
        # Rejected inside the per-tempo admin freeze window; clears within a block or two.
        if attempt != attempts - 1:
            time.sleep(6)

    print(f"FAIL: toggle_transfer netuid={netuid} -> {last_err}", file=sys.stderr)
    sys.exit(1)


def set_validators(
    rpc_url: str,
    registry: str,
    signer_pks: list[str],
    netuid: int,
    hotkeys: list[str],
    weights: list[int],
    deadline_secs: int,
) -> None:
    from eth_account import Account
    from web3 import Web3

    from common import load_abi

    if len(hotkeys) != len(weights):
        print("hotkeys/weights length mismatch", file=sys.stderr)
        sys.exit(1)
    if sum(weights) != 10_000:
        print(f"weights must sum to 10000, got {sum(weights)}", file=sys.stderr)
        sys.exit(1)

    w3 = Web3(Web3.HTTPProvider(rpc_url))
    if not w3.is_connected():
        print(f"could not connect to {rpc_url}", file=sys.stderr)
        sys.exit(1)

    registry = Web3.to_checksum_address(registry)

    chain_id = w3.eth.chain_id
    registry_contract = w3.eth.contract(address=registry, abi=load_abi("ValidatorRegistry"))

    current_nonce = registry_contract.functions.nonces(netuid).call()
    next_nonce = current_nonce + 1
    deadline = int(time.time()) + deadline_secs

    hotkey_bytes = [bytes.fromhex(hk.removeprefix("0x")) for hk in hotkeys]

    typed_data = {
        "types": {
            "EIP712Domain": [
                {"name": "name", "type": "string"},
                {"name": "version", "type": "string"},
                {"name": "chainId", "type": "uint256"},
                {"name": "verifyingContract", "type": "address"},
            ],
            "WeightAttestation": [
                {"name": "netuid", "type": "uint256"},
                {"name": "hotkeys", "type": "bytes32[]"},
                {"name": "weights", "type": "uint256[]"},
                {"name": "nonce", "type": "uint256"},
                {"name": "deadline", "type": "uint256"},
            ],
        },
        "primaryType": "WeightAttestation",
        "domain": {
            "name": "AlphaVault ValidatorRegistry",
            "version": "1",
            "chainId": chain_id,
            "verifyingContract": registry,
        },
        "message": {
            "netuid": netuid,
            "hotkeys": hotkey_bytes,
            "weights": weights,
            "nonce": next_nonce,
            "deadline": deadline,
        },
    }

    # Sign with every key, then sort by recovered signer address ascending (contract requirement).
    pairs = []
    for pk in signer_pks:
        signer = Account.from_key(pk)
        signed = Account.sign_typed_data(pk, full_message=typed_data)
        pairs.append((signer.address.lower(), bytes(signed.signature)))
    pairs.sort(key=lambda p: p[0])
    sigs = [sig for _, sig in pairs]

    # First-listed signer pays the transaction.
    submitter_pk = signer_pks[0]
    submitter = Account.from_key(submitter_pk)

    att_tuple = (netuid, hotkey_bytes, weights, next_nonce, deadline)
    tx_nonce = w3.eth.get_transaction_count(submitter.address)
    tx = registry_contract.functions.updateValidators(att_tuple, sigs).build_transaction(
        {
            "from": submitter.address,
            "nonce": tx_nonce,
            "gas": 500_000,
            "gasPrice": w3.to_wei(10, "gwei"),
            "chainId": chain_id,
        }
    )
    signed_tx = w3.eth.account.sign_transaction(tx, submitter_pk)
    tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
    if receipt.status != 1:
        print(f"updateValidators failed (tx {tx_hash.hex()})", file=sys.stderr)
        sys.exit(1)
    print(f"ok netuid={netuid} nonce={next_nonce} signers={len(sigs)} tx={tx_hash.hex()}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("h160_to_substrate_b32")
    p.add_argument("h160")

    p = sub.add_parser("h160_to_ss58")
    p.add_argument("h160")

    p = sub.add_parser("transfer_stake")
    p.add_argument("--chain-endpoint", required=True)
    p.add_argument("--dest-ss58", required=True)
    p.add_argument("--hotkey-ss58", required=True)
    p.add_argument("--netuid", required=True, type=int)
    p.add_argument("--alpha-amount", required=True, type=int)

    p = sub.add_parser("toggle_transfer")
    p.add_argument("--chain-endpoint", required=True)
    p.add_argument("--netuid", required=True, type=int)
    p.add_argument("--enabled", required=True, choices=["true", "false"],
                   help="Whether alpha transfer_stake is allowed on the subnet")
    p.add_argument("--attempts", type=int, default=10)

    p = sub.add_parser("set_validators")
    p.add_argument("--rpc-url", required=True)
    p.add_argument("--registry", required=True)
    p.add_argument("--signer-pk", required=True, action="append", dest="signer_pks",
                   help="Repeat for each signer. First listed pays the transaction.")
    p.add_argument("--netuid", required=True, type=int)
    p.add_argument("--hotkeys", required=True, help="Comma-separated bytes32 hex hotkeys")
    p.add_argument("--weights", required=True, help="Comma-separated BPS weights summing to 10000")
    p.add_argument("--deadline-secs", type=int, default=3600)

    args = parser.parse_args()

    if args.cmd == "h160_to_substrate_b32":
        print(h160_to_substrate_b32(args.h160))
    elif args.cmd == "h160_to_ss58":
        print(h160_to_ss58(args.h160))
    elif args.cmd == "transfer_stake":
        transfer_stake(
            chain_endpoint=args.chain_endpoint,
            dest_ss58=args.dest_ss58,
            hotkey_ss58=args.hotkey_ss58,
            netuid=args.netuid,
            alpha_amount=args.alpha_amount,
        )
    elif args.cmd == "toggle_transfer":
        toggle_transfer(
            chain_endpoint=args.chain_endpoint,
            netuid=args.netuid,
            enabled=(args.enabled == "true"),
            attempts=args.attempts,
        )
    elif args.cmd == "set_validators":
        set_validators(
            rpc_url=args.rpc_url,
            registry=args.registry,
            signer_pks=args.signer_pks,
            netuid=args.netuid,
            hotkeys=args.hotkeys.split(","),
            weights=[int(w) for w in args.weights.split(",")],
            deadline_secs=args.deadline_secs,
        )


if __name__ == "__main__":
    main()
