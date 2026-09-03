"""Scenario: subnet deregistration (dissolution).

Dissolving (deregistering) a subnet returns its staked alpha to holders as
native TAO. Two users wrap a shared position on one subnet, and raw alpha is
parked in a never-wrapped mailbox on another; the test dissolves both and
checks each user recovers their pro-rata share of the position, and the
parked (unprocessed) mailbox alpha is recoverable as native TAO too -- while
the alpha-based exits no longer apply (they revert without touching shares)
and a position on an untouched subnet keeps exiting normally.

  Phase 6   two users wrap positions on the soon-dissolved subnet
  Phase 7   park raw alpha in a never-wrapped mailbox on a second subnet
  Phase 8   seed a control position on a subnet that will NOT be dissolved
  Phase 9   dissolve both the position's subnet and the mailbox's subnet
  Phase 10  alpha-selling exits revert -- dissolution left no alpha to sell
  Phase 11  both users recover their pro-rata slice of the refund as native TAO
  Phase 12  recover the never-wrapped mailbox as native TAO
  Phase 13  the untouched subnet still exits normally (dissolution was scoped)
"""
import pytest

from alpha_e2e import chain, checks, config, extrinsics
from alpha_e2e.checks import run_observability_script
from alpha_e2e.substrate import h160_to_ss58, h160_to_substrate_b32


@pytest.mark.scenario
def test_subnet_dissolved(env):
    # --- Phase 6: two users wrap positions on the soon-dissolved subnet ---------
    dissolved_netuid = env.netuids[0]
    dissolved_token_id = env.token_ids[0]
    dissolved_hotkey_pubkey = env.hotkey_pubkeys[0]
    dissolved_hotkey_ss58 = env.hotkey_ss58s[0]
    volume_block_start = chain.cast_block_number()

    # The deployer key doubles as a second share-holder so the dissolved payout
    # splits pro-rata.
    second_user_address = config.DEPLOYER_ADDRESS
    second_user_private_key = config.DEPLOYER_PRIVATE_KEY

    env.deposit_and_wrap(
        dissolved_netuid, dissolved_hotkey_pubkey, dissolved_hotkey_ss58,
        config.PER_HOTKEY_TRANSFER_RAO, 1_500_000, "primary-user wrap failed",
    )
    env.deposit_and_wrap(
        dissolved_netuid, dissolved_hotkey_pubkey, dissolved_hotkey_ss58,
        config.PER_HOTKEY_TRANSFER_RAO, 1_500_000, "second-user wrap failed",
        user=second_user_address, private_key=second_user_private_key,
    )

    first_user_shares = env.vault_shares(dissolved_token_id)
    second_user_shares = env.vault_shares(dissolved_token_id, second_user_address)
    assert first_user_shares != 0, f"no shares minted for user1 on netuid {dissolved_netuid}"
    assert second_user_shares != 0, f"no shares minted for user2 on netuid {dissolved_netuid}"
    dissolved_clone = env.clone_address(dissolved_token_id)
    assert env.vault_total_stake(dissolved_token_id) != 0, (
        f"wrap on netuid {dissolved_netuid} left zero backing alpha"
    )
    assert chain.cast_balance_wei(dissolved_clone) == 0, (
        "clone holds native TAO before dissolution"
    )
    print(f"  netuid {dissolved_netuid} (tokenId {dissolved_token_id}): "
          f"user1 {first_user_shares} + user2 {second_user_shares} shares, "
          f"clone {dissolved_clone} backed by alpha")

    # --- Phase 7: park raw alpha in a never-wrapped mailbox on a second subnet ---
    parked_netuid = env.netuids[2]
    parked_hotkey_pubkey = env.hotkey_pubkeys[6]
    parked_hotkey_ss58 = env.hotkey_ss58s[6]
    parked_mailbox = env.mailbox_address(parked_netuid)
    parked_mailbox_coldkey = h160_to_substrate_b32(parked_mailbox)
    print(f"  User mailbox on netuid {parked_netuid}: {parked_mailbox}")

    extrinsics.transfer_stake(
        h160_to_ss58(parked_mailbox), parked_hotkey_ss58, parked_netuid,
        config.PER_HOTKEY_TRANSFER_RAO,
    )
    parked_alpha = env.stake(parked_hotkey_pubkey, parked_mailbox_coldkey, parked_netuid)
    assert parked_alpha > 0, "mailbox has zero alpha after seeding"
    print(f"  Mailbox stake: {parked_alpha} RAO under {parked_hotkey_pubkey[:18]}...")

    # --- Phase 8: seed a control position on a subnet that will NOT be dissolved --
    surviving_netuid = env.netuids[1]
    surviving_token_id = env.token_ids[1]

    env.deposit_and_wrap(
        surviving_netuid, env.hotkey_pubkeys[3], env.hotkey_ss58s[3],
        config.PER_HOTKEY_TRANSFER_RAO, 1_500_000, "wrap for the control position failed",
    )
    surviving_shares = env.vault_shares(surviving_token_id)
    assert surviving_shares != 0, f"no shares minted by wrap on netuid {surviving_netuid}"
    print(f"  netuid {surviving_netuid} (tokenId {surviving_token_id}): "
          f"{surviving_shares} shares")

    # --- Phase 9: dissolve both the position's subnet and the mailbox's subnet ----
    extrinsics.dissolve_network(dissolved_netuid)
    extrinsics.dissolve_network(parked_netuid)
    env.wait_for_dissolution_cleanup(dissolved_netuid)
    env.wait_for_dissolution_cleanup(parked_netuid)

    # Dissolution returns the position's and mailbox's alpha as native TAO to
    # their addresses, so those balances turn positive as the alpha is wiped.
    dissolved_clone_tao = chain.cast_balance_wei(dissolved_clone)
    parked_mailbox_tao = chain.cast_balance_wei(parked_mailbox)
    assert dissolved_clone_tao >= 1, "position clone received no TAO refund after dissolution"
    assert parked_mailbox_tao >= 1, "mailbox received no TAO refund after dissolution"
    assert env.vault_total_stake(dissolved_token_id) == 0, "totalStake nonzero after dissolution"

    share_price_probe = chain.run(
        ["cast", "call", env.lens_address, "sharePrice(uint256)(uint256)",
         str(dissolved_token_id), "--rpc-url", config.RPC_URL],
        check=False,
    )
    assert share_price_probe.returncode != 0, (
        "sharePrice did not revert for the dissolved subnet"
    )
    print(f"  Dissolved: position clone holds {dissolved_clone_tao} wei, mailbox "
          f"{parked_mailbox_tao} wei; alpha zeroed, sharePrice reverts")

    # --- Phase 10: alpha-selling exits revert - dissolution left no alpha to sell --
    env.vault_send_expect_revert(
        2_000_000, "unwrapForTao did NOT revert on the dissolved subnet",
        "unwrapForTao(uint256,uint256,uint256)", dissolved_token_id, first_user_shares, 0,
    )
    assert env.vault_shares(dissolved_token_id) == first_user_shares, (
        "shares changed after a reverted unwrapForTao"
    )

    env.vault_send_expect_revert(
        1_500_000, "reclaimMailboxAlphaAsTao did NOT revert on wiped mailbox alpha",
        "reclaimMailboxAlphaAsTao(uint256,bytes32,uint256)",
        parked_netuid, parked_hotkey_pubkey, 0,
    )
    print(f"  Alpha-selling exits reverted; position shares preserved ({first_user_shares})")

    # --- Phase 11: both users recover their pro-rata slice as native TAO ----------
    clone_tao_before = chain.cast_balance_wei(dissolved_clone)
    total_shares = first_user_shares + second_user_shares
    expected_first_user_tao = clone_tao_before * first_user_shares // total_shares

    _, previewed_tao = env.preview_unwrap(dissolved_token_id, first_user_shares)
    assert previewed_tao == expected_first_user_tao, (
        f"previewUnwrap tao ({previewed_tao}) != user1's pro-rata share "
        f"({expected_first_user_tao}) of clone {clone_tao_before}"
    )
    assert 0 < expected_first_user_tao < clone_tao_before, (
        f"dissolved payout did not split between holders "
        f"(share {expected_first_user_tao} of {clone_tao_before})"
    )

    first_user_tao_before = env.user_tao_wei()
    env.vault_send(
        2_000_000, "user1 dissolved unwrap failed",
        "unwrap(uint256,uint256,bytes32,uint256)",
        dissolved_token_id, first_user_shares, env.wrapper_substrate_coldkey, 0,
    )
    assert env.vault_shares(dissolved_token_id) == 0, (
        "user1 shares not burned after the dissolved unwrap"
    )
    first_user_gain = checks.assert_positive_gain(
        first_user_tao_before, env.user_tao_wei(),
        "user1 gained no TAO from the dissolved unwrap",
    )

    second_user_tao_before = chain.cast_balance_wei(second_user_address)
    env.vault_send(
        2_000_000, "user2 dissolved unwrap failed",
        "unwrap(uint256,uint256,bytes32,uint256)",
        dissolved_token_id, second_user_shares, env.wrapper_substrate_coldkey, 0,
        private_key=second_user_private_key,
    )
    assert env.vault_shares(dissolved_token_id, second_user_address) == 0, (
        "user2 shares not burned after the dissolved unwrap"
    )
    second_user_gain = checks.assert_positive_gain(
        second_user_tao_before, chain.cast_balance_wei(second_user_address),
        "user2 gained no TAO from the dissolved unwrap",
    )

    assert chain.cast_balance_wei(dissolved_clone) == 0, (
        "clone not fully drained after both users unwrapped"
    )
    print(f"  Pro-rata recovery: user1 +{first_user_gain} wei "
          f"(preview {expected_first_user_tao}), user2 +{second_user_gain} wei; "
          "clone drained to 0")

    volume_block_end = chain.cast_block_number()
    checks.assert_csv(
        run_observability_script(
            "get_volumes", "--token-id", str(dissolved_token_id),
            address_args=["--vault-address", env.vault_address],
            block_start=volume_block_start, block_end=volume_block_end,
        ),
        rows=1,
        column_eq={
            "token_id": str(dissolved_token_id),
            "user": "",
            "deposit_count": "2",
            "alpha_unwrap_count": "0",
            "tao_unwrap_count": "0",
            "dissolved_unwrap_count": "2",
            "unwrap_count": "2",
            "tao_from_alpha_sales_wei": "0",
        },
        column_positive=[
            "alpha_deposited_rao", "shares_minted", "dissolved_unwrap_shares_burned",
            "tao_from_dissolutions_wei", "shares_burned", "tao_received_wei",
        ],
    )
    print("  get_volumes reports dissolved TAO separately from live alpha volume")

    # --- Phase 12: recover the never-wrapped mailbox as native TAO -----------------
    assert chain.cast_code(parked_mailbox) == "0x", (
        "mailbox clone was materialized before reclaim - lazy-deploy path not exercised"
    )
    parked_mailbox_tao_before = chain.cast_balance_wei(parked_mailbox)
    user_tao_before = env.user_tao_wei()
    env.vault_send(
        2_000_000, "reclaimTaoFromMailbox failed",
        "reclaimTaoFromMailbox(uint256)", parked_netuid,
    )

    assert chain.cast_code(parked_mailbox) != "0x", (
        "reclaimTaoFromMailbox did not deploy the mailbox clone"
    )
    assert chain.cast_balance_wei(parked_mailbox) == 0, (
        "mailbox not fully drained after reclaimTaoFromMailbox"
    )
    gained = checks.assert_positive_gain(
        user_tao_before, env.user_tao_wei(),
        "user gained no TAO from reclaimTaoFromMailbox",
    )
    print(f"  Never-wrapped mailbox recovered ({parked_mailbox_tao_before} wei): "
          f"clone deployed on demand, user net +{gained} wei, mailbox drained to 0")

    # --- Phase 13: the untouched subnet still exits normally -----------------------
    surviving_alpha, _ = env.preview_unwrap(surviving_token_id, surviving_shares)

    user_tao_before = env.user_tao_wei()
    receipt = env.vault_send(
        2_500_000, "unwrapForTao on the surviving subnet failed",
        "unwrapForTao(uint256,uint256,uint256)", surviving_token_id, surviving_shares, 0,
    )
    assert env.vault_shares(surviving_token_id) == 0, (
        "shares still outstanding after unwrapForTao on the live subnet"
    )
    sold_alpha = checks.assert_payout_near_quote(
        user_tao_before, env.user_tao_wei(), receipt, surviving_netuid, surviving_alpha,
        "surviving-subnet unwrapForTao payout off the alpha->TAO quote",
    )
    print(f"  Surviving subnet sold {sold_alpha} alpha RAO at the chain's quote; "
          f"dissolution was scoped to netuid {dissolved_netuid}")
