"""Sub-floor balances cannot block recovery declaration or expiry.

Three positions share real-time windows: dust before declaration, dust arriving
with empty parking, and dust collected by an existing parked balance. All swaps,
plants, recoveries and exits are real chain calls; no state edits or time warps.
"""
import json
import time

import pytest

from alpha_e2e import chain, config, extrinsics
from alpha_e2e.substrate import h160_to_ss58


@pytest.fixture(scope="session")
def recovery_window():
    return 180


def _timestamp():
    block = json.loads(chain.run(["cast", "block", "latest", "--json", "--rpc-url", config.RPC_URL]).stdout)
    return int(str(block["timestamp"]), 0)


def _plant_dust(env, position):
    netuid, hotkeys, ss58s = position["netuid"], position["hotkeys"], position["ss58s"]
    floor = env.chain_min_stake_tao()
    _, boundary = env.floor_boundary(netuid, floor)
    amount = boundary * 2 // 3
    extrinsics.transfer_stake(h160_to_ss58(env.clone_address(position["token"])), ss58s[0], netuid, amount)
    balance = env.stake(hotkeys[0], position["coldkey"], netuid)
    assert balance > config.ROUNDING_DUST_TOTAL_RAO, "the plant must exceed accounting slack"
    # Match the collector's conservative upper price bound, not just a rounded-down quote.
    assert balance * (env.alpha_price(netuid) + config.ALPHA_PRICE_QUANTUM_E18) // config.ALPHA_PRICE_SCALE < floor
    position["dust"] = balance


@pytest.mark.scenario
def test_sub_floor_backing_cannot_block_the_fixed_recovery_window(env, recovery_window):
    tolerance = config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO
    parking = env.parking_hotkey()
    positions = []
    for index in range(3):
        netuid, token = env.netuids[index], env.token_ids[index]
        uris = [f"//RecoveryDust{index}{name}" for name in ("A", "C", "E")]
        hotkeys = [extrinsics.keypair_pubkey(uri) for uri in uris]
        ss58s = [extrinsics.keypair_ss58(uri) for uri in uris]
        for ss58 in ss58s:
            extrinsics.associate_hotkey(ss58)
            assert not extrinsics.hotkey_is_registered(ss58, netuid)
        extrinsics.add_stake(ss58s[0], netuid, 100_000_000_000)
        deposit = env.stake(hotkeys[0], config.ALICE_COLDKEY_PUBKEY, netuid) // 2
        env.set_validators(netuid, hotkeys, [5000, 3000, 2000])
        env.deposit_and_wrap(netuid, hotkeys[0], ss58s[0], deposit, 1_500_000, "Recovery dust: wrap failed")
        coldkey = env.clone_coldkey(token)
        expected = env.vault_total_stake(token)
        source_uris = [f"//RecoveryDust{index}{name}" for name in ("B", "D", "F")]
        sources = [extrinsics.keypair_pubkey(uri) for uri in source_uris]
        # Keep E located only in the third position, to seed a movable parking balance.
        swap_count = 2 if index == 2 else 3
        for old, new_uri in zip(ss58s[:swap_count], source_uris[:swap_count]):
            extrinsics.swap_hotkey(old, extrinsics.keypair_ss58(new_uri))
        # Reclaim A to make a real sub-floor transfer possible, without restoring its lost stake.
        extrinsics.associate_hotkey(ss58s[0])
        extrinsics.add_stake(ss58s[0], netuid, 1_000_000_000)
        assert not env.backing_intact(token)
        positions.append({
            "netuid": netuid, "token": token, "coldkey": coldkey,
            "hotkeys": hotkeys, "ss58s": ss58s, "sources": sources[:swap_count],
            "expected": expected, "shares": env.vault_shares(token), "dust": 0,
        })

    _plant_dust(env, positions[0])
    for index, position in enumerate(positions):
        token, netuid, coldkey = position["token"], position["netuid"], position["coldkey"]
        env.sync_backing(token, label=f"syncBacking [dust case {index}: declare]")
        position["deadline"] = env.frozen_until(token)
        since = int(chain.cast_call_lines(env.vault_address, "recovery(uint256)(uint64,uint256)", token)[0])
        assert position["deadline"] == since + recovery_window
        position["parked"] = env.stake(parking, coldkey, netuid)
        if index < 2:
            assert position["parked"] == 0, "recovery must start even without a movable pile"
        else:
            assert position["parked"] > 0

    for position in positions[1:]:
        _plant_dust(env, position)
    position = positions[2]
    assert _timestamp() < position["deadline"], "stage dust collection before expiry"
    env.sync_backing(position["token"], label="syncBacking [parked pile collects dust]")
    collected = env.stake(parking, position["coldkey"], position["netuid"])
    assert abs(collected - position["parked"] - position["dust"]) <= tolerance
    assert env.stake(position["hotkeys"][0], position["coldkey"], position["netuid"]) <= config.ROUNDING_DUST_SLOT_RAO
    position["parked"] = collected
    for position in positions:
        assert env.frozen_until(position["token"]) == position["deadline"]

    deadline = max(position["deadline"] for position in positions)
    timeout = time.monotonic() + recovery_window + 120
    while _timestamp() < deadline:
        assert time.monotonic() < timeout, "localnet did not reach the recovery deadline"
        time.sleep(2)
    topic = chain.run(["cast", "keccak", "BackingWrittenOff(uint256,uint256,uint256)"]).stdout.strip().lower()
    for index, position in enumerate(positions):
        token, netuid, coldkey = position["token"], position["netuid"], position["coldkey"]
        receipt = env.vault_send(
            4_000_000, "Recovery dust: expiry must succeed", "syncBacking(uint256)", token,
            label=f"syncBacking [dust case {index}: write-off]",
        )
        events = [log for log in receipt["logs"] if (
            log["address"].lower() == env.vault_address.lower() and log["topics"][0].lower() == topic
        )]
        assert len(events) == 1 and int(events[0]["topics"][1], 16) == token
        data = events[0]["data"].removeprefix("0x")
        assert abs(int(data[:64], 16) - position["expected"]) <= tolerance
        assert int(data[64:], 16) == position["parked"], "all secured backing must survive write-off"
        assert env.vault_total_stake(token) == position["parked"]
        assert env.frozen_until(token) == 0 and env.backing_intact(token)
        if index < 2:
            assert env.stake(position["hotkeys"][0], coldkey, netuid) == position["dust"]

        # Written-off dust remains recoverable. Explicitly include its abandoned location.
        env.recover_stray(token, position["sources"] + [position["hotkeys"][0]], "Recovery dust: late collection failed")
        parked = env.stake(parking, coldkey, netuid)
        assert abs(parked - position["expected"] - position["dust"]) <= 3 * tolerance
        assert env.vault_shares(token) == position["shares"]
        assert env.total_stake_across(coldkey, netuid, position["hotkeys"] + position["sources"]) <= config.ROUNDING_DUST_TOTAL_RAO
        delivered_before = env.stake(parking, env.wrapper_substrate_coldkey, netuid)
        env.vault_send(
            2_500_000, "Recovery dust: holder exit failed", "unwrap(uint256,uint256,bytes32,uint256)",
            token, position["shares"], env.wrapper_substrate_coldkey, max(1, parked - tolerance),
        )
        assert env.stake(parking, env.wrapper_substrate_coldkey, netuid) - delivered_before >= parked - tolerance
        assert env.vault_total_supply(token) == 0
