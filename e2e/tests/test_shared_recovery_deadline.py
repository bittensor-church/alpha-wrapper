"""A late second loss inherits the first loss's deadline, even if the first returns.

Attested hotkeys outside the metagraph can hold stake. Their global swaps move that
stake without a subnet successor edge, so the vault loses sight of it. They also
allow the first owner to swap back without a subnet membership cooldown. This
stages both losses and the first return through real extrinsics, with no storage
edits or time warps. An intentionally short constructor window keeps CI bounded.
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


def _wait_until(timestamp):
    timeout = time.monotonic() + 240
    while _timestamp() < timestamp:
        assert time.monotonic() < timeout, "localnet did not reach the recovery timestamp"
        time.sleep(2)


@pytest.mark.scenario
def test_second_loss_is_written_off_on_the_first_loss_deadline(env, recovery_window):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    clone = env.clone_coldkey(token_id)
    parking = env.parking_hotkey()
    tolerance = config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO
    window = int(chain.cast_call(env.vault_address, "recoveryWindow()(uint256)"))
    assert window == recovery_window

    # Unregistered receiving keys neither earn emissions nor create swap lineage.
    # Use three so a live remainder exists even while A and C are both missing.
    uris = ["//DeadlineA", "//DeadlineC", "//DeadlineLive"]
    hotkeys = [extrinsics.keypair_pubkey(uri) for uri in uris]
    ss58s = [extrinsics.keypair_ss58(uri) for uri in uris]
    for ss58 in ss58s:
        extrinsics.associate_hotkey(ss58)
        assert not extrinsics.hotkey_is_registered(ss58, netuid)
    extrinsics.add_stake(ss58s[0], netuid, 100_000_000_000)
    deposit = env.stake(hotkeys[0], config.ALICE_COLDKEY_PUBKEY, netuid) // 2
    env.set_validators(netuid, hotkeys, [2000, 6000, 2000])
    env.deposit_and_wrap(netuid, hotkeys[0], ss58s[0], deposit, 1_500_000, "Shared deadline: wrap failed")
    shares = env.vault_shares(token_id)
    assert shares > 0
    expected = env.vault_total_stake(token_id)
    first_stake = env.stake(hotkeys[0], clone, netuid)
    second_stake = env.stake(hotkeys[1], clone, netuid)
    assert 0 < first_stake < second_stake

    b_ss58, d_ss58 = [extrinsics.keypair_ss58(uri) for uri in ("//DeadlineB", "//DeadlineD")]
    b, d = [extrinsics.keypair_pubkey(uri) for uri in ("//DeadlineB", "//DeadlineD")]
    extrinsics.swap_hotkey(ss58s[0], b_ss58)
    assert env.stake(b, clone, netuid) >= first_stake - tolerance
    assert not env.backing_intact(token_id), "the first swap must leave unlocated backing"
    env.sync_backing(token_id, label="syncBacking [first loss]")
    deadline = env.frozen_until(token_id)
    declared_at = int(chain.cast_call_lines(
        env.vault_address, "recovery(uint256)(uint64,uint256)", token_id,
    )[0])
    assert deadline == declared_at + window

    # Introduce C's loss in the last minute of A's three-minute window.
    _wait_until(deadline - 60)
    second_swap_block = extrinsics.swap_hotkey(ss58s[1], d_ss58)
    second_at = _timestamp(second_swap_block)
    assert deadline - 60 <= second_at < deadline, "the second loss must happen shortly before the old deadline"
    assert env.stake(d, clone, netuid) >= second_stake - tolerance
    assert env.frozen_until(token_id) == deadline, "a later loss does not extend the shared clock"

    # Recovery of only the first loss is not accepted while the second remains.
    env.assert_vault_reverts_with(
        "RecoveryIncomplete()", 1_500_000, "Shared deadline: recovering only A must fail while C is missing",
        "recoverStray(uint256,bytes32[])", token_id, f"[{b}]",
    )
    assert env.frozen_until(token_id) == deadline
    assert env.stake(b, clone, netuid) >= first_stake - tolerance

    # Return the actual first balance to A through a reverse swap. This does not
    # call recoverStray or donate replacement backing: B must be drained into A.
    returned_block = extrinsics.swap_hotkey(b_ss58, ss58s[0])
    assert _timestamp(returned_block) < deadline, "the first balance must return before expiry"
    assert env.stake(b, clone, netuid) <= config.ROUNDING_DUST_SLOT_RAO
    assert env.stake(hotkeys[0], clone, netuid) >= first_stake - tolerance
    assert not env.backing_intact(token_id), "C is still missing after A returns"
    env.assert_vault_reverts_with(
        "BackingUnchanged()", 1_500_000, "Shared deadline: partial restoration must not clear or restart the clock",
        "syncBacking(uint256)", token_id,
    )
    assert env.frozen_until(token_id) == deadline
    assert _timestamp() < deadline, "the pre-expiry sync must be tested before expiry"

    _wait_until(deadline)
    receipt = env.vault_send(
        4_000_000, "Shared deadline: the original deadline must permit writing off C",
        "syncBacking(uint256)", token_id, label="syncBacking [late loss written off]",
    )
    written_off_at = _timestamp(chain.receipt_block_number(receipt, "Shared deadline"))
    assert deadline <= written_off_at < second_at + window, (
        "C must be written off before a full recovery window has elapsed since its own swap"
    )

    topic = chain.run(["cast", "keccak", "BackingWrittenOff(uint256,uint256,uint256)"]).stdout.strip()
    write_offs = [log for log in receipt["logs"] if (
        log["address"].lower() == env.vault_address.lower() and log["topics"][0].lower() == topic.lower()
    )]
    assert len(write_offs) == 1, "syncBacking must emit exactly one write-off"
    event = write_offs[0]
    assert int(event["topics"][1], 16) == token_id
    data = event["data"].removeprefix("0x")
    assert len(data) == 128
    event_expected, event_located = int(data[:64], 16), int(data[64:], 16)
    assert abs(event_expected - expected) <= tolerance
    assert abs((event_expected - event_located) - second_stake) <= tolerance, (
        "only C's still-missing stake should be written off; A's returned balance must be retained"
    )
    parked = env.stake(parking, clone, netuid)
    assert abs(parked - event_located) <= tolerance
    assert env.stake(d, clone, netuid) >= second_stake - tolerance, "written-off alpha remains on D"
    assert env.vault_shares(token_id) == shares, "the write-off reduces backing, not shares"
    assert env.backing_intact(token_id) and env.awaiting_attestation(token_id)
    assert env.frozen_until(token_id) == 0
    print(
        f"Shared deadline: declared={declared_at}, second_loss={second_at}, deadline={deadline}, "
        f"write_off={written_off_at}, second_loss_age={written_off_at - second_at}s, full_window={window}s"
    )

    # The write-off does not destroy D's stake: it can still join current holders' backing later.
    env.recover_stray(token_id, [d], "Shared deadline: late recovery of D failed")
    assert env.stake(d, clone, netuid) <= config.ROUNDING_DUST_SLOT_RAO
    assert env.vault_total_stake(token_id) >= expected - 2 * tolerance
    assert env.vault_shares(token_id) == shares
