"""Parking before declaration prevents late swaps from increasing the deficit.

All swaps use real extrinsics on unregistered receiving hotkeys, which hold stake
without recording subnet successor edges. A and E disappear before declaration;
C is secured immediately. A late C->D swap cannot take its parked backing.
Partial recovery of B also parks immediately and cannot be undone by reverse
swaps. One fixed window ends with only E's unrecovered balance written off.
"""
import json
import time

import pytest

from alpha_e2e import chain, config, extrinsics


@pytest.fixture(scope="session")
def recovery_window():
    return 180


def _timestamp(block="latest"):
    data = json.loads(chain.run(["cast", "block", str(block), "--json", "--rpc-url", config.RPC_URL]).stdout)
    return int(str(data["timestamp"]), 0)


def _substrate_timestamp(block_hash):
    header = json.loads(chain.run([
        "cast", "rpc", "chain_getHeader", json.dumps(block_hash), "--rpc-url", config.RPC_URL,
    ]).stdout)
    assert header is not None
    return _timestamp(int(header["number"], 16))


def _wait_until(timestamp):
    timeout = time.monotonic() + 240
    while _timestamp() < timestamp:
        assert time.monotonic() < timeout, "localnet did not reach the recovery timestamp"
        time.sleep(2)


@pytest.mark.scenario
def test_parking_prevents_late_swaps_and_partial_recovery_keeps_one_deadline(env, recovery_window):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    clone = env.clone_coldkey(token_id)
    parking = env.parking_hotkey()
    tolerance = config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO
    window = int(chain.cast_call(env.vault_address, "recoveryWindow()(uint256)"))
    assert window == recovery_window

    uris = ["//DeadlineA", "//DeadlineC", "//DeadlineE"]
    hotkeys = [extrinsics.keypair_pubkey(uri) for uri in uris]
    ss58s = [extrinsics.keypair_ss58(uri) for uri in uris]
    for ss58 in ss58s:
        extrinsics.associate_hotkey(ss58)
        assert not extrinsics.hotkey_is_registered(ss58, netuid)
    extrinsics.add_stake(ss58s[0], netuid, 100_000_000_000)
    deposit = env.stake(hotkeys[0], config.ALICE_COLDKEY_PUBKEY, netuid) // 2
    env.set_validators(netuid, hotkeys, [2000, 6000, 2000])
    env.deposit_and_wrap(netuid, hotkeys[0], ss58s[0], deposit, 1_500_000, "Fixed deadline: wrap failed")
    shares = env.vault_shares(token_id)
    expected = env.vault_total_stake(token_id)
    a_stake, c_stake, e_stake = [env.stake(key, clone, netuid) for key in hotkeys]
    assert 0 < a_stake < c_stake and e_stake > 0

    successors = ["//DeadlineB", "//DeadlineD", "//DeadlineF"]
    b, d, f = [extrinsics.keypair_pubkey(uri) for uri in successors]
    b_ss58, d_ss58, f_ss58 = [extrinsics.keypair_ss58(uri) for uri in successors]
    extrinsics.swap_hotkey(ss58s[0], b_ss58)
    extrinsics.swap_hotkey(ss58s[2], f_ss58)
    env.sync_backing(token_id, label="syncBacking [secure C and start fixed window]")
    deadline = env.frozen_until(token_id)
    declared_at = int(chain.cast_call_lines(env.vault_address, "recovery(uint256)(uint64,uint256)", token_id)[0])
    assert deadline == declared_at + window
    parked_before = env.stake(parking, clone, netuid)
    assert abs(parked_before - c_stake) <= tolerance
    assert env.stake(hotkeys[1], clone, netuid) <= config.ROUNDING_DUST_SLOT_RAO
    missing = int(chain.cast_call(env.lens_address, "missingStake(uint256)(uint256)", token_id))
    assert abs(missing - a_stake - e_stake) <= tolerance

    # The late swap happens inside the last minute, but C's vault balance is already safe.
    _wait_until(deadline - 60)
    late_block = extrinsics.swap_hotkey(ss58s[1], d_ss58)
    late_at = _substrate_timestamp(late_block)
    assert deadline - 60 <= late_at < deadline, "stage the late swap before expiry"
    assert env.stake(d, clone, netuid) <= config.ROUNDING_DUST_SLOT_RAO
    assert env.stake(parking, clone, netuid) == parked_before
    assert env.frozen_until(token_id) == deadline

    env.recover_stray(token_id, b, "Fixed deadline: partial recovery must succeed")
    partial = env.stake(parking, clone, netuid)
    assert abs(partial - parked_before - a_stake) <= tolerance
    assert env.frozen_until(token_id) == deadline, "partial recovery must not extend the deadline"
    assert not env.backing_intact(token_id), "E remains unrecovered"
    assert abs(int(chain.cast_call(env.lens_address, "missingStake(uint256)(uint256)", token_id)) - e_stake) <= tolerance

    # Neither reversing the recovered source nor swapping it again can move the parked funds.
    extrinsics.swap_hotkey(b_ss58, ss58s[0])
    extrinsics.swap_hotkey(ss58s[0], b_ss58)
    assert env.stake(b, clone, netuid) <= config.ROUNDING_DUST_SLOT_RAO
    assert env.stake(hotkeys[0], clone, netuid) <= config.ROUNDING_DUST_SLOT_RAO
    assert env.stake(parking, clone, netuid) == partial
    assert env.frozen_until(token_id) == deadline

    _wait_until(deadline)
    receipt = env.vault_send(
        4_000_000, "Fixed deadline: write-off failed", "syncBacking(uint256)", token_id,
        label="syncBacking [fixed deadline expired]",
    )
    written_off_at = _timestamp(chain.receipt_block_number(receipt, "Fixed deadline"))
    assert written_off_at >= deadline
    topic = chain.run(["cast", "keccak", "BackingWrittenOff(uint256,uint256,uint256)"]).stdout.strip()
    events = [log for log in receipt["logs"] if (
        log["address"].lower() == env.vault_address.lower() and log["topics"][0].lower() == topic.lower()
    )]
    assert len(events) == 1
    assert int(events[0]["topics"][1], 16) == token_id
    data = events[0]["data"].removeprefix("0x")
    event_expected, event_located = int(data[:64], 16), int(data[64:], 16)
    assert abs(event_expected - expected) <= tolerance
    assert abs(event_expected - event_located - e_stake) <= tolerance, "only the unrecovered deficit is written off"
    assert env.stake(parking, clone, netuid) == partial
    assert env.vault_shares(token_id) == shares
    assert env.backing_intact(token_id) and env.awaiting_attestation(token_id)
    assert env.frozen_until(token_id) == 0
    print(f"Fixed deadline: declared={declared_at}, late_swap={late_at}, deadline={deadline}, write_off={written_off_at}")

    env.recover_stray(token_id, f, "Fixed deadline: late recovery failed")
    assert env.stake(f, clone, netuid) <= config.ROUNDING_DUST_SLOT_RAO
    assert env.vault_total_stake(token_id) >= expected - 2 * tolerance
    assert env.vault_shares(token_id) == shares
