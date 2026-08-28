"""Scenario: a holder stranded by a hotkey swap can still get their alpha out.

A hotkey swap that keeps its stake carries the validator's identity to a new key
across every subnet and leaves the vault's alpha behind under the old one, which
the chain no longer records an owner for. The vault can still see that alpha and
still counts it - the backing is exactly where its record expects, so nothing is
missing and no recovery window opens - but every stake operation naming the
abandoned key is refused, so nobody can exit.

What matters is that this is not where the money stops. Ownership of a hotkey is
free for the taking once nobody holds it, so an account with no part in the
vault, the subnet or the swap can hand the position back to its holders, and
gains nothing over their stake by doing so. The exit that was refused then pays
out in full.
"""
import pytest

from alpha_e2e import config, extrinsics

# A dev account with no role in the vault, the subnet, or the swap.
STRANGER_URI = "//Bob"

# Enough to cover the claim's transaction fee.
STRANGER_FUNDING_RAO = 1_000_000_000


@pytest.mark.scenario
def test_stranded_holder_exits_after_anyone_claims_the_hotkey(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)
    hotkey_pubkey = env.hotkey_pubkeys[0]
    hotkey_ss58 = env.hotkey_ss58s[0]

    env.deposit_and_wrap(
        netuid, hotkey_pubkey, hotkey_ss58,
        config.PER_HOTKEY_TRANSFER_RAO, 1_500_000, "Parked: wrap failed",
    )
    shares = env.vault_shares(token_id)
    assert shares != 0, "no shares minted by the setup wrap"

    # A live subnet emits, so the position only ever grows between reads; the
    # comparisons below are floors rather than equalities for that reason.
    clone_coldkey = env.clone_coldkey(token_id)
    parked = env.stake(hotkey_pubkey, clone_coldkey, netuid)
    assert parked > 0, "the setup left no stake on the hotkey about to be stranded"

    successor_ss58 = extrinsics.keypair_ss58("//ParkedSuccessor")
    # Only a runtime without the call at all may skip; a dispatch failure on a runtime that
    # knows it (a rate limit, a funding gap) must fail the scenario, or the suite's one test
    # goes green with no coverage.
    try:
        extrinsics.swap_hotkey_keep_stake(hotkey_ss58, successor_ss58)
    except AttributeError as error:
        pytest.skip(f"this runtime cannot strand stake under an unowned hotkey: {error}")

    # The identity moved and the owner went with it; the alpha stayed put.
    assert extrinsics.hotkey_owner(hotkey_ss58) == "", "the swap left the hotkey owned"
    assert env.stake(hotkey_pubkey, clone_coldkey, netuid) >= parked, (
        "the swap was meant to leave the stake where it was"
    )

    # The vault is not the one objecting. Its record still finds the alpha exactly where it
    # expects, so nothing is missing, no recovery window opens, and the token stays quotable -
    # the refusal below can only be the chain declining to move alpha off a hotkey nobody owns.
    assert env.backing_intact(token_id), "the backing check should be satisfied, not tripped"
    assert env.frozen_until(token_id) == 0, "an intact position must not be holding anything shut"
    assert env.vault_total_stake(token_id) > 0, "the vault stopped counting the stranded alpha"

    exit_shares = shares // 2
    env.vault_send_expect_revert(
        2_500_000, "Parked: the exit should be refused while the hotkey has no owner",
        "unwrap(uint256,uint256,bytes32)", token_id, exit_shares, env.wrapper_substrate_coldkey,
    )

    # Anyone may take an abandoned hotkey. Funding the claimant here keeps the test
    # off whatever the chainspec happened to endow.
    stranger_ss58 = extrinsics.keypair_ss58(STRANGER_URI)
    extrinsics.fund_account(stranger_ss58, STRANGER_FUNDING_RAO)
    extrinsics.associate_hotkey(hotkey_ss58, signer_uri=STRANGER_URI)

    assert extrinsics.hotkey_owner(hotkey_ss58) == stranger_ss58, (
        "the stranger's claim did not take"
    )
    assert env.stake(hotkey_pubkey, clone_coldkey, netuid) >= parked, (
        "owning the hotkey must carry no claim on the stake delegated under it"
    )

    # The same exit, now paid: the holder's own coldkey receives the alpha.
    delivered_before = env.total_stake_across(env.wrapper_substrate_coldkey, netuid, hotkeys)
    env.vault_send(
        2_500_000, "Parked: the exit should succeed once the hotkey is owned again",
        "unwrap(uint256,uint256,bytes32)", token_id, exit_shares, env.wrapper_substrate_coldkey,
    )
    delivered = env.total_stake_across(env.wrapper_substrate_coldkey, netuid, hotkeys) - delivered_before

    assert delivered > 0, "the exit burned shares without delivering alpha"
    assert env.vault_shares(token_id) == shares - exit_shares, "the exit burned the wrong shares"
