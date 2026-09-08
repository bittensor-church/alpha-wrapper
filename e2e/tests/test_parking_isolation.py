"""One parking hotkey serves every subnet without coupling their positions.

The chain keys stake by hotkey, coldkey and subnet, and each subnet's position lives
under its own clone coldkey, so the vault claims a single parking hotkey for all of
them. This scenario checks what that sharing must never do: parking subnet A leaves
subnet B depositing, aligning and exiting as before; both positions park on the same
hotkey at once with separate balances; releasing one moves nothing of the other's.
"""
import pytest

from alpha_e2e import config, incidents

VALIDATORS = config.VALIDATORS_PER_SUBNET


@pytest.mark.scenario
def test_parked_subnets_share_the_hotkey_without_sharing_state(env):
    netuid_a, netuid_b = env.netuids[0], env.netuids[1]
    token_a, token_b = env.token_ids[0], env.token_ids[1]
    hotkeys_a, hotkeys_b = env.subnet_hotkey_pubkeys(0), env.subnet_hotkey_pubkeys(1)
    clone_a, clone_b = env.clone_coldkey(token_a), env.clone_coldkey(token_b)
    parking_hotkey = env.parking_hotkey()

    env.deposit_and_wrap(
        netuid_a, hotkeys_a[0], env.hotkey_ss58s[0],
        config.PER_HOTKEY_TRANSFER_RAO, 1_500_000, "Isolation: wrap on A failed",
    )
    env.deposit_and_wrap(
        netuid_b, hotkeys_b[0], env.hotkey_ss58s[VALIDATORS],
        config.PER_HOTKEY_TRANSFER_RAO, 1_500_000, "Isolation: wrap on B failed",
    )
    stakes_b_before = [env.stake(hotkey, clone_b, netuid_b) for hotkey in hotkeys_b]

    # An incident on A parks A alone.
    stranding_a = incidents.cut_trail(env, 0, 0, "//IsolationSuccessorA", "//IsolationJunkA", "Isolation: A")
    parked_a = incidents.park(env, token_a, [stranding_a.successor_pubkey], "Isolation: A")

    assert not env.awaiting_attestation(token_b), "B should not be parked by A's incident"
    assert env.backing_intact(token_b), "B's backing should be untouched"
    assert env.stake(parking_hotkey, clone_b, netuid_b) == 0, "nothing of B's should sit on the parking hotkey"
    for hotkey, before in zip(hotkeys_b, stakes_b_before):
        assert env.stake(hotkey, clone_b, netuid_b) >= before, "B's stake should stay on B's validators"

    # B keeps taking deposits, aligning and paying exits while A is parked.
    env.deposit_and_wrap(
        netuid_b, hotkeys_b[1], env.hotkey_ss58s[VALIDATORS + 1],
        config.PER_HOTKEY_TRANSFER_RAO // 10, 1_500_000, "Isolation: B should accept a deposit while A is parked",
    )
    env.vault_send(
        4_000_000, "Isolation: B should align while A is parked", "rebalance(uint256)", netuid_b,
        label="rebalance [sibling parked]",
    )
    exit_shares = env.vault_shares(token_b) // 4
    quoted_alpha, _ = env.preview_unwrap(token_b, exit_shares)
    delivered_before = env.total_stake_across(env.wrapper_substrate_coldkey, netuid_b, hotkeys_b)
    env.vault_send(
        2_500_000, "Isolation: B should pay an exit while A is parked",
        "unwrap(uint256,uint256,bytes32,uint256)", token_b, exit_shares, env.wrapper_substrate_coldkey, 1,
        label="unwrap [sibling parked]",
    )
    delivered = env.total_stake_across(env.wrapper_substrate_coldkey, netuid_b, hotkeys_b) - delivered_before
    assert delivered >= quoted_alpha - config.ROUNDING_DUST_TOTAL_RAO, (
        f"B's exit delivered {delivered} alpha against a quote of {quoted_alpha}"
    )
    assert env.stake(parking_hotkey, clone_a, netuid_a) == parked_a, "A's parked balance moved while B traded"
    assert env.awaiting_attestation(token_a), "A should still be waiting for its attesters"

    # A second incident parks B on the same hotkey, next to A.
    stranding_b = incidents.cut_trail(env, 1, 0, "//IsolationSuccessorB", "//IsolationJunkB", "Isolation: B")
    parked_b = incidents.park(env, token_b, [stranding_b.successor_pubkey], "Isolation: B")

    assert env.stake(parking_hotkey, clone_a, netuid_a) == parked_a, "parking B should leave A's entry alone"
    assert env.stake(parking_hotkey, clone_b, netuid_b) == parked_b, "B's entry should hold B's alpha"
    assert env.awaiting_attestation(token_a) and env.awaiting_attestation(token_b), "both positions should wait"

    # A's attesters release A; B keeps waiting for its own.
    env.set_validators(netuid_a, [stranding_a.successor_pubkey, hotkeys_a[1], hotkeys_a[2]], [5000, 3000, 2000])
    assert env.awaiting_attestation(token_b), "an attestation for A should not release B"
    env.vault_send(
        4_000_000, "Isolation: the release rebalance on A failed", "rebalance(uint256)", netuid_a,
        label="rebalance [release A]",
    )
    assert env.stake(parking_hotkey, clone_a, netuid_a) <= config.ROUNDING_DUST_SLOT_RAO, (
        "A's entry should be empty after its release"
    )
    assert env.stake(stranding_a.successor_pubkey, clone_a, netuid_a) > 0, "A's successor should carry its weight"
    assert not env.awaiting_attestation(token_a), "A should be ordinary again"
    assert env.stake(parking_hotkey, clone_b, netuid_b) == parked_b, "releasing A should move nothing of B's"
    assert env.awaiting_attestation(token_b), "B should still be parked"

    # B's attesters release B.
    env.set_validators(netuid_b, [stranding_b.successor_pubkey, hotkeys_b[1], hotkeys_b[2]], [5000, 3000, 2000])
    env.vault_send(
        4_000_000, "Isolation: the release rebalance on B failed", "rebalance(uint256)", netuid_b,
        label="rebalance [release B]",
    )
    assert env.stake(parking_hotkey, clone_b, netuid_b) <= config.ROUNDING_DUST_SLOT_RAO, (
        "B's entry should be empty after its release"
    )
    assert env.stake(stranding_b.successor_pubkey, clone_b, netuid_b) > 0, "B's successor should carry its weight"
    assert not env.awaiting_attestation(token_b), "B should be ordinary again"
    assert env.backing_intact(token_a) and env.backing_intact(token_b), "both records should follow their new sets"
