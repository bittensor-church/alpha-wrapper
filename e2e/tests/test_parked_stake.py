"""Scenario: stake stranded under an unowned hotkey comes free without privileged help.

A hotkey swap that keeps its stake carries the validator's identity to a new key
across every subnet and leaves the vault's alpha behind under the old one, which
the chain no longer records an owner for. Stake operations naming that key are
then refused - as a move's origin, as its destination, and as an unstake source
- so the vault can see the position but cannot move it.

Clearing it needs nothing privileged and nothing from the attesters. Any account
may take ownership of a hotkey nobody owns, and that restores exactly the record
those refusals consult. An account with no part in the vault, the subnet or the
swap does the claiming here, and the stake stays where it was: ownership of a
hotkey carries no claim on what is delegated under it.
"""
import pytest

from alpha_e2e import config, extrinsics

# A dev account with no role in the vault, the subnet, or the swap.
STRANGER_URI = "//Bob"


@pytest.mark.scenario
def test_parked_stake_frees_after_anyone_claims_the_hotkey(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkey_pubkey = env.hotkey_pubkeys[0]
    hotkey_ss58 = env.hotkey_ss58s[0]

    env.deposit_and_wrap(
        netuid, hotkey_pubkey, hotkey_ss58,
        config.PER_HOTKEY_TRANSFER_RAO, 1_500_000, "Parked: wrap failed",
    )
    shares = env.vault_shares(token_id)
    assert shares != 0, "no shares minted by the setup wrap"

    clone_coldkey = env.clone_coldkey(token_id)
    parked = env.stake(hotkey_pubkey, clone_coldkey, netuid)
    assert parked > 0, "the setup left no stake on the hotkey about to be stranded"

    successor_ss58 = extrinsics.keypair_ss58("//ParkedSuccessor")
    try:
        extrinsics.swap_hotkey_keep_stake(hotkey_ss58, successor_ss58)
    except (extrinsics.ExtrinsicError, AttributeError) as error:
        pytest.skip(f"this runtime cannot strand stake under an unowned hotkey: {error}")

    # The identity moved; the alpha did not.
    assert env.stake(hotkey_pubkey, clone_coldkey, netuid) == parked, (
        "the swap was meant to keep the stake in place"
    )

    assert extrinsics.hotkey_owner(hotkey_ss58) == "", "the swap left the hotkey owned"

    # The backing check is satisfied - the alpha is exactly where the record expects
    # it - so what fails is the chain refusing to move it.
    env.vault_send_expect_revert(
        2_500_000, "Parked: the exit should be refused while the hotkey has no owner",
        "unwrap(uint256,uint256,bytes32)", token_id, shares // 2, env.wrapper_substrate_coldkey,
    )

    # A signer with no part in any of this takes the abandoned hotkey. Nothing about
    # the claim is privileged, and it is the claim alone that reopens the position.
    stranger_ss58 = extrinsics.keypair_ss58(STRANGER_URI)
    extrinsics.associate_hotkey(hotkey_ss58, signer_uri=STRANGER_URI)
    assert extrinsics.hotkey_owner(hotkey_ss58) == stranger_ss58, (
        "the stranger's claim did not take"
    )
    assert env.stake(hotkey_pubkey, clone_coldkey, netuid) == parked, (
        "owning the hotkey must give no claim on the stake delegated under it"
    )

    env.vault_send(
        2_500_000, "Parked: the exit should succeed once the hotkey is owned again",
        "unwrap(uint256,uint256,bytes32)", token_id, shares // 2, env.wrapper_substrate_coldkey,
    )
    assert env.vault_shares(token_id) < shares, "the exit burned no shares"
