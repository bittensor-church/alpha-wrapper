"""Substrate extrinsics driving the localnet, signed by the dev Alice key.

Each function opens a fresh connection, submits one extrinsic, and waits for
inclusion. Failures raise ExtrinsicError carrying the chain's decoded module
error (e.g. its name), which negative tests assert on.

substrateinterface is imported lazily so the pure-Python helpers in this
package stay usable without it installed.
"""
import time

from . import config


class ExtrinsicError(RuntimeError):
    """A submitted extrinsic failed; str(error) carries the decoded module error."""


def _connect(chain_endpoint: str):
    from substrateinterface import Keypair, SubstrateInterface

    substrate = SubstrateInterface(url=chain_endpoint)
    alice = Keypair.create_from_uri("//Alice")
    return substrate, alice


def _submit(substrate, alice, call) -> str:
    """Sign `call` as Alice, wait for inclusion, and return the block hash."""
    extrinsic = substrate.create_signed_extrinsic(call=call, keypair=alice)
    receipt = substrate.submit_extrinsic(extrinsic, wait_for_inclusion=True)
    if not receipt.is_success:
        # error_message is the metadata-decoded module error, e.g.
        # {'type': 'Module', 'name': 'TransferDisallowed', ...} - callers match the name.
        raise ExtrinsicError(str(receipt.error_message))
    return receipt.block_hash


def _submit_subtensor_call(chain_endpoint: str, call_function: str, call_params: dict) -> str:
    substrate, alice = _connect(chain_endpoint)
    try:
        call = substrate.compose_call(
            call_module="SubtensorModule",
            call_function=call_function,
            call_params=call_params,
        )
    except ValueError as error:
        raise ExtrinsicError(
            f"runtime has no SubtensorModule.{call_function}: {error}"
        ) from error
    return _submit(substrate, alice, call)


def _compose_sudo_call(substrate, inner_module: str, inner_function: str, call_params: dict):
    inner = substrate.compose_call(
        call_module=inner_module,
        call_function=inner_function,
        call_params=call_params,
    )
    return substrate.compose_call(
        call_module="Sudo",
        call_function="sudo",
        call_params={"call": inner},
    )


def transfer_stake(
    dest_ss58: str, hotkey_ss58: str, netuid: int, alpha_amount: int,
    *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    return _submit_subtensor_call(chain_endpoint, "transfer_stake", {
        "destination_coldkey": dest_ss58,
        "hotkey": hotkey_ss58,
        "origin_netuid": netuid,
        "destination_netuid": netuid,
        "alpha_amount": alpha_amount,
    })


def add_stake(
    hotkey_ss58: str, netuid: int, amount_rao: int,
    *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    return _submit_subtensor_call(chain_endpoint, "add_stake", {
        "hotkey": hotkey_ss58,
        "netuid": netuid,
        "amount_staked": amount_rao,
    })


def remove_stake(
    hotkey_ss58: str, netuid: int, amount_rao: int,
    *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Sell `amount_rao` alpha back to the pool for TAO."""
    return _submit_subtensor_call(chain_endpoint, "remove_stake", {
        "hotkey": hotkey_ss58,
        "netuid": netuid,
        "amount_unstaked": amount_rao,
    })


def lock_stake(
    hotkey_ss58: str, netuid: int, amount_rao: int,
    *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Lock `amount_rao` alpha to the given conviction hotkey."""
    return _submit_subtensor_call(chain_endpoint, "lock_stake", {
        "hotkey": hotkey_ss58,
        "netuid": netuid,
        "amount": amount_rao,
    })


def get_lock(
    coldkey_ss58: str, netuid: int, hotkey_ss58: str,
    *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> int:
    """locked_mass of the (coldkey, netuid, hotkey) lock in RAW alpha (0 when none)."""
    from substrateinterface import SubstrateInterface

    substrate = SubstrateInterface(url=chain_endpoint)
    result = substrate.query("SubtensorModule", "Lock", [coldkey_ss58, netuid, hotkey_ss58])
    value = result.value if result is not None else None
    return value.get("locked_mass", 0) if isinstance(value, dict) else 0


def toggle_transfer(
    netuid: int, enabled: bool, *, attempts: int = 10,
    chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Flip a subnet's alpha transfer toggle via Sudo. With transfers off, the
    staking precompile's transferStake reverts TransferDisallowed while
    removeStake/moveStake keep working. Relies on the admin freeze window being
    disabled first (see set_admin_freeze_window); retries across blocks as a
    safety net."""
    substrate, alice = _connect(chain_endpoint)
    call = _compose_sudo_call(
        substrate, "AdminUtils", "sudo_set_toggle_transfer",
        {"netuid": netuid, "toggle": enabled},
    )
    for attempt in range(attempts):
        extrinsic = substrate.create_signed_extrinsic(call=call, keypair=alice)
        receipt = substrate.submit_extrinsic(extrinsic, wait_for_inclusion=True)
        # Sudo.sudo reports success even when the inner call reverts, so trust the
        # chain state rather than the receipt: read the toggle back and check it stuck.
        current = substrate.query("SubtensorModule", "TransferToggle", [netuid]).value
        if current == enabled:
            return receipt.block_hash
        if attempt != attempts - 1:
            time.sleep(6)
    raise ExtrinsicError(f"toggle_transfer netuid={netuid} did not reach toggle={enabled}")


def set_admin_freeze_window(
    window: int, *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Set the global admin freeze window via Sudo. On the fast-runtime localnet
    the window equals the tempo, so owner/root hyperparameter writes are only
    accepted near each subnet epoch boundary and otherwise silently miss. The
    bootstrap sets the window to 0 so those sudo writes apply on the first try."""
    substrate, alice = _connect(chain_endpoint)
    call = _compose_sudo_call(
        substrate, "AdminUtils", "sudo_set_admin_freeze_window", {"window": window},
    )
    extrinsic = substrate.create_signed_extrinsic(call=call, keypair=alice)
    receipt = substrate.submit_extrinsic(extrinsic, wait_for_inclusion=True)
    current = substrate.query("SubtensorModule", "AdminFreezeWindow", []).value
    if current != window:
        raise ExtrinsicError(
            f"set_admin_freeze_window did not reach window={window} (now {current})"
        )
    return receipt.block_hash


def dissolve_network(
    netuid: int, *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Dissolve (deregister) a subnet via Sudo. The chain converts every staker's
    alpha into a pro-rata share of the subnet's TAO reserve, credits it to their
    coldkey, and removes the subnet."""
    substrate, alice = _connect(chain_endpoint)
    call = _compose_sudo_call(
        substrate, "SubtensorModule", "root_dissolve_network", {"netuid": netuid},
    )
    extrinsic = substrate.create_signed_extrinsic(call=call, keypair=alice)
    receipt = substrate.submit_extrinsic(extrinsic, wait_for_inclusion=True)
    # Sudo.sudo reports success even when the inner call reverts, so trust chain state.
    if substrate.query("SubtensorModule", "NetworksAdded", [netuid]).value:
        raise ExtrinsicError(f"dissolve_network netuid={netuid} left the subnet registered")
    return receipt.block_hash
