"""Scenario: alpha transfers switched off.

When a subnet's alpha transfers are disabled, the chain refuses to move
staked alpha between wallets but still allows selling it for TAO. The
vault's alpha rail (which delivers by moving staked alpha) is therefore
closed, but both TAO-rail exits still pay out: they only ever sell alpha
for TAO.

  Phase 6   seed a wrapped position in the deposit clone (transfers ON)
  Phase 7   seed raw alpha in the user's mailbox (transfers ON)
  Phase 8   switch alpha transfers OFF on every subnet and confirm the chain
            now refuses a raw stake transfer
  Phase 9   the alpha rail is closed: unwrap reverts with shares intact
  Phase 10  withdraw the deposit clone as TAO (unwrapForTao), payout on quote
  Phase 11  withdraw the mailbox itself as TAO (reclaimMailboxAlphaAsTao),
            payout on quote
"""
import pytest

from alpha_e2e import checks, config, extrinsics
from alpha_e2e.substrate import h160_to_ss58, h160_to_substrate_b32


@pytest.mark.scenario
def test_transfers_off(env):
    # --- Phase 6: seed a wrapped position in the deposit clone (transfers ON) ---
    position_netuid = env.netuids[0]
    position_token_id = env.token_ids[0]
    position_hotkey_pubkey = env.hotkey_pubkeys[0]
    position_hotkey_ss58 = env.hotkey_ss58s[0]

    env.deposit_and_wrap(
        position_netuid, position_hotkey_pubkey, position_hotkey_ss58,
        config.PER_HOTKEY_TRANSFER_RAO, 1_500_000, "wrap for transfers-off setup failed",
    )
    position_shares = env.vault_shares(position_token_id)
    assert position_shares != 0, f"no shares minted by wrap on netuid {position_netuid}"
    # Guard the Phase 9 premise: the position must actually back alpha, else unwrap
    # would revert early with NothingToUnwrap and the revert assertion would pass
    # for the wrong reason.
    position_total_stake = env.vault_total_stake(position_token_id)
    assert position_total_stake != 0, (
        f"wrap on netuid {position_netuid} left zero backing alpha"
    )
    print(f"  netuid {position_netuid} (tokenId {position_token_id}): "
          f"minted {position_shares} shares, backing {position_total_stake} RAO")

    # --- Phase 7: seed raw alpha in the user's mailbox (transfers ON) -----------
    seed_netuid = env.netuids[1]
    seed_hotkey_pubkey = env.hotkey_pubkeys[3]
    seed_hotkey_ss58 = env.hotkey_ss58s[3]

    seed_mailbox = env.mailbox_address(seed_netuid)
    seed_mailbox_coldkey = h160_to_substrate_b32(seed_mailbox)
    seed_mailbox_ss58 = h160_to_ss58(seed_mailbox)
    print(f"  User mailbox on netuid {seed_netuid}: {seed_mailbox}")

    extrinsics.transfer_stake(
        seed_mailbox_ss58, seed_hotkey_ss58, seed_netuid, config.PER_HOTKEY_TRANSFER_RAO,
    )
    seed_alpha = env.stake(seed_hotkey_pubkey, seed_mailbox_coldkey, seed_netuid)
    assert seed_alpha > 0, "mailbox has zero alpha after seeding"
    print(f"  Mailbox stake: {seed_alpha} RAO")

    # --- Phase 8: switch alpha transfers OFF on every subnet ---------------------
    for netuid in env.netuids:
        extrinsics.toggle_transfer(netuid, False)
        print(f"  netuid {netuid}: alpha transfers disabled")

    print(f"  Confirming raw transferStake now reverts on netuid {position_netuid}...")
    with pytest.raises(extrinsics.ExtrinsicError) as refused_transfer:
        extrinsics.transfer_stake(
            seed_mailbox_ss58, position_hotkey_ss58, position_netuid,
            config.PER_HOTKEY_TRANSFER_RAO,
        )
    assert "TransferDisallowed" in str(refused_transfer.value), (
        f"transferStake reverted but not with TransferDisallowed: {refused_transfer.value}"
    )

    # --- Phase 9: the alpha rail is closed - unwrap must revert -------------------
    # The alpha rail ends in clone flush -> transferStake, which now reverts
    # TransferDisallowed (asserted directly in Phase 8), rolling back the whole
    # unwrap and leaving the shares intact.
    shares_before_revert = env.vault_shares(position_token_id)
    env.vault_send_expect_revert(
        2_000_000, "unwrap (alpha rail) did NOT revert with transfers off",
        "unwrap(uint256,uint256,bytes32)",
        position_token_id, shares_before_revert, env.wrapper_substrate_coldkey,
    )
    shares_after_revert = env.vault_shares(position_token_id)
    assert shares_after_revert == shares_before_revert, (
        f"shares changed after a reverted unwrap "
        f"({shares_before_revert} -> {shares_after_revert})"
    )
    print(f"  Alpha-rail unwrap reverted; shares preserved ({shares_after_revert})")

    # --- Phase 10: withdraw the deposit clone as TAO (unwrapForTao) ----------------
    # Live backing alpha this position will sell, and its alpha->TAO quote -- both
    # captured pre-swap.
    position_alpha, _ = env.preview_unwrap(position_token_id, position_shares)
    position_quote = env.alpha_to_tao_quote(position_netuid, position_alpha)

    user_tao_before = env.user_tao_wei()
    env.vault_send(
        2_500_000, "unwrapForTao failed with transfers off",
        "unwrapForTao(uint256,uint256,uint256)", position_token_id, position_shares, 0,
    )
    remaining_shares = env.vault_shares(position_token_id)
    assert remaining_shares == 0, f"shares still {remaining_shares} after unwrapForTao"

    gained = checks.assert_tao_gain_near_quote(
        user_tao_before, env.user_tao_wei(), position_quote,
        "unwrapForTao payout off the alpha->TAO quote",
    )
    print(f"  Deposit clone withdrawn as TAO; user gained {gained} wei "
          f"(matches quote {position_quote} RAO)")

    # --- Phase 11: withdraw the mailbox itself as TAO (reclaimMailboxAlphaAsTao) ---
    # Live mailbox alpha (re-read: accrued emissions since Phase 7) and its
    # alpha->TAO quote, both captured pre-swap.
    reclaim_alpha = env.stake(seed_hotkey_pubkey, seed_mailbox_coldkey, seed_netuid)
    reclaim_quote = env.alpha_to_tao_quote(seed_netuid, reclaim_alpha)

    user_tao_before = env.user_tao_wei()
    env.vault_send(
        1_500_000, "reclaimMailboxAlphaAsTao failed with transfers off",
        "reclaimMailboxAlphaAsTao(uint256,bytes32,uint256)",
        seed_netuid, seed_hotkey_pubkey, 0,
    )
    seed_alpha_after = env.stake(seed_hotkey_pubkey, seed_mailbox_coldkey, seed_netuid)
    # The chain rounds the sold amount down to whole shares, so a mailbox that has
    # been accruing emissions keeps a RAO or two of dust after the reclaim.
    assert seed_alpha_after <= config.ROUNDING_DUST_SLOT_RAO, (
        f"mailbox still holds {seed_alpha_after} RAO after reclaim"
    )

    gained = checks.assert_tao_gain_near_quote(
        user_tao_before, env.user_tao_wei(), reclaim_quote,
        "reclaim payout off the alpha->TAO quote",
    )
    print(f"  Mailbox withdrawn as TAO; user gained {gained} wei "
          f"(matches quote {reclaim_quote} RAO)")
