"""Scenario: the batched stake read the vault prices a validator set with.

The vault reads a whole validator set's balances in one call rather than one
call per hotkey, and it matches the reply back to its own list by hotkey. Four
properties of that call carry the accounting, and a faithful mock cannot prove
any of them - only the chain can:

  - argument order is (coldkey, netuid, hotkeys),
  - hotkeys holding nothing are dropped from the reply,
  - survivors keep the order they were asked in,
  - a repeated hotkey is refused outright.

A wrong argument order returns an empty reply rather than an error, which would
read as "this position holds nothing" and price every share at zero.
"""
import pytest

from alpha_e2e import chain, config, environment


@pytest.mark.scenario
def test_batched_stake_read(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    coldkey = env.clone_coldkey(token_id)
    hotkeys = env.subnet_hotkey_pubkeys(0)

    per_hotkey = {
        hotkey.lower(): env.stake(hotkey, coldkey, netuid) for hotkey in hotkeys
    }
    funded = [hotkey for hotkey, stake in per_hotkey.items() if stake > 0]
    assert funded, (
        "Batched read: the vault's position holds nothing on this subnet, so this "
        "scenario cannot tell a correct read from a silently empty one"
    )

    batched = environment.read_stake_batch(coldkey, netuid, hotkeys)
    print(f"  per-hotkey={per_hotkey}")
    print(f"  batched={batched}")

    assert batched == {hotkey: per_hotkey[hotkey] for hotkey in funded}, (
        "Batched read: disagrees with per-hotkey getStake. If the batch came back "
        "empty, the argument order is (coldkey, netuid, hotkeys) and the vault's "
        "interface has drifted from it"
    )

    # An unfunded hotkey must be absent rather than present with a zero, because the
    # vault matches the reply to its own list by hotkey and would misalign otherwise.
    unfunded = env.hotkey_pubkeys[-1]
    if env.stake(unfunded, coldkey, netuid) == 0:
        widened = environment.read_stake_batch(
            coldkey, netuid, [unfunded] + hotkeys,
        )
        assert unfunded.lower() not in widened, (
            "Batched read: an unfunded hotkey came back in the reply; the vault's "
            "forward scan assumes the chain drops them"
        )
        assert list(widened) == funded, (
            "Batched read: survivors must keep the order they were asked in"
        )

    duplicated = chain.run(
        ["cast", "call", config.STAKING_PRECOMPILE,
         "getStakeInfoForColdkeyAndNetuid(bytes32,uint256,bytes32[])((bytes32,uint256)[])",
         coldkey, str(netuid), "[" + ",".join([hotkeys[0], hotkeys[0]]) + "]",
         "--rpc-url", config.RPC_URL],
        check=False,
    )
    assert duplicated.returncode != 0, (
        "Batched read: a repeated hotkey was accepted; the vault relies on the chain "
        "refusing it, because its forward scan cannot resolve a duplicate"
    )
    print("  batched read matches per-hotkey reads, drops the unfunded, refuses duplicates")
