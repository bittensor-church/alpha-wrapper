"""EIP-712 validator-set attestations for the ValidatorRegistry.

Builds a WeightAttestation, signs it with every listed signer key, sorts the
signatures by recovered signer address ascending (contract requirement), and
submits updateValidators(att, sigs[]). The first signer key also pays for the
transaction.
"""
import pathlib
import sys
from typing import List

from . import config

_SCRIPTS_DIR = pathlib.Path(__file__).resolve().parents[2] / "scripts"


class ValidatorUpdateError(RuntimeError):
    pass


def set_validators(
    registry_address: str,
    signer_private_keys: List[str],
    netuid: int,
    hotkeys: List[str],
    weights: List[int],
    *, rpc_url: str = config.RPC_URL,
) -> str:
    from eth_account import Account
    from web3 import Web3

    # The shared ABI loader and connection helper live with the observability
    # tools in scripts/.
    sys.path.insert(0, str(_SCRIPTS_DIR))
    from common import get_web3_connection, load_abi

    if len(hotkeys) != len(weights):
        raise ValidatorUpdateError("hotkeys/weights length mismatch")
    if sum(weights) != 10_000:
        raise ValidatorUpdateError(f"weights must sum to 10000, got {sum(weights)}")

    w3 = get_web3_connection(rpc_url)
    registry_address = Web3.to_checksum_address(registry_address)
    chain_id = w3.eth.chain_id
    registry_contract = w3.eth.contract(address=registry_address, abi=load_abi("ValidatorRegistry"))

    current_nonce = registry_contract.functions.nonces(netuid).call()
    next_nonce = current_nonce + 1

    hotkey_bytes = [bytes.fromhex(hotkey.removeprefix("0x")) for hotkey in hotkeys]

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
            ],
        },
        "primaryType": "WeightAttestation",
        "domain": {
            "name": "AlphaVault ValidatorRegistry",
            "version": "1",
            "chainId": chain_id,
            "verifyingContract": registry_address,
        },
        "message": {
            "netuid": netuid,
            "hotkeys": hotkey_bytes,
            "weights": weights,
            "nonce": next_nonce,
        },
    }

    pairs = []
    for private_key in signer_private_keys:
        signer = Account.from_key(private_key)
        signed = Account.sign_typed_data(private_key, full_message=typed_data)
        pairs.append((signer.address.lower(), bytes(signed.signature)))
    pairs.sort(key=lambda pair: pair[0])
    signatures = [signature for _, signature in pairs]

    submitter_private_key = signer_private_keys[0]
    submitter = Account.from_key(submitter_private_key)

    attestation_tuple = (netuid, hotkey_bytes, weights, next_nonce)
    transaction_nonce = w3.eth.get_transaction_count(submitter.address)
    transaction = registry_contract.functions.updateValidators(
        attestation_tuple, signatures
    ).build_transaction(
        {
            "from": submitter.address,
            "nonce": transaction_nonce,
            "gasPrice": w3.to_wei(10, "gwei"),
            "chainId": chain_id,
        }
    )
    signed_transaction = w3.eth.account.sign_transaction(transaction, submitter_private_key)
    transaction_hash = w3.eth.send_raw_transaction(signed_transaction.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(transaction_hash, timeout=60)
    if receipt.status != 1:
        raise ValidatorUpdateError(f"updateValidators failed (tx {transaction_hash.hex()})")
    return transaction_hash.hex()
