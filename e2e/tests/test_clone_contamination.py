"""Scenario: what an unprotected deposit address costs the people who use it.

Every address the vault hands out is an ordinary Substrate account long before it
holds anything. The chain lets any coldkey swap onto an account that holds no
stake and is not a hotkey, and that swap carries the source's conviction lock and
its accept-locked-alpha flag onto the destination without asking. Deployed EVM
code changes none of that: the chain looks at the stake, never at the code.

Conviction-locked alpha cannot be unstaked, and a same-subnet transfer drags the
lock along once the sender's unlocked alpha runs out. An account refuses locked
alpha unless it has opted in, and that refusal happens inside the precompile,
which burns the whole gas the caller forwarded.

Two legs, each against its own freshly deployed vault on its own subnet:

  mailbox   a stranger parks a lock in the address the vault told one user to
            fund. That user can no longer wrap, and cannot reclaim to their own
            coldkey; the deposit leaves only to an account that accepts locks,
            where it arrives locked and unsellable.

  clone     a stranger makes the shared subnet clone accept locked alpha, mints
            shares against locked alpha, and exits with the unlocked alpha that
            an honest holder deposited. What is left cannot be withdrawn, while
            the vault's own books still price it as if it could.
"""
import time
from dataclasses import replace

import pytest

from alpha_e2e import bootstrap, chain, config, extrinsics
from alpha_e2e.environment import read_stake
from alpha_e2e.substrate import h160_to_account_id, h160_to_ss58, h160_to_substrate_b32

SWAP_DELAY_BLOCKS = 5
SWAP_MATURITY_TIMEOUT_SECONDS = 300

MAILBOX_DONOR = "//MailboxLockDonor"
CLONE_FLAG_DONOR = "//CloneFlagDonor"
ATTACKER_LOCK_DONOR = "//AttackerLockDonor"
LOCK_TOLERANT_HOME = "//LockTolerantHome"

DONOR_FUNDING_RAO = 60 * 10**9
DONOR_STAKE_RAO = 40 * 10**9
HONEST_DEPOSIT_RAO = 20 * 10**9
ATTACKER_GAS_FUNDING_RAO = 10 * 10**9

WRAP_GAS = 1_500_000
UNWRAP_GAS = 2_500_000
RECLAIM_GAS = 1_500_000
# A refused precompile dispatch consumes everything forwarded to it, which is what
# separates the chain refusing a transfer from the vault declining one cheaply.
BURNED_GAS_NUMERATOR = 9
BURNED_GAS_DENOMINATOR = 10
# Share arithmetic drops about a RAO per hop; totals are compared with this much slack.
DUST_RAO = 10


def _swap_into(signer_uri: str, destination: str) -> None:
    """Move the signer's whole coldkey -- stake, locks, flags and TAO -- onto the
    Substrate account behind an EVM address the signer does not control."""
    started = chain.cast_block_number()
    extrinsics.announce_coldkey_swap(h160_to_account_id(destination), signer_uri=signer_uri)
    deadline = time.time() + SWAP_MATURITY_TIMEOUT_SECONDS
    while chain.cast_block_number() < started + SWAP_DELAY_BLOCKS + 2:
        assert time.time() < deadline, "coldkey swap announcement did not mature"
        time.sleep(1)
    extrinsics.swap_coldkey_announced(h160_to_ss58(destination), signer_uri=signer_uri)


def _lock_and_swap_into(
    signer_uri: str, destination: str, netuid: int, hotkey: str, hotkey_ss58: str,
) -> int:
    """Stake, conviction-lock, then hand the whole account to `destination`. Returns
    the alpha that arrives there, all of it locked."""
    extrinsics.fund_account(extrinsics.keypair_ss58(signer_uri), DONOR_FUNDING_RAO)
    extrinsics.add_stake(hotkey_ss58, netuid, DONOR_STAKE_RAO, signer_uri=signer_uri)
    staked = read_stake(hotkey, extrinsics.keypair_pubkey(signer_uri), netuid)
    assert staked > 0, f"{signer_uri} staked nothing to lock"
    extrinsics.lock_stake(hotkey_ss58, netuid, staked, signer_uri=signer_uri)
    # A decaying lock would drain away mid-scenario and stop the outcome being deterministic.
    extrinsics.set_perpetual_lock(netuid, True, signer_uri=signer_uri)
    _swap_into(signer_uri, destination)
    return staked


def _fresh_vault(env, netuid: int, subnet_index: int):
    """A vault of this build serving one subnet, so a leg can poison addresses no
    other leg or scenario shares."""
    _, _, _, contracts, _ = bootstrap._deploy_contracts(
        [netuid], env.subnet_hotkey_pubkeys(subnet_index),
    )
    return replace(
        env,
        vault_address=contracts.vault_address,
        lens_address=contracts.lens_address,
        validator_registry_address=contracts.validator_registry_address,
    )


def _assert_burned_all_gas(receipt: dict, gas_limit: int, message: str) -> None:
    used = chain.receipt_gas_used(receipt)
    floor = gas_limit * BURNED_GAS_NUMERATOR // BURNED_GAS_DENOMINATOR
    assert used is not None and used >= floor, (
        f"{message}: used {used} of {gas_limit}, so the chain never reached the transfer"
    )


@pytest.mark.scenario
def test_poisoned_mailbox_strands_its_owners_deposit(env):
    netuid = env.netuids[0]
    hotkey = env.hotkey_pubkeys[0]
    hotkey_ss58 = env.hotkey_ss58s[0]
    env = _fresh_vault(env, netuid, 0)
    extrinsics.set_coldkey_swap_announcement_delay(SWAP_DELAY_BLOCKS)

    # --- The vault publishes the address before anything exists at it ----------------
    mailbox = env.mailbox_address(netuid)
    mailbox_coldkey = h160_to_substrate_b32(mailbox)
    mailbox_ss58 = h160_to_ss58(mailbox)
    assert chain.cast_code(mailbox) == "0x", "the deposit address is a prediction, not a contract"
    print(f"  User's published deposit address: {mailbox} (no code, no owner)")

    # --- A stranger parks a perpetual lock in it -------------------------------------
    donor_alpha = _lock_and_swap_into(MAILBOX_DONOR, mailbox, netuid, hotkey, hotkey_ss58)
    parked_lock = extrinsics.get_lock(mailbox_ss58, netuid, hotkey_ss58)
    assert parked_lock > 0, "the swap did not carry the stranger's lock onto the deposit address"
    assert env.stake(hotkey, mailbox_coldkey, netuid) >= donor_alpha - DUST_RAO, (
        "the stranger's alpha did not land in the user's deposit address"
    )
    print(f"  A stranger's coldkey swap parked {parked_lock} RAO of locked alpha there")

    # --- The user funds it, exactly as the user guide tells them to ------------------
    extrinsics.transfer_stake(mailbox_ss58, hotkey_ss58, netuid, HONEST_DEPOSIT_RAO)
    pooled = env.stake(hotkey, mailbox_coldkey, netuid)
    assert pooled >= donor_alpha + HONEST_DEPOSIT_RAO - DUST_RAO

    # --- Their deposit can no longer be wrapped --------------------------------------
    # wrap collects the whole hotkey balance, which now exceeds the unlocked part, so the
    # transfer into the subnet clone drags the lock and the clone refuses it.
    wrap_receipt = env.vault_send_expect_revert(
        WRAP_GAS, "a poisoned mailbox still wrapped", "wrap(uint256,bytes32,uint256)",
        netuid, hotkey, 0,
    )
    _assert_burned_all_gas(wrap_receipt, WRAP_GAS, "wrap did not reach the refused transfer")
    assert env.vault_shares(env.current_token_id(netuid)) == 0, "no shares should exist"
    print("  wrap is refused by the chain and burns every unit of gas forwarded to it")

    # --- Nor reclaimed to the address the user actually controls ---------------------
    reclaim_receipt = env.vault_send_expect_revert(
        RECLAIM_GAS, "a lock-refusing coldkey still received locked alpha",
        "reclaimAlphaFromMailbox(uint256,bytes32,bytes32)",
        netuid, hotkey, env.wrapper_substrate_coldkey,
    )
    _assert_burned_all_gas(
        reclaim_receipt, RECLAIM_GAS, "reclaim did not reach the refused transfer",
    )
    assert env.stake(hotkey, mailbox_coldkey, netuid) >= HONEST_DEPOSIT_RAO, (
        "the deposit should still be stranded in the mailbox"
    )
    print("  reclaim to the user's own coldkey is refused too: the deposit is stranded")

    # --- It leaves only to an account that accepts conviction locks ------------------
    extrinsics.fund_account(extrinsics.keypair_ss58(LOCK_TOLERANT_HOME), DONOR_FUNDING_RAO)
    extrinsics.set_reject_locked_alpha(False, signer_uri=LOCK_TOLERANT_HOME)
    home_pubkey = extrinsics.keypair_pubkey(LOCK_TOLERANT_HOME)
    home_ss58 = extrinsics.keypair_ss58(LOCK_TOLERANT_HOME)
    env.vault_send(
        RECLAIM_GAS, "reclaim to a lock-accepting coldkey failed",
        "reclaimAlphaFromMailbox(uint256,bytes32,bytes32)", netuid, hotkey, home_pubkey,
    )
    recovered = read_stake(hotkey, home_pubkey, netuid)
    assert recovered >= HONEST_DEPOSIT_RAO, "the rescue account did not receive the deposit"

    # --- And it arrives carrying the stranger's lock ---------------------------------
    inherited_lock = extrinsics.get_lock(home_ss58, netuid, hotkey_ss58)
    assert inherited_lock > 0, "the lock should have travelled with the alpha"
    with pytest.raises(extrinsics.ExtrinsicError) as refused:
        extrinsics.remove_stake(hotkey_ss58, netuid, recovered, signer_uri=LOCK_TOLERANT_HOME)
    assert "StakeUnavailable" in str(refused.value), str(refused.value)
    print(f"  Recovered {recovered} RAO, of which {inherited_lock} RAO is locked and unsellable")


@pytest.mark.scenario
def test_poisoned_subnet_clone_pays_an_attacker_with_holder_alpha(env):
    subnet_index = 1
    netuid = env.netuids[subnet_index]
    first_validator = subnet_index * config.VALIDATORS_PER_SUBNET
    hotkey = env.hotkey_pubkeys[first_validator]
    hotkey_ss58 = env.hotkey_ss58s[first_validator]
    env = _fresh_vault(env, netuid, subnet_index)
    extrinsics.set_coldkey_swap_announcement_delay(SWAP_DELAY_BLOCKS)

    token_id = env.current_token_id(netuid)
    clone = env.clone_address(token_id)
    clone_coldkey = h160_to_substrate_b32(clone)
    clone_ss58 = h160_to_ss58(clone)
    subnet_hotkeys = env.subnet_hotkey_pubkeys(subnet_index)

    # --- Deployed EVM code does not stop a coldkey swap into an empty account --------
    assert chain.cast_code(clone) != "0x", "the shared subnet clone is a deployed contract"
    assert env.total_stake_across(clone_coldkey, netuid, subnet_hotkeys) == 0
    extrinsics.fund_account(extrinsics.keypair_ss58(CLONE_FLAG_DONOR), DONOR_FUNDING_RAO)
    extrinsics.set_reject_locked_alpha(False, signer_uri=CLONE_FLAG_DONOR)
    _swap_into(CLONE_FLAG_DONOR, clone)
    assert extrinsics.account_flags(clone_ss58) & 1 == 1, (
        "the swap should have copied the accept-locked-alpha flag onto the deployed clone"
    )
    print(f"  The pooled account {clone} now accepts locked alpha, without the vault's consent")

    # --- An honest holder deposits ordinary, unlocked alpha --------------------------
    env.deposit_and_wrap(
        netuid, hotkey, hotkey_ss58, HONEST_DEPOSIT_RAO, WRAP_GAS, "honest wrap failed",
    )
    honest_shares = env.vault_shares(token_id)
    assert honest_shares > 0
    assert env.vault_total_stake(token_id) >= HONEST_DEPOSIT_RAO - DUST_RAO
    print(f"  Honest holder deposited {HONEST_DEPOSIT_RAO} RAO of unlocked alpha")

    # --- The attacker loads their own mailbox with locked alpha ----------------------
    attacker = config.SECOND_HOLDER_ADDRESS
    attacker_coldkey = h160_to_substrate_b32(attacker)
    attacker_ss58 = h160_to_ss58(attacker)
    extrinsics.fund_account(attacker_ss58, ATTACKER_GAS_FUNDING_RAO)
    attacker_mailbox = env.mailbox_address(netuid, attacker)
    locked_alpha = _lock_and_swap_into(
        ATTACKER_LOCK_DONOR, attacker_mailbox, netuid, hotkey, hotkey_ss58,
    )
    assert 0 < locked_alpha < HONEST_DEPOSIT_RAO, (
        f"the scenario needs a lock the honest deposit can cover: {locked_alpha} RAO locked "
        f"against a {HONEST_DEPOSIT_RAO} RAO deposit"
    )

    # --- Locked alpha mints ordinary shares ------------------------------------------
    env.vault_send(
        WRAP_GAS, "the vault refused the attacker's locked deposit",
        "wrap(uint256,bytes32,uint256)", netuid, hotkey, 0,
        private_key=config.SECOND_HOLDER_PRIVATE_KEY,
    )
    attacker_shares = env.vault_shares(token_id, attacker)
    assert attacker_shares > 0, "locked alpha should have minted shares on this build"
    pooled_lock = extrinsics.get_lock(clone_ss58, netuid, hotkey_ss58)
    assert pooled_lock > 0, "the lock followed the alpha into the pooled account"
    print(f"  {locked_alpha} RAO of locked alpha minted {attacker_shares} shares; the pool "
          f"now carries a {pooled_lock} RAO lock")

    # --- The attacker exits with unlocked alpha --------------------------------------
    # Their own coldkey refuses locked alpha, so a successful exit proves what left was
    # unlocked: the honest holder's deposit, not the alpha the attacker put in.
    attacker_before = env.total_stake_across(attacker_coldkey, netuid, subnet_hotkeys)
    env.vault_send(
        UNWRAP_GAS, "attacker exit failed", "unwrap(uint256,uint256,bytes32,uint256)",
        token_id, attacker_shares, attacker_coldkey, 0,
        private_key=config.SECOND_HOLDER_PRIVATE_KEY,
    )
    attacker_after = env.total_stake_across(attacker_coldkey, netuid, subnet_hotkeys)
    attacker_gain = attacker_after - attacker_before
    assert attacker_gain >= locked_alpha * 9 // 10, (
        f"attacker withdrew {attacker_gain} RAO against {locked_alpha} RAO of locked input"
    )
    assert extrinsics.get_lock(attacker_ss58, netuid, hotkey_ss58) == 0, (
        "the attacker walked away with no lock at all"
    )
    print(f"  Attacker turned {locked_alpha} RAO of locked alpha into {attacker_gain} RAO "
          f"of unlocked alpha")

    # --- The lock stays behind, on the honest holder's backing -----------------------
    stranded_lock = extrinsics.get_lock(clone_ss58, netuid, hotkey_ss58)
    pooled_alpha = env.total_stake_across(clone_coldkey, netuid, subnet_hotkeys)
    assert stranded_lock >= locked_alpha * 9 // 10, "the lock should still sit on the pool"
    assert env.vault_total_stake(token_id) >= pooled_alpha - DUST_RAO, (
        "the vault still prices the locked mass as ordinary backing"
    )
    print(f"  Pool holds {pooled_alpha} RAO for the honest holder, {stranded_lock} RAO locked")

    # --- The honest holder cannot get their deposit back -----------------------------
    exit_receipt = env.vault_send_expect_revert(
        UNWRAP_GAS, "the honest holder's full exit should be refused",
        "unwrap(uint256,uint256,bytes32,uint256)",
        token_id, honest_shares, env.wrapper_substrate_coldkey, 0,
    )
    _assert_burned_all_gas(exit_receipt, UNWRAP_GAS, "the exit never reached the refused transfer")

    # Only the part the lock does not cover can still leave, which pins the lock as the
    # boundary rather than some unrelated failure.
    unlocked_share = honest_shares * (pooled_alpha - stranded_lock) // pooled_alpha
    withdrawable_shares = unlocked_share * 8 // 10
    assert withdrawable_shares > 0
    env.vault_send(
        UNWRAP_GAS, "the unlocked remainder should still pay out",
        "unwrap(uint256,uint256,bytes32,uint256)",
        token_id, withdrawable_shares, env.wrapper_substrate_coldkey, 0,
    )
    print(f"  The honest holder can withdraw only the unlocked remainder; {stranded_lock} RAO "
          f"stays frozen behind a lock they never agreed to")
