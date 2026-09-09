"""Substrate extrinsics driving the localnet, signed by the dev Alice key.

Each function opens a fresh connection, submits one extrinsic, and waits for
inclusion. Failures raise ExtrinsicError carrying the chain's decoded module
error (e.g. its name), which negative tests assert on.

The bittensor SDK is imported lazily so the pure-Python helpers in this
package stay usable without it installed.
"""
import hashlib
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
    show a call is open to signers with no relationship to its subject."""
    signer = _sdk().sp_core.Keypair.create_from_uri(signer_uri)
    result = client.submit_call(call, signer, wait_for_finalization=False)
    if not result.success:
        raise ExtrinsicError(_failure(result))
    return result.block_hash


def _sudo(client, call):
    """Encode an administrative call for submission through Sudo."""
    return _sdk().calls.Sudo.sudo(call=client.compose(call))


def transfer_stake(
    dest_ss58: str, hotkey_ss58: str, netuid: int, alpha_amount: int,
    *, signer_uri: str = "//Alice", chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    with _connect(chain_endpoint) as client:
        return _submit(client, _sdk().calls.SubtensorModule.transfer_stake(
            destination_coldkey=dest_ss58,
            hotkey=hotkey_ss58,
            origin_netuid=netuid,
            destination_netuid=netuid,
            alpha_amount=alpha_amount,
        ), signer_uri=signer_uri)


def add_stake(
    hotkey_ss58: str, netuid: int, amount_rao: int,
    *, signer_uri: str = "//Alice", chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    with _connect(chain_endpoint) as client:
        return _submit(client, _sdk().calls.SubtensorModule.add_stake(
            hotkey=hotkey_ss58, netuid=netuid, amount_staked=amount_rao,
        ), signer_uri=signer_uri)


def remove_stake(
    hotkey_ss58: str, netuid: int, amount_rao: int,
    *, signer_uri: str = "//Alice", chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Sell `amount_rao` alpha back to the pool for TAO."""
    with _connect(chain_endpoint) as client:
        return _submit(client, _sdk().calls.SubtensorModule.remove_stake(
            hotkey=hotkey_ss58, netuid=netuid, amount_unstaked=amount_rao,
        ), signer_uri=signer_uri)


def lock_stake(
    hotkey_ss58: str, netuid: int, amount_rao: int,
    *, signer_uri: str = "//Alice", chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Lock `amount_rao` alpha to the given conviction hotkey."""
    with _connect(chain_endpoint) as client:
        return _submit(client, _sdk().calls.SubtensorModule.lock_stake(
            hotkey=hotkey_ss58, netuid=netuid, amount=amount_rao,
        ), signer_uri=signer_uri)


def set_reject_locked_alpha(
    enabled: bool, *, signer_uri: str = "//Alice", chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Flip whether the signer's coldkey refuses incoming locked alpha; the chain
    default refuses, and only the account itself or a coldkey swap into it can change that."""
    with _connect(chain_endpoint) as client:
        return _submit(client, _sdk().calls.SubtensorModule.set_reject_locked_alpha(
            enabled=enabled,
        ), signer_uri=signer_uri)


def set_perpetual_lock(
    netuid: int, enabled: bool, *, signer_uri: str = "//Alice",
    chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Keep the signer's lock on `netuid` from decaying. Allowed before any lock exists,
    so a coldkey swap can carry the preference onto its destination."""
    with _connect(chain_endpoint) as client:
        return _submit(client, _sdk().calls.SubtensorModule.set_perpetual_lock(
            netuid=netuid, enabled=enabled,
        ), signer_uri=signer_uri)


def account_flags(coldkey_ss58: str, *, chain_endpoint: str = config.CHAIN_ENDPOINT) -> int:
    """The chain's per-coldkey flag word; bit 0 set means the account accepts locked alpha."""
    with _connect(chain_endpoint) as client:
        value = client.query(_sdk().storage.SubtensorModule.AccountFlags, [coldkey_ss58])
    return int(value) if value is not None else 0


def set_coldkey_swap_announcement_delay(
    blocks: int, *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Shorten the wait between announcing a coldkey swap and executing it, via Sudo."""
    with _connect(chain_endpoint) as client:
        block_hash = _submit(client, _sudo(
            client,
            _sdk().calls.AdminUtils.sudo_set_coldkey_swap_announcement_delay(duration=blocks),
        ))
        current = client.query(_sdk().storage.SubtensorModule.ColdkeySwapAnnouncementDelay)
    if int(current) != blocks:
        raise ExtrinsicError(
            f"set_coldkey_swap_announcement_delay did not reach {blocks} (now {current})"
        )
    return block_hash


def announce_coldkey_swap(
    new_coldkey_account: bytes, *, signer_uri: str, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Announce that the signer's coldkey will become `new_coldkey_account`. The chain takes
    the destination's BlakeTwo256 hash and asks nothing of the destination itself; it only
    has to stake nothing and not be a hotkey when the swap executes."""
    new_coldkey_hash = hashlib.blake2b(new_coldkey_account, digest_size=32).hexdigest()
    with _connect(chain_endpoint) as client:
        return _submit(client, _sdk().calls.SubtensorModule.announce_coldkey_swap(
            new_coldkey_hash="0x" + new_coldkey_hash,
        ), signer_uri=signer_uri)


def swap_coldkey_announced(
    new_coldkey_ss58: str, *, signer_uri: str, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Execute an announced coldkey swap once its delay has passed: every stake, lock,
    flag and TAO balance of the signer's coldkey moves onto `new_coldkey_ss58`."""
    with _connect(chain_endpoint) as client:
        return _submit(client, _sdk().calls.SubtensorModule.swap_coldkey_announced(
            new_coldkey=new_coldkey_ss58,
        ), signer_uri=signer_uri)


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
    """Set and verify the administrative update window used by scenario setup."""
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


def network_registration_block(netuid: int, *, chain_endpoint: str = config.CHAIN_ENDPOINT) -> int:
    with _connect(chain_endpoint) as client:
        return int(client.query(_sdk().storage.SubtensorModule.NetworkRegisteredAt, [netuid]))


def _set_subnet_u64(item: bytes, netuid: int, value: int, chain_endpoint: str) -> str:
    """Write one entry of a per-netuid `SubtensorModule` map through Sudo."""
    import xxhash

    def twox128(data: bytes) -> bytes:
        return b"".join(
            xxhash.xxh64(data, seed=seed).intdigest().to_bytes(8, "little") for seed in (0, 1)
        )

    # These maps are keyed by the netuid's own bytes (Identity hasher).
    key = twox128(b"SubtensorModule") + twox128(item) + netuid.to_bytes(2, "little")
    with _connect(chain_endpoint) as client:
        return _submit(client, _sudo(
            client, _sdk().calls.System.set_storage(items=[(key, value.to_bytes(8, "little"))]),
        ))


def set_network_registration_block(
    netuid: int, block_number: int, *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Rewrite a live subnet's registration block through Sudo, the way chain
    migrations have done to extend a subnet's immunity period."""
    block_hash = _set_subnet_u64(b"NetworkRegisteredAt", netuid, block_number, chain_endpoint)
    written = network_registration_block(netuid, chain_endpoint=chain_endpoint)
    if written != block_number:
        raise ExtrinsicError(f"set_network_registration_block wrote {written}, wanted {block_number}")
    return block_hash


def set_subnet_alpha_in(
    netuid: int, alpha_rao: int, *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Rewrite the alpha side of a subnet's pool through Sudo. The localnet prices alpha
    above one TAO, where the pool refuses no sale; deepening the alpha side brings the
    price down to where most subnets trade. Read the result back through the alpha
    precompile: emissions keep adding to it every block."""
    return _set_subnet_u64(b"SubnetAlphaIn", netuid, alpha_rao, chain_endpoint)


def keypair_pubkey(uri: str) -> str:
    """The 32-byte public key of a dev URI, hex-encoded, as the vault and precompiles take it."""
    return "0x" + bytes(_sdk().sp_core.Keypair.create_from_uri(uri).public_key).hex()


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


def swap_hotkey(
    hotkey_ss58: str, new_hotkey_ss58: str,
    *, signer_uri: str = "//Alice", chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Rename a hotkey across every subnet, carrying its stake to the new name and
    leaving the old name without an owner record. The chain records the
    old -> new edge the vault follows."""
    with _connect(chain_endpoint) as client:
        return _submit(client, _sdk().calls.SubtensorModule.swap_hotkey_v2(
            hotkey=hotkey_ss58, new_hotkey=new_hotkey_ss58, netuid=None, keep_stake=False,
        ), signer_uri=signer_uri)


def swap_hotkey_on_subnet(
    hotkey_ss58: str, new_hotkey_ss58: str, netuid: int,
    *, signer_uri: str = "//Alice", chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    """Rename a hotkey on one subnet. The target may be any name with no owner
    record, and the rename erases that name's own outgoing edge, which is how a
    stranger can cut the trail the vault follows."""
    with _connect(chain_endpoint) as client:
        return _submit(client, _sdk().calls.SubtensorModule.swap_hotkey_v2(
            hotkey=hotkey_ss58, new_hotkey=new_hotkey_ss58, netuid=netuid, keep_stake=False,
        ), signer_uri=signer_uri)


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


def hotkey_is_registered(
    hotkey_ss58: str, netuid: int, *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> bool:
    """Whether `hotkey_ss58` currently has subnet membership on `netuid`."""
    with _connect(chain_endpoint) as client:
        value = client.query(
            _sdk().storage.SubtensorModule.IsNetworkMember, [hotkey_ss58, netuid],
        )
    return bool(value)


# An unowned hotkey returns the zero account rather than an absent value; normalize it to an empty owner.
UNOWNED_ACCOUNT = "5C4hrfjw9DjXZTzV3MwzrrAr9P1MJhSrvWGWqi1eSuyUpnhM"


def hotkey_owner(
    hotkey_ss58: str, *, chain_endpoint: str = config.CHAIN_ENDPOINT,
) -> str:
    '''Return the hotkey owner, or "" when nobody owns it.'''
    with _connect(chain_endpoint) as client:
        value = client.query(_sdk().storage.SubtensorModule.Owner, [hotkey_ss58])
    owner = "" if value is None else str(value)
    return "" if owner == UNOWNED_ACCOUNT else owner
