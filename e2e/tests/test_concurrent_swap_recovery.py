"""Unequal concurrent swaps recover into one pool, in either source order.

After both successor edges are cut, the larger source can be recovered first,
one source per call. Its actual balance reduces the pooled deficit without
assigning it to a validator. The smaller source then fills the deficit, and sync finalizes recovery.
"""
import re

import pytest

from alpha_e2e import chain, config, extrinsics, incidents


@pytest.mark.scenario
def test_concurrent_unequal_swaps_cannot_poison_stray_recovery(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)
    clone_coldkey = env.clone_coldkey(token_id)
    parking_hotkey = env.parking_hotkey()
    tolerance = config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO

    # The swap cooldown is per (subnet, coldkey), so use independent validator
    # owners rather than the bootstrap's shared Alice coldkey for both swaps.
    owner_c_uri = "//ConcurrentValidatorC"
    hotkey_c_uri = "//ConcurrentHotkeyC"
    hotkey_c_ss58 = extrinsics.keypair_ss58(hotkey_c_uri)
    extrinsics.fund_account(extrinsics.keypair_ss58(owner_c_uri), 10_000_000_000)
    extrinsics.burned_register(hotkey_c_ss58, netuid, signer_uri=owner_c_uri)
    assert extrinsics.hotkey_owner(hotkey_c_ss58) == extrinsics.keypair_ss58(owner_c_uri)
    hotkeys[1] = extrinsics.keypair_pubkey(hotkey_c_uri)
    old_ss58s = [env.hotkey_ss58s[0], hotkey_c_ss58]

    # Put the smaller slot first, so a first-compatible-slot recovery would
    # incorrectly assign C's larger balance to A.
    env.set_validators(netuid, hotkeys, [2000, 6000, 2000])
    env.deposit_and_wrap(
        netuid, hotkeys[0], env.hotkey_ss58s[0],
        config.PER_HOTKEY_TRANSFER_RAO, 1_500_000, "Concurrent swaps: wrap failed",
    )
    shares = env.vault_shares(token_id)
    assert shares > 0, "the setup must mint shares"
    assert env.vault_total_supply(token_id) == shares, "the wrapper must own the whole position"
    stake_a = env.stake(hotkeys[0], clone_coldkey, netuid)
    stake_c = env.stake(hotkeys[1], clone_coldkey, netuid)
    assert 0 < stake_a < stake_c, "A must hold less alpha than C"
    backing_before = env.vault_total_stake(token_id)

    def recorded_slots():
        return chain.cast_call_raw(
            env.vault_address, "recordedSlots(uint256)((bytes32,bytes32,uint256)[])", token_id,
        )

    record_before = recorded_slots()
    tracked = re.findall(r"\(0x[0-9a-fA-F]{64},\s*0x[0-9a-fA-F]{64},\s*(\d+)", record_before)
    assert len(tracked) == len(hotkeys), "read each recorded obligation before the swaps"
    expected = sum(map(int, tracked))
    successor_uris = ["//ConcurrentSuccessorB", "//ConcurrentSuccessorD"]
    successors = [extrinsics.keypair_pubkey(uri) for uri in successor_uris]
    successor_ss58s = [extrinsics.keypair_ss58(uri) for uri in successor_uris]
    for old_ss58, new_ss58, owner_uri in zip(old_ss58s, successor_ss58s, ["//Alice", owner_c_uri]):
        extrinsics.swap_hotkey(old_ss58, new_ss58, signer_uri=owner_uri)
        assert extrinsics.hotkey_owner(old_ss58) == "", "the swap must vacate the old name"

    # No successful vault mutation has observed either swap yet.
    assert recorded_slots() == record_before, "swaps must leave the vault's record at A and C"
    assert env.backing_intact(token_id), "both direct successors should resolve automatically"
    assert env.stake(successors[0], clone_coldkey, netuid) >= stake_a - tolerance
    assert env.stake(successors[1], clone_coldkey, netuid) >= stake_c - tolerance

    # The funded deployer has no shares; recovery must resist a non-holder too.
    assert env.vault_shares(token_id, config.DEPLOYER_ADDRESS) == 0
    env.assert_vault_reverts_with(
        "NothingToRecover()", 1_500_000,
        "Concurrent swaps: D is already resolved and cannot be counted again",
        "recoverStray(uint256,bytes32)", token_id, successors[1],
        private_key=config.DEPLOYER_PRIVATE_KEY, sender=config.DEPLOYER_ADDRESS,
    )
    assert recorded_slots() == record_before
    assert env.backing_intact(token_id)

    # Cut both outgoing edges using real extrinsics, leaving B and D funded.
    # Independent claimants also avoid sharing the per-coldkey swap cooldown.
    for old_ss58, junk_uri, stranger_uri in zip(
        old_ss58s, ["//ConcurrentJunkA", "//ConcurrentJunkC"],
        ["//ConcurrentStrangerA", "//ConcurrentStrangerC"],
    ):
        stranger_ss58 = extrinsics.keypair_ss58(stranger_uri)
        extrinsics.fund_account(stranger_ss58, incidents.STRANGER_FUNDING_RAO)
        junk_ss58 = extrinsics.keypair_ss58(junk_uri)
        extrinsics.associate_hotkey(junk_ss58, signer_uri=stranger_uri)
        extrinsics.swap_hotkey_on_subnet(junk_ss58, old_ss58, netuid, signer_uri=stranger_uri)
        assert extrinsics.hotkey_owner(old_ss58) == stranger_ss58, "the stranger must claim the vacated name"

    for old_pubkey in hotkeys[:2]:
        exists, _ = chain.cast_call_lines(
            config.STAKING_PRECOMPILE, "getHotkeySuccessor(bytes32,uint16)(bool,bytes32)", old_pubkey, netuid,
        )
        assert exists == "false", "each old name must lose its successor edge"
    assert not env.backing_intact(token_id), "both successor balances must now be unlocated"
    env.assert_vault_reverts_with(
        "BackingShortfall(uint16,bytes32,uint256)", 1_500_000,
        "Concurrent swaps: recovery must require an explicit declaration",
        "recoverStray(uint256,bytes32)", token_id, successors[1],
        private_key=config.DEPLOYER_PRIVATE_KEY, sender=config.DEPLOYER_ADDRESS,
    )
    assert env.frozen_until(token_id) == config.UNDECLARED_SHORTFALL
    assert recorded_slots() == record_before
    env.sync_backing(token_id, label="syncBacking [two missing slots]")
    deadline = env.frozen_until(token_id)
    assert 0 < deadline < config.UNDECLARED_SHORTFALL, "the shortfall must have a real recovery deadline"
    record_before = recorded_slots()
    source_balances = [env.stake(key, clone_coldkey, netuid) for key in successors]
    assert 0 < source_balances[0] < source_balances[1]
    assert source_balances[1] > stake_a, "D alone must be large enough to cover A's original slot"
    assert env.vault_located_stake(token_id) + source_balances[1] + tolerance < backing_before, (
        "D must cover the smaller slot but remain insufficient for the whole position"
    )

    parked_before = env.stake(parking_hotkey, clone_coldkey, netuid)
    assert parked_before > 0, "syncBacking must secure the located remainder immediately"
    located_before = parked_before + env.total_stake_across(clone_coldkey, netuid, hotkeys + successors)

    # Collect the larger source without assigning it to A or C.
    receipt = env.vault_send(
        4_000_000, "Concurrent swaps: partial recovery of D failed",
        "recoverStray(uint256,bytes32)", token_id, successors[1],
        private_key=config.DEPLOYER_PRIVATE_KEY, label="recoverStray [larger source]",
    )
    block = chain.receipt_block_number(receipt, "Concurrent partial recovery")
    partial = int(chain.cast_call(
        config.STAKING_PRECOMPILE, "getStake(bytes32,bytes32,uint256)(uint256)",
        parking_hotkey, clone_coldkey, netuid, block=block,
    ))
    topic = chain.run(["cast", "keccak", "BackingRecovered(uint256,bytes32,uint256)"]).stdout.strip().lower()
    events = [log for log in receipt["logs"] if (
        log["address"].lower() == env.vault_address.lower() and log["topics"][0].lower() == topic
    )]
    assert len(events) == 1
    assert int(events[0]["topics"][1], 16) == token_id
    assert events[0]["topics"][2].lower() == parking_hotkey.lower()
    assert int(events[0]["data"], 16) == partial - parked_before, "reported credit must equal actual parking credit"
    # Registered successors can earn emissions between reads. Credit actual funds,
    # including those emissions, without assigning them to an original validator.
    assert partial >= parked_before + source_balances[1] - tolerance
    missing = int(chain.cast_call(env.lens_address, "missingStake(uint256)(uint256)", token_id))
    assert abs(missing - max(expected - partial, 0)) <= tolerance
    assert recorded_slots() == record_before, "partial recovery must preserve the full expected backing"
    assert env.frozen_until(token_id) == deadline, "partial recovery must not restart the clock"
    assert env.stake(successors[1], clone_coldkey, netuid) <= config.ROUNDING_DUST_SLOT_RAO
    assert env.stake(successors[0], clone_coldkey, netuid) >= source_balances[0] - tolerance
    assert env.vault_shares(token_id) == shares
    assert not env.backing_intact(token_id)
    env.recover_stray(token_id, successors[0], "Concurrent swaps: final partial recovery failed")
    assert env.frozen_until(token_id) == deadline, "only sync may clear recovery"
    assert recorded_slots() == record_before, "collection must preserve the recovery record"
    env.sync_backing(token_id, label="syncBacking [finalize full recovery]")
    parked = env.stake(parking_hotkey, clone_coldkey, netuid)
    assert parked >= max(backing_before, located_before) - tolerance, "both swapped balances must come home"
    assert env.total_stake_across(clone_coldkey, netuid, hotkeys + successors) <= config.ROUNDING_DUST_TOTAL_RAO
    recorded_keys = re.findall(r"0x[0-9a-fA-F]{64}", recorded_slots())
    assert [key.lower() for key in recorded_keys] == [parking_hotkey.lower()] * 2, (
        "the record must collapse to one parking slot, with no unresolved C slot"
    )
    assert env.vault_total_stake(token_id) == parked
    assert env.backing_intact(token_id)
    assert env.frozen_until(token_id) == 0
    assert env.awaiting_attestation(token_id)

    # Exiting needs no new attestation and must deliver the entire recovered backing.
    quoted_alpha, _ = env.preview_unwrap(token_id, shares)
    assert quoted_alpha >= parked - tolerance, "the full exit quote must include both recovered balances"
    delivered_before = env.stake(parking_hotkey, env.wrapper_substrate_coldkey, netuid)
    env.vault_send(
        2_500_000, "Concurrent swaps: full exit after joint recovery failed",
        "unwrap(uint256,uint256,bytes32,uint256)", token_id, shares, env.wrapper_substrate_coldkey,
        max(1, quoted_alpha - config.ROUNDING_DUST_TOTAL_RAO),
    )
    delivered = env.stake(parking_hotkey, env.wrapper_substrate_coldkey, netuid) - delivered_before
    assert delivered >= parked - tolerance, "the holder must receive both recovered balances"
    assert env.stake(parking_hotkey, clone_coldkey, netuid) <= config.ROUNDING_DUST_SLOT_RAO
    assert env.vault_shares(token_id) == 0
    assert env.vault_total_supply(token_id) == 0
