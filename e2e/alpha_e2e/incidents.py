"""Chain-side incidents the recovery scenarios stage against a vault position."""
from dataclasses import dataclass
from . import config, extrinsics
from .environment import Environment

# A dev account with no role in the vault, the subnets, or the swaps.
STRANGER_URI = "//Bob"
# Enough for one association, one per-subnet rename fee and transaction fees.
STRANGER_FUNDING_RAO = 2_000_000_000


@dataclass(frozen=True)
class Stranding:
    lost_pubkey: str
    lost_ss58: str
    successor_pubkey: str
    successor_ss58: str
    stranger_ss58: str
    backing_before: int


def cut_trail(
    env: Environment, subnet_index: int, validator_index: int,
    successor_uri: str, junk_uri: str, context: str,
) -> Stranding:
    """Strand the vault's alpha behind a rename whose trail a stranger cuts."""
    netuid = env.netuids[subnet_index]
    token_id = env.token_ids[subnet_index]
    position = subnet_index * config.VALIDATORS_PER_SUBNET + validator_index
    lost_pubkey = env.hotkey_pubkeys[position]
    lost_ss58 = env.hotkey_ss58s[position]
    clone_coldkey = env.clone_coldkey(token_id)
    backing_before = env.vault_total_stake(token_id)
    assert env.stake(lost_pubkey, clone_coldkey, netuid) > 0, (
        f"{context}: nothing sits under the hotkey about to move"
    )

    successor_ss58 = extrinsics.keypair_ss58(successor_uri)
    successor_pubkey = extrinsics.keypair_pubkey(successor_uri)
    extrinsics.swap_hotkey(lost_ss58, successor_ss58)
    assert extrinsics.hotkey_owner(lost_ss58) == "", f"{context}: the rename should leave the old name unowned"
    assert env.stake(successor_pubkey, clone_coldkey, netuid) > 0, f"{context}: the alpha did not follow the rename"
    assert env.backing_intact(token_id), f"{context}: a plain rename is followed and is not a loss"

    stranger_ss58 = extrinsics.keypair_ss58(STRANGER_URI)
    junk_ss58 = extrinsics.keypair_ss58(junk_uri)
    extrinsics.fund_account(stranger_ss58, STRANGER_FUNDING_RAO)
    extrinsics.associate_hotkey(junk_ss58, signer_uri=STRANGER_URI)
    extrinsics.swap_hotkey_on_subnet(junk_ss58, lost_ss58, netuid, signer_uri=STRANGER_URI)
    assert extrinsics.hotkey_owner(lost_ss58) == stranger_ss58, f"{context}: the stranger did not take the name"
    assert not env.backing_intact(token_id), f"{context}: with the edge gone the vault should not find its alpha"

    return Stranding(lost_pubkey, lost_ss58, successor_pubkey, successor_ss58, stranger_ss58, backing_before)


def park(env: Environment, token_id: int, stranding: Stranding, context: str) -> int:
    """The watcher's answer to a shortfall."""
    netuid = env.netuids[env.token_ids.index(token_id)]
    clone_coldkey = env.clone_coldkey(token_id)
    backing_before = stranding.backing_before

    env.sync_backing(token_id, label="syncBacking [declare]")
    assert env.frozen_until(token_id) > 0, f"{context}: the shortfall should be on file with a deadline"
    env.recover_stray(token_id, stranding.successor_pubkey, f"{context}: recoverStray failed")

    env.sync_backing(token_id, label="syncBacking [finalize]")
    parked = env.stake(env.parking_hotkey(), clone_coldkey, netuid)
    assert parked >= backing_before - config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO, (
        f"{context}: the parking hotkey holds {parked} against {backing_before} before the incident"
    )
    assert env.awaiting_attestation(token_id), f"{context}: the position should wait for the attesters"
    assert env.backing_intact(token_id), f"{context}: parked backing accounts for itself"
    assert env.frozen_until(token_id) == 0, f"{context}: nothing should be on file any more"
    return parked
