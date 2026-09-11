"""Creation rejects contaminated candidates and leaves accepted clones nothing a swap can target.

A fresh vault is used so the scenario can poison the first candidates on the subnet.
Stake and conviction can sit on different hotkeys; neither may be imported into
accepted backing through a poisoned candidate. A fresh UID selects a clean candidate.
"""
import secrets
import time
from dataclasses import replace

import pytest

from alpha_e2e import bootstrap, chain, config, extrinsics
from alpha_e2e.substrate import h160_to_account_id, h160_to_ss58, h160_to_substrate_b32

SWAP_DELAY_BLOCKS = 5
CLONE_DONOR = "//CloneCandidateDonor"
MAILBOX_DONOR = "//MailboxCandidateDonor"
SWAP_DONOR = "//PostDeploymentSwapDonor"
LOCKED_HOLDER = "//LockedHolder"
SWAP_REFUSALS = ("NewColdKeyIsHotkey", "ColdKeyAlreadyAssociated")


def _uid() -> str:
    return "0x" + secrets.token_hex(32)


def _swap_into(signer_uri: str, destination: str) -> None:
    started = chain.cast_block_number()
    extrinsics.announce_coldkey_swap(h160_to_account_id(destination), signer_uri=signer_uri)
    deadline = time.time() + 300
    while chain.cast_block_number() < started + SWAP_DELAY_BLOCKS + 2:
        assert time.time() < deadline, "coldkey swap announcement did not mature"
        time.sleep(1)
    extrinsics.swap_coldkey_announced(h160_to_ss58(destination), signer_uri=signer_uri)


def _candidates(factory: str, token_id: int, netuid: int, uid: str):
    """The addresses a creation with this UID would deploy, derived the way the factory does."""
    clone_salt = chain.cast_keccak(chain.cast_abi_encode("f(string,uint256,bytes32)", "subnet-v1", token_id, uid))
    mailbox_salt = chain.cast_keccak(chain.cast_abi_encode(
        "f(string,address,uint256,bytes32)", "mailbox-v1", config.WRAPPER_USER_ADDRESS, netuid, uid,
    ))
    clone = chain.create2_clone_address(factory, chain.cast_call(factory, "subnetLogic()(address)"), clone_salt)
    mailbox = chain.create2_clone_address(factory, chain.cast_call(factory, "mailboxLogic()(address)"), mailbox_salt)
    return clone, mailbox


def _protected(env, address: str) -> None:
    coldkey = h160_to_substrate_b32(address)
    owner = chain.cast_call_lines(
        config.STAKING_PRECOMPILE, "getHotkeyOwner(bytes32)(bool,bytes32)", coldkey,
    )
    assert owner[0] == "true"
    assert owner[1].lower() == coldkey.lower(), "a clone owns its own account as a hotkey"
    assert chain.cast_call(
        config.STAKING_PRECOMPILE, "getRejectLockedAlpha(bytes32)(bool)", coldkey,
    ) == "true"
    assert env.stake(env.hotkey_pubkeys[0], coldkey, env.netuids[0]) == 0


@pytest.mark.scenario
def test_locked_deposit(env, recovery_window):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkey = env.hotkey_pubkeys[0]
    hotkey_ss58 = env.hotkey_ss58s[0]
    gift_hotkey = env.hotkey_pubkeys[-1]
    gift_hotkey_ss58 = env.hotkey_ss58s[-1]
    assert gift_hotkey != hotkey, "scenario needs a gift key outside the first subnet's attested set"
    _, _, _, contracts, _ = bootstrap._deploy_contracts(
        [netuid], env.subnet_hotkey_pubkeys(0), recovery_window=recovery_window
    )
    env = replace(
        env, vault_address=contracts.vault_address, lens_address=contracts.lens_address,
        validator_registry_address=contracts.validator_registry_address,
    )
    factory = chain.cast_call(env.vault_address, "cloneFactory()(address)")
    extrinsics.set_coldkey_swap_announcement_delay(SWAP_DELAY_BLOCKS)
    for uri in (CLONE_DONOR, MAILBOX_DONOR, SWAP_DONOR, LOCKED_HOLDER):
        extrinsics.fund_account(extrinsics.keypair_ss58(uri), 30 * 10**9)
    for uri in (CLONE_DONOR, MAILBOX_DONOR, LOCKED_HOLDER):
        extrinsics.set_reject_locked_alpha(False, signer_uri=uri)
        extrinsics.add_stake(gift_hotkey_ss58, netuid, 20 * 10**9, signer_uri=uri)
        alpha = env.stake(gift_hotkey, extrinsics.keypair_pubkey(uri), netuid)
        extrinsics.lock_stake(hotkey_ss58, netuid, alpha, signer_uri=uri)
        extrinsics.set_perpetual_lock(netuid, True, signer_uri=uri)

    # Before deployment: a gift with a differently named conviction cannot become backing.
    poisoned_uid = _uid()
    poisoned_clone, _ = _candidates(factory, token_id, netuid, poisoned_uid)
    _swap_into(CLONE_DONOR, poisoned_clone)
    assert env.stake(gift_hotkey, h160_to_substrate_b32(poisoned_clone), netuid) > 0
    env.assert_vault_reverts_with(
        "CloneContaminated(address)", 2_000_000, "contaminated subnet candidate was accepted",
        "createMailbox(uint256,bytes32)", netuid, poisoned_uid,
    )
    assert int(env.clone_address(token_id), 16) == 0
    assert int(env.mailbox_address(netuid), 16) == 0

    # A poisoned mailbox rolls back the shared clone created earlier in the same transaction.
    mailbox_uid = _uid()
    _, poisoned_mailbox = _candidates(factory, token_id, netuid, mailbox_uid)
    _swap_into(MAILBOX_DONOR, poisoned_mailbox)
    env.assert_vault_reverts_with(
        "CloneContaminated(address)", 2_000_000, "contaminated mailbox candidate was accepted",
        "createMailbox(uint256,bytes32)", netuid, mailbox_uid,
    )
    assert int(env.clone_address(token_id), 16) == 0
    assert int(env.mailbox_address(netuid), 16) == 0

    env.vault_send(
        2_000_000, "fresh UID did not prepare protected addresses", "createMailbox(uint256,bytes32)",
        netuid, _uid(),
    )
    clone = env.clone_address(token_id)
    mailbox = env.mailbox_address(netuid)
    assert clone.lower() != poisoned_clone.lower()
    assert mailbox.lower() != poisoned_mailbox.lower()
    _protected(env, clone)
    _protected(env, mailbox)
    extrinsics.associate_hotkey(h160_to_ss58(clone), signer_uri=LOCKED_HOLDER)
    _protected(env, clone)
    print("  A stranger's association attempt leaves the self-owned clone untouched")
    env.vault_send(2_000_000, "idempotent creation failed", "createMailbox(uint256,bytes32)", netuid, _uid())
    assert env.clone_address(token_id) == clone
    assert env.mailbox_address(netuid) == mailbox

    # After deployment, even an empty, TAO-only subnet clone rejects a coldkey swap.
    extrinsics.fund_account(h160_to_ss58(clone), 10**9)
    with pytest.raises(extrinsics.ExtrinsicError) as refused:
        _swap_into(SWAP_DONOR, clone)
    assert any(reason in str(refused.value) for reason in SWAP_REFUSALS), str(refused.value)

    # Locked alpha cannot be transferred into either accepted clone.
    locked_alpha = env.stake(gift_hotkey, extrinsics.keypair_pubkey(LOCKED_HOLDER), netuid)
    for destination in (mailbox, clone):
        with pytest.raises(extrinsics.ExtrinsicError) as refused:
            extrinsics.transfer_stake(
                h160_to_ss58(destination), gift_hotkey_ss58, netuid, locked_alpha // 2, signer_uri=LOCKED_HOLDER,
            )
        assert "AccountRejectsLockedAlpha" in str(refused.value), str(refused.value)

    env.deposit_and_wrap(netuid, hotkey, hotkey_ss58, 10 * 10**9, 1_500_000, "honest wrap failed")
    shares = env.vault_shares(token_id)
    assert shares > 0
    assert env.vault_total_stake(token_id) >= 9 * 10**9
    before = env.total_stake_across(env.wrapper_substrate_coldkey, netuid, env.subnet_hotkey_pubkeys(0))
    env.vault_send(
        2_500_000, "honest exit failed", "unwrap(uint256,uint256,bytes32,uint256)",
        token_id, shares, env.wrapper_substrate_coldkey, 1,
    )
    received = env.total_stake_across(env.wrapper_substrate_coldkey, netuid, env.subnet_hotkey_pubkeys(0)) - before
    assert received >= 9 * 10**9
    assert env.vault_shares(token_id) == 0
    assert env.stake(gift_hotkey, h160_to_substrate_b32(poisoned_clone), netuid) > 0, "rejected gift never entered backing"
    _protected(env, clone)
