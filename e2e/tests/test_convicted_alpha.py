"""Scenario: convicted (conviction-locked) alpha.

Conviction locks bind a coldkey's subnet-wide alpha, and contract-controlled
coldkeys reject locked inflow (the accept-locked flag defaults OFF and no
precompile can flip it). A deposit dipping into locked mass therefore reverts
at the depositor's own transferStake, before the vault is involved; the free
portion wraps normally; and vault flows -- rebalance, unwrap (including to a
coldkey that itself holds a lock), unwrapForTao -- never touch lock state.

  Phase 6   Alice locks all but a movable margin of her subnet stake
  Phase 7   depositing MORE than the movable amount is refused by the chain,
            atomically, and the following wrap reverts on the empty mailbox
  Phase 8   the movable portion of the locked wallet wraps normally
  Phase 9   unwrap pays out to a coldkey that HOLDS an active lock
  Phase 10  unwrapForTao works while a large lock exists on the subnet
"""
import pytest

from alpha_e2e import checks, config, extrinsics, substrate
from alpha_e2e.substrate import h160_to_ss58, h160_to_substrate_b32

UNLOCKED_MARGIN_RAO = 30_000_000_000  # 30 alpha


def _alice_locked_alpha(netuid: int, hotkey_ss58: str) -> int:
    return extrinsics.get_lock(config.ALICE_COLDKEY_SS58, netuid, hotkey_ss58)


@pytest.mark.scenario
def test_convicted_alpha(env):
    test_netuid = env.netuids[0]
    test_token_id = env.token_ids[0]
    test_hotkey_pubkey = env.hotkey_pubkeys[0]
    test_hotkey_ss58 = env.hotkey_ss58s[0]

    user_mailbox = env.mailbox_address(test_netuid)
    user_mailbox_coldkey = h160_to_substrate_b32(user_mailbox)
    user_mailbox_ss58 = h160_to_ss58(user_mailbox)
    alice_owner_hotkey_pubkey = substrate.read_hotkey_pubkey(
        config.ALICE_WALLET, config.ALICE_HOTKEY_NAME,
    )

    def alice_subnet_alpha() -> int:
        # Locks bind Alice's subnet-wide alpha across ALL her hotkeys, including
        # the subnet-owner hotkey. The subnet-wide TAO-value getter cannot size
        # the lock: it returns TAO value, not the alpha the lock is denominated in.
        return env.total_stake_across(
            config.ALICE_COLDKEY_PUBKEY, test_netuid,
            [alice_owner_hotkey_pubkey, *env.subnet_hotkey_pubkeys(0)],
        )

    # --- Phase 6: Alice locks all but the movable margin of her subnet stake ------
    alice_subnet_alpha_before_lock = alice_subnet_alpha()
    assert alice_subnet_alpha_before_lock >= 2 * UNLOCKED_MARGIN_RAO, (
        "Alice's subnet stake too small to lock meaningfully"
    )
    lock_amount_rao = alice_subnet_alpha_before_lock - UNLOCKED_MARGIN_RAO

    print(f"  Alice subnet total: {alice_subnet_alpha_before_lock} RAO; locking "
          f"{lock_amount_rao} RAO to {test_hotkey_ss58[:12]}... (margin {UNLOCKED_MARGIN_RAO})")
    extrinsics.lock_stake(test_hotkey_ss58, test_netuid, lock_amount_rao)

    initial_locked_alpha = _alice_locked_alpha(test_netuid, test_hotkey_ss58)
    assert initial_locked_alpha == lock_amount_rao, (
        f"lock not registered exactly (asked {lock_amount_rao}, stored {initial_locked_alpha})"
    )
    print(f"  Lock live on chain: {initial_locked_alpha} RAO locked "
          f"(movable margin ~ {UNLOCKED_MARGIN_RAO} RAO + emissions)")

    # --- Phase 7: depositing MORE than the movable amount is refused by the chain --
    # The chain clamps: a transfer within the movable amount passes legitimately,
    # so the refused transfer must exceed movable (which keeps growing with emissions).
    over_movable_amount = env.stake(test_hotkey_pubkey, config.ALICE_COLDKEY_PUBKEY, test_netuid)
    alice_movable_alpha = max(
        0, alice_subnet_alpha() - _alice_locked_alpha(test_netuid, test_hotkey_ss58),
    )
    assert over_movable_amount >= alice_movable_alpha + 2 * UNLOCKED_MARGIN_RAO, (
        f"premise broken: Alice's test-hotkey stake does not exceed movable "
        f"({alice_movable_alpha} RAO) by 2x margin"
    )

    mailbox_alpha_before = env.stake(test_hotkey_pubkey, user_mailbox_coldkey, test_netuid)
    assert mailbox_alpha_before == 0, (
        f"mailbox not virgin before the refused transfer ({mailbox_alpha_before} RAO)"
    )

    print(f"  Attempting to transfer {over_movable_amount} RAO "
          "(Alice's full test-hotkey stake) into the mailbox...")
    with pytest.raises(extrinsics.ExtrinsicError) as refused_transfer:
        extrinsics.transfer_stake(
            user_mailbox_ss58, test_hotkey_ss58, test_netuid, over_movable_amount,
        )
    assert "AccountRejectsLockedAlpha" in str(refused_transfer.value), (
        f"transferStake reverted but not with AccountRejectsLockedAlpha: "
        f"{refused_transfer.value}"
    )
    print("  Chain refused the over-movable transfer (mailbox rejects locked inflow by default)")

    mailbox_alpha_after = env.stake(test_hotkey_pubkey, user_mailbox_coldkey, test_netuid)
    assert mailbox_alpha_after == mailbox_alpha_before, (
        f"mailbox balance changed by a refused transfer "
        f"({mailbox_alpha_before} -> {mailbox_alpha_after} RAO)"
    )
    alice_test_hotkey_stake_after = env.stake(
        test_hotkey_pubkey, config.ALICE_COLDKEY_PUBKEY, test_netuid,
    )
    assert alice_test_hotkey_stake_after >= over_movable_amount, (
        "Alice's stake decreased despite the refused transfer"
    )
    print(f"  Refusal was atomic: mailbox unchanged ({mailbox_alpha_after} RAO), "
          "Alice's stake intact")

    shares_before_reverted_wrap = env.vault_shares(test_token_id)
    env.vault_send_expect_revert(
        1_500_000, "wrap with no arrived deposit did NOT revert",
        "wrap(uint256,bytes32,uint256)", test_netuid, test_hotkey_pubkey, 0,
    )
    shares_after_reverted_wrap = env.vault_shares(test_token_id)
    assert shares_after_reverted_wrap == shares_before_reverted_wrap, (
        f"shares changed after a reverted wrap "
        f"({shares_before_reverted_wrap} -> {shares_after_reverted_wrap})"
    )
    print(f"  wrap reverted (the mailbox is provably empty); shares unchanged "
          f"({shares_after_reverted_wrap})")

    # --- Phase 8: the movable portion of the locked wallet wraps normally ----------
    movable_deposit_rao = UNLOCKED_MARGIN_RAO // 2
    env.deposit_and_wrap(
        test_netuid, test_hotkey_pubkey, test_hotkey_ss58, movable_deposit_rao,
        1_500_000, "wrap of the movable portion failed",
    )
    shares_after_movable_wrap = env.vault_shares(test_token_id)
    assert shares_after_movable_wrap > shares_after_reverted_wrap, (
        "no shares minted for the movable-portion wrap"
    )
    locked_alpha_after_movable_wrap = _alice_locked_alpha(test_netuid, test_hotkey_ss58)
    # Touching the lock re-persists its lazily-decayed locked amount (the decay is
    # about one part in a million per block); 99% is a generous floor here.
    assert locked_alpha_after_movable_wrap >= initial_locked_alpha // 100 * 99, (
        "Alice's lock shrank from a free-portion transfer"
    )
    assert initial_locked_alpha >= locked_alpha_after_movable_wrap, (
        "Alice's lock grew during a free-portion wrap (a lock migrated unexpectedly)"
    )
    print(f"  Movable portion wrapped: {shares_after_movable_wrap} shares; "
          "Alice's lock untouched")

    # --- Phase 9: unwrap pays out to a coldkey that HOLDS an active lock -----------
    total_shares = env.vault_shares(test_token_id)
    half_shares = total_shares // 2
    previewed_half_alpha, _ = env.preview_unwrap(test_token_id, half_shares)
    alice_subnet_alpha_before_unwrap = alice_subnet_alpha()

    env.vault_send(
        2_000_000, "unwrap to a lock-holding coldkey failed",
        "unwrap(uint256,uint256,bytes32)",
        test_token_id, half_shares, config.ALICE_COLDKEY_PUBKEY,
    )

    alice_received_alpha = alice_subnet_alpha() - alice_subnet_alpha_before_unwrap
    # Emissions between the reads only add, so the preview (less drift allowance)
    # is a safe lower bound proving a real half-position payout.
    assert alice_received_alpha >= previewed_half_alpha // 100 * 85, (
        f"unwrap paid a lock-holding coldkey far less than previewed "
        f"({alice_received_alpha} vs {previewed_half_alpha})"
    )
    locked_alpha_after_unwrap = _alice_locked_alpha(test_netuid, test_hotkey_ss58)
    assert locked_alpha_after_unwrap >= initial_locked_alpha // 100 * 99, (
        "Alice's lock disturbed by receiving unwrapped alpha"
    )
    assert initial_locked_alpha >= locked_alpha_after_unwrap, (
        "Alice's lock grew from receiving unwrapped alpha (a lock arrived with the transfer)"
    )
    print(f"  Locked coldkey received {alice_received_alpha} RAO unlocked alpha "
          f"(preview {previewed_half_alpha}); lock intact")

    # --- Phase 10: unwrapForTao works while a large lock exists on the subnet -------
    remaining_shares = env.vault_shares(test_token_id)
    previewed_remaining_alpha, _ = env.preview_unwrap(test_token_id, remaining_shares)
    remaining_tao_quote = env.alpha_to_tao_quote(test_netuid, previewed_remaining_alpha)

    user_tao_before = env.user_tao_wei()
    env.vault_send(
        2_500_000, "unwrapForTao failed on a subnet with active locks",
        "unwrapForTao(uint256,uint256,uint256)", test_token_id, remaining_shares, 0,
    )
    final_shares = env.vault_shares(test_token_id)
    assert final_shares == 0, f"shares still {final_shares} after unwrapForTao"

    tao_gained = checks.assert_tao_gain_near_quote(
        user_tao_before, env.user_tao_wei(), remaining_tao_quote,
        "unwrapForTao payout off the alpha->TAO quote",
    )
    print(f"  Remaining shares exited as TAO: gained {tao_gained} wei "
          f"(quote {remaining_tao_quote} RAO)")
