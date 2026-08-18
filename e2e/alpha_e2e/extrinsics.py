"""Substrate extrinsics driving the localnet, signed by the dev Alice key.

Each function opens a fresh connection, submits one extrinsic, and waits for
inclusion. Failures raise ExtrinsicError carrying the chain's decoded module
error (e.g. its name), which negative tests assert on.

The bittensor SDK is imported lazily so the pure-Python helpers in this
package stay usable without it installed.
"""
import time
from contextlib import contextmanager

from . import config


class ExtrinsicError(RuntimeError):
    """A submitted extrinsic failed; str(error) carries the decoded module error."""


def _sdk():
    """The bittensor SDK: its client, its generated call builders (`calls`) and
    storage descriptors (`storage`), and the key primitives in `sp_core`."""
    import bittensor

    return bittensor


@contextmanager
def _connect(chain_endpoint: str):
    """A client pinned to `chain_endpoint`. Both endpoint pools are left empty so
    an unreachable localnet fails the test instead of rotating the suite onto a
    public node."""
    with _sdk().SyncClient(
        chain_endpoint, fallback_endpoints=[], archive_endpoints=[]
    ) as client:
        yield client


def _failure(result) -> str:
    """The failed dispatch, named: the SDK reports the error's documentation text,
    while callers match on the error name (e.g. TransferDisallowed)."""
    error = result.error
    if error is None or not error.name:
        return result.message
    return f"{error.name}: {error.message}"


def _submit(client, call, signer_uri: str = "//Alice") -> str:
    """Sign `call`, wait for inclusion, and return the block hash. Defaults to
    Alice, who owns the registered validator hotkeys; pass another dev URI to
    prove a call is open to signers with no relationship to the subject."""
    signer = _sdk().sp_core.Keypair.create_from_uri(signer_uri)
    result = client.submit_call(call, signer, wait_for_finalization=False)
    if not result.success:
        raise ExtrinsicError(_failure(result))
    return result.block_hash


def _sudo(client, call):
    """Wrap `call` in root origin. The inner call is encoded against the runtime
    first, because sudo carries an encoded call rather than a builder."""
    return _sdk().calls.Sudo.sudo(call=client.compose(call))


def transfer_stake(
    dest_ss58: str, hotkey_ss58: str, netuid: int, alpha_amount: int,
    *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    with _connect(chain_endpoint) as client:
        return _submit(client, _sdk().calls.SubtensorModule.transfer_stake(
            destination_coldkey=dest_ss58,
            hotkey=hotkey_ss58,
            origin_netuid=netuid,
            destination_netuid=netuid,
            alpha_amount=alpha_amount,
        ))


def add_stake(
    hotkey_ss58: str, netuid: int, amount_rao: int,
    *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    with _connect(chain_endpoint) as client:
        return _submit(client, _sdk().calls.SubtensorModule.add_stake(
            hotkey=hotkey_ss58, netuid=netuid, amount_staked=amount_rao,
        ))


def remove_stake(
    hotkey_ss58: str, netuid: int, amount_rao: int,
    *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Sell `amount_rao` alpha back to the pool for TAO."""
    with _connect(chain_endpoint) as client:
        return _submit(client, _sdk().calls.SubtensorModule.remove_stake(
            hotkey=hotkey_ss58, netuid=netuid, amount_unstaked=amount_rao,
        ))


def lock_stake(
    hotkey_ss58: str, netuid: int, amount_rao: int,
    *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Lock `amount_rao` alpha to the given conviction hotkey."""
    with _connect(chain_endpoint) as client:
        return _submit(client, _sdk().calls.SubtensorModule.lock_stake(
            hotkey=hotkey_ss58, netuid=netuid, amount=amount_rao,
        ))


def burned_register(
    hotkey_ss58: str, netuid: int, *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Register a hotkey on a subnet, paying the recycle cost from Alice's balance.

    Submitted as a plain call rather than through btcli, which requires this one
    to be MEV-shielded -- machinery the localnet does not run."""
    with _connect(chain_endpoint) as client:
        return _submit(client, _sdk().calls.SubtensorModule.burned_register(
            netuid=netuid, hotkey=hotkey_ss58,
        ))


def get_lock(
    coldkey_ss58: str, netuid: int, hotkey_ss58: str,
    *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> int:
    """locked_mass of the (coldkey, netuid, hotkey) lock in RAW alpha (0 when none)."""
    with _connect(chain_endpoint) as client:
        value = client.query(
            _sdk().storage.SubtensorModule.Lock, [coldkey_ss58, netuid, hotkey_ss58],
        )
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
    with _connect(chain_endpoint) as client:
        call = _sudo(client, _sdk().calls.AdminUtils.sudo_set_toggle_transfer(
            netuid=netuid, toggle=enabled,
        ))
        for attempt in range(attempts):
            block_hash = _submit(client, call)
            # Sudo reports success even when the inner call reverts, so trust the
            # chain state rather than the result: read the toggle back and check it stuck.
            current = client.query(_sdk().storage.SubtensorModule.TransferToggle, [netuid])
            if current == enabled:
                return block_hash
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
    with _connect(chain_endpoint) as client:
        block_hash = _submit(client, _sudo(
            client, _sdk().calls.AdminUtils.sudo_set_admin_freeze_window(window=window),
        ))
        current = client.query(_sdk().storage.SubtensorModule.AdminFreezeWindow)
    if current != window:
        raise ExtrinsicError(
            f"set_admin_freeze_window did not reach window={window} (now {current})"
        )
    return block_hash


def set_max_registrations_per_block(
    netuid: int, limit: int, *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Raise a subnet's per-block registration cap via Sudo. The bootstrap registers
    several hotkeys in a row, which the chain's default cap turns away. Root sets
    this, not the subnet owner, so it cannot go through the owner hyperparameters."""
    with _connect(chain_endpoint) as client:
        block_hash = _submit(client, _sudo(
            client,
            _sdk().calls.AdminUtils.sudo_set_max_registrations_per_block(
                netuid=netuid, max_registrations_per_block=limit,
            ),
        ))
        current = client.query(
            _sdk().storage.SubtensorModule.MaxRegistrationsPerBlock, [netuid],
        )
    if current != limit:
        raise ExtrinsicError(
            f"set_max_registrations_per_block did not reach limit={limit} (now {current})"
        )
    return block_hash


def get_nominator_min_required_stake(*, chain_endpoint: str = config.CHAIN_ENDPOINT) -> int:
    """Read the global nominator dust-threshold factor."""
    with _connect(chain_endpoint) as client:
        value = client.query(_sdk().storage.SubtensorModule.NominatorMinRequiredStake)
    return int(value) if value is not None else 0


def set_nominator_min_required_stake(
    factor: int, *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Set the global nominator dust-threshold factor via Sudo. Raising it also
    runs the chain's global clearing pass in the same block: every nomination
    whose value sits below the new threshold is force-sold and the proceeds are
    credited to its nominator coldkey. Lowering it only writes the factor."""
    with _connect(chain_endpoint) as client:
        block_hash = _submit(client, _sudo(
            client,
            _sdk().calls.AdminUtils.sudo_set_nominator_min_required_stake(min_stake=factor),
        ))
        current = client.query(_sdk().storage.SubtensorModule.NominatorMinRequiredStake)
    if current != factor:
        raise ExtrinsicError(
            f"set_nominator_min_required_stake did not reach factor={factor} (now {current})"
        )
    return block_hash


def dissolve_network(
    netuid: int, *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Dissolve (deregister) a subnet via Sudo. The chain converts every staker's
    alpha into a pro-rata share of the subnet's TAO reserve, credits it to their
    coldkey, and removes the subnet."""
    with _connect(chain_endpoint) as client:
        block_hash = _submit(client, _sudo(
            client, _sdk().calls.SubtensorModule.root_dissolve_network(netuid=netuid),
        ))
        # Sudo reports success even when the inner call reverts, so trust chain state.
        still_registered = client.query(
            _sdk().storage.SubtensorModule.NetworksAdded, [netuid],
        )
    if still_registered:
        raise ExtrinsicError(f"dissolve_network netuid={netuid} left the subnet registered")
    return block_hash


def keypair_ss58(uri: str) -> str:
    """The ss58 address behind a dev key URI, for keys that only need an identity."""
    return _sdk().sp_core.Keypair.create_from_uri(uri).ss58_address


def fund_account(
    dest_ss58: str, amount_rao: int, *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Send TAO from Alice so `dest_ss58` can pay its own transaction fees, rather
    than the test resting on whatever the chainspec happened to endow."""
    with _connect(chain_endpoint) as client:
        return _submit(client, _sdk().calls.Balances.transfer_keep_alive(
            dest=dest_ss58, value=amount_rao,
        ))


def swap_hotkey_keep_stake(
    hotkey_ss58: str, new_hotkey_ss58: str,
    *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Move a hotkey's identity across every subnet while its stake stays behind.

    The old hotkey is left with no recorded owner, which is the state the chain
    refuses to move stake out of. Signed by Alice, who owns the registered
    validator hotkeys."""
    with _connect(chain_endpoint) as client:
        return _submit(client, _sdk().calls.SubtensorModule.swap_hotkey_v2(
            hotkey=hotkey_ss58, new_hotkey=new_hotkey_ss58, netuid=None, keep_stake=True,
        ))


def associate_hotkey(
    hotkey_ss58: str, *, signer_uri: str = "//Alice",
    chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Take ownership of a hotkey nobody owns. Open to any signer and free beyond
    the fee; a hotkey that already has an owner is left alone."""
    with _connect(chain_endpoint) as client:
        return _submit(client, _sdk().calls.SubtensorModule.try_associate_hotkey(
            hotkey=hotkey_ss58,
        ), signer_uri=signer_uri)


# The ownership map answers for every hotkey, so "nobody owns this" arrives as the
# all-zero account rather than as an absent entry.
UNOWNED_ACCOUNT = "5C4hrfjw9DjXZTzV3MwzrrAr9P1MJhSrvWGWqi1eSuyUpnhM"


def hotkey_owner(
    hotkey_ss58: str, *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """The coldkey recorded as owning `hotkey_ss58`, or "" when nobody does. This
    record is what every stake operation checks the hotkey against."""
    with _connect(chain_endpoint) as client:
        value = client.query(_sdk().storage.SubtensorModule.Owner, [hotkey_ss58])
    owner = "" if value is None else str(value)
    return "" if owner == UNOWNED_ACCOUNT else owner
