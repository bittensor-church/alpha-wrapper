"""A stranger cuts the trail behind a validator's rename; the watcher parks the position.

A validator renames its hotkey on every subnet, which moves the vault's alpha to the
new name and records the edge the vault follows. Before the vault records that, a
stranger renames a junk key onto the vacated name: the chain lets anyone claim a name
with no owner, and the rename erases the name's own edge. The vault can no longer find
the alpha and refuses every priced operation.

The watcher points `recoverStray` at the successor. The vault rolls everything it can
locate onto its own parking hotkey, where nobody else can rename or claim it, and holds
deposits and weight alignment shut until the attesters publish a set without the
vacated name. Exits keep working from the parking hotkey throughout.
"""
import pytest

from alpha_e2e import config, extrinsics

# A dev account with no role in the vault, the subnet, or the swap.
STRANGER_URI = "//Bob"
# Enough for the association, the per-subnet rename fee and transaction fees.
STRANGER_FUNDING_RAO = 2_000_000_000


@pytest.mark.scenario
def test_watcher_parks_a_position_whose_trail_a_stranger_cut(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)
    lost_pubkey = env.hotkey_pubkeys[0]
    lost_ss58 = env.hotkey_ss58s[0]
    clone_coldkey = env.clone_coldkey(token_id)
    parking_hotkey = env.parking_hotkey()

    env.deposit_and_wrap(
        netuid, lost_pubkey, lost_ss58,
        config.PER_HOTKEY_TRANSFER_RAO, 1_500_000, "Parked recovery: wrap failed",
    )
    shares = env.vault_shares(token_id)
    assert shares != 0, "no shares minted by the setup wrap"
    backing_before = env.vault_total_stake(token_id)
    assert env.stake(lost_pubkey, clone_coldkey, netuid) > 0, "the setup left nothing under the hotkey about to move"

    # The validator renames its hotkey across every subnet; the alpha follows the name.
    successor_ss58 = extrinsics.keypair_ss58("//ParkedSuccessor")
    successor_pubkey = extrinsics.keypair_pubkey("//ParkedSuccessor")
    extrinsics.swap_hotkey(lost_ss58, successor_ss58)
    assert extrinsics.hotkey_owner(lost_ss58) == "", "the rename should leave the old name without an owner"
    assert env.stake(successor_pubkey, clone_coldkey, netuid) > 0, "the vault's alpha did not follow the rename"
    assert env.backing_intact(token_id), "a plain rename is followed and is not a loss"

    # A stranger renames a junk key onto the vacated name, erasing the edge the vault follows.
    stranger_ss58 = extrinsics.keypair_ss58(STRANGER_URI)
    junk_ss58 = extrinsics.keypair_ss58("//ParkedJunk")
    extrinsics.fund_account(stranger_ss58, STRANGER_FUNDING_RAO)
    extrinsics.associate_hotkey(junk_ss58, signer_uri=STRANGER_URI)
    extrinsics.swap_hotkey_on_subnet(junk_ss58, lost_ss58, netuid, signer_uri=STRANGER_URI)
    assert extrinsics.hotkey_owner(lost_ss58) == stranger_ss58, "the stranger did not take the vacated name"

    assert not env.backing_intact(token_id), "with the edge gone the vault cannot find its alpha"
    env.assert_vault_reverts_with(
        "BackingShortfall(uint16,bytes32,uint256)", 1_500_000,
        "Parked recovery: a priced operation should refuse while the alpha is unlocated",
        "rebalance(uint256)", netuid,
    )
    env.sync_backing(token_id, label="syncBacking [declare]")
    assert env.frozen_until(token_id) > 0, "the shortfall should be on file with a deadline"

    # The watcher names the successor; the vault parks everything it can locate.
    env.recover_stray(token_id, [successor_pubkey], "Parked recovery: recoverStray failed")

    parked = env.stake(parking_hotkey, clone_coldkey, netuid)
    assert parked >= backing_before - config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO, (
        f"the parking hotkey holds {parked} against {backing_before} before the incident"
    )
    assert env.total_stake_across(clone_coldkey, netuid, hotkeys + [successor_pubkey]) <= (
        config.ROUNDING_DUST_TOTAL_RAO
    ), "alpha stayed behind on validator keys after parking"
    assert env.awaiting_attestation(token_id), "the position should wait for the attesters"
    assert env.backing_intact(token_id), "parked backing accounts for itself"
    assert env.frozen_until(token_id) == 0, "and nothing is on file any more"
    assert env.vault_total_stake(token_id) == parked, "the quote prices the parked alpha"

    # Deposits and alignment wait; exits do not.
    env.assert_vault_reverts_with(
        "Parked()", 1_500_000,
        "Parked recovery: a deposit should be refused while parked",
        "wrap(uint256,bytes32,uint256)", netuid, hotkeys[1], 0,
    )
    exit_shares = shares // 4
    quoted_alpha, _ = env.preview_unwrap(token_id, exit_shares)
    delivered_before = env.stake(parking_hotkey, env.wrapper_substrate_coldkey, netuid)
    env.vault_send(
        2_500_000, "Parked recovery: the exit should pay from the parking hotkey",
        "unwrap(uint256,uint256,bytes32,uint256)", token_id, exit_shares, env.wrapper_substrate_coldkey, 1,
    )
    delivered = env.stake(parking_hotkey, env.wrapper_substrate_coldkey, netuid) - delivered_before
    assert delivered >= quoted_alpha - config.ROUNDING_DUST_TOTAL_RAO, (
        f"the parked exit delivered {delivered} alpha against a quote of {quoted_alpha}"
    )
    assert env.awaiting_attestation(token_id), "an exit does not release the position"

    # The attesters replace the vacated name with the successor; the next rebalance releases the position.
    env.set_validators(netuid, [successor_pubkey, hotkeys[1], hotkeys[2]], [5000, 3000, 2000])
    assert not env.awaiting_attestation(token_id), "a newer attestation lifts the hold"
    env.vault_send(
        4_000_000, "Parked recovery: the release rebalance failed", "rebalance(uint256)", netuid,
        label="rebalance [release parked]",
    )

    assert env.stake(parking_hotkey, clone_coldkey, netuid) <= config.ROUNDING_DUST_SLOT_RAO, (
        "the parking hotkey should be empty after the release"
    )
    assert env.stake(lost_pubkey, clone_coldkey, netuid) == 0, "nothing should go back to the stranger's name"
    assert env.stake(successor_pubkey, clone_coldkey, netuid) > 0, "the successor should carry its weight"
    assert env.backing_intact(token_id), "the record follows the new set"
    assert not env.awaiting_attestation(token_id), "and the position is ordinary again"
    env.deposit_and_wrap(
        netuid, hotkeys[1], env.hotkey_ss58s[1],
        config.PER_HOTKEY_TRANSFER_RAO // 10, 1_500_000, "Parked recovery: deposits should resume",
    )
