"""Scenario: the main full flow against a live localnet.

Walks the wrapper user through the vault's whole happy path -- deposits split
across three validators on three subnets, full alpha unwraps, both TAO-rail
exits, emission accrual, and a validator rotation -- and cross-checks the
emitted events against the observability scripts in scripts/:

  Phase 6   transfer alpha to the deposit mailboxes (split across 3 validators)
  Phase 7   wrap every deposit (one wrap per validator)
  Phase 8   verify shares / totalStake / sharePrice on every vault
  Phase 9   unwrap all shares and verify the alpha comes back in full
  Phase 10  observability scripts asserted row-by-row over the deposit window
  Phase 11  reclaim mailbox alpha as native TAO
  Phase 12  unwrap shares for native TAO (plus its volume report)
  Phase 13  emission accrual: the position appreciates and the gain is captured
  Phase 14  validator rotation: rotated-out stake is consolidated by the unwrap
  Phase 15  TAO-exit slippage guard against the real alpha->TAO price

Setup (chain, subnets, validators, contracts, funding) is the session `env`
fixture (alpha_e2e.bootstrap.build_environment); this test picks up right after it.
"""
import time

import pytest

from alpha_e2e import chain, checks, config, extrinsics
from alpha_e2e.checks import run_observability_script
from alpha_e2e.substrate import h160_to_ss58, h160_to_substrate_b32

# Phase 9's single full unwrap can leave a few RAO of per-slot rounding behind.
FULL_UNWRAP_TOLERANCE_RAO = 10


@pytest.mark.scenario
def test_full_flow(env):
    # --- Phase 6: transfer alpha to the deposit mailboxes (3 validators each) ---
    for subnet_index, netuid in enumerate(env.netuids):
        mailbox = env.mailbox_address(netuid)
        mailbox_coldkey = h160_to_substrate_b32(mailbox)
        mailbox_ss58 = h160_to_ss58(mailbox)
        print(f"  netuid {netuid} mailbox: {mailbox} ({mailbox_ss58})")

        for validator_index in range(config.VALIDATORS_PER_SUBNET):
            flat_index = subnet_index * config.VALIDATORS_PER_SUBNET + validator_index
            hotkey_pubkey = env.hotkey_pubkeys[flat_index]

            extrinsics.transfer_stake(
                mailbox_ss58, env.hotkey_ss58s[flat_index], netuid,
                config.PER_HOTKEY_TRANSFER_RAO,
            )
            mailbox_stake = env.stake(hotkey_pubkey, mailbox_coldkey, netuid)
            assert mailbox_stake != 0, (
                f"mailbox {mailbox} has 0 alpha under {hotkey_pubkey[:18]}... after transfer"
            )

    # --- Phase 7: process deposits (one wrap per validator) --------------------
    for subnet_index, netuid in enumerate(env.netuids):
        for hotkey_pubkey in env.subnet_hotkey_pubkeys(subnet_index):
            env.vault_send(
                1_000_000, f"wrap for netuid {netuid}, hotkey {hotkey_pubkey[:18]}... failed",
                "wrap(uint256,bytes32)", netuid, hotkey_pubkey,
            )

    # --- Phase 8: verify deposits ----------------------------------------------
    shares_by_subnet = []
    deposited_by_subnet = []
    for subnet_index, netuid in enumerate(env.netuids):
        token_id = env.token_ids[subnet_index]
        shares = env.vault_shares(token_id)
        total_stake = env.vault_total_stake(token_id)
        share_price = env.share_price(token_id)
        print(f"  netuid {netuid} (tokenId {token_id}): shares={shares} "
              f"totalStake={total_stake} RAO sharePrice={share_price}")

        assert shares != 0, f"netuid {netuid}: zero shares after wrap"
        assert total_stake != 0, f"netuid {netuid}: zero totalStake after wrap"
        assert share_price != 0, f"netuid {netuid}: zero sharePrice after wrap"

        shares_by_subnet.append(shares)
        deposited_by_subnet.append(total_stake)

    # --- Phase 9: unwrap all shares -> verify the alpha comes back --------------
    for subnet_index, netuid in enumerate(env.netuids):
        token_id = env.token_ids[subnet_index]
        shares = shares_by_subnet[subnet_index]
        deposited = deposited_by_subnet[subnet_index]

        env.vault_send(
            2_000_000, f"unwrap for netuid {netuid} failed",
            "unwrap(uint256,uint256,bytes32)",
            token_id, shares, env.wrapper_substrate_coldkey,
        )
        remaining_shares = env.vault_shares(token_id)
        assert remaining_shares == 0, (
            f"netuid {netuid}: shares still {remaining_shares} after full unwrap"
        )

        received = env.total_stake_across(
            env.wrapper_substrate_coldkey, netuid, env.subnet_hotkey_pubkeys(subnet_index),
        )
        assert received >= max(0, deposited - FULL_UNWRAP_TOLERANCE_RAO), (
            f"netuid {netuid}: user only received {received} RAO across 3 hotkeys; "
            f"expected >= {deposited - FULL_UNWRAP_TOLERANCE_RAO}"
        )
        print(f"  netuid {netuid}: received {received} RAO "
              f"(deposited {deposited}, tolerance {FULL_UNWRAP_TOLERANCE_RAO})")

    # --- Phase 10: observability scripts -----------------------------------------
    block_end = chain.cast_block_number()
    print(f"  Block range: [{env.observation_block_start}, {block_end}]")

    subnet_count = len(env.netuids)
    token_id_set = {str(token_id) for token_id in env.token_ids}
    vault_args = ["--vault-address", env.vault_address]

    checks.assert_csv(
        run_observability_script(
            "get_subnet_proxies",
            block_start=env.observation_block_start, block_end=block_end,
            address_args=vault_args,
        ),
        rows=subnet_count,
        column_sets={"token_id": token_id_set},
    )

    checks.assert_csv(
        run_observability_script(
            "get_deposits",
            block_start=env.observation_block_start, block_end=block_end,
            address_args=vault_args,
        ),
        rows=subnet_count * config.VALIDATORS_PER_SUBNET,
        column_sets={"token_id": token_id_set},
        column_eq={"user": config.WRAPPER_USER_ADDRESS},
        column_positive=["assets", "shares"],
    )

    checks.assert_csv(
        run_observability_script(
            "get_unwraps",
            block_start=env.observation_block_start, block_end=block_end,
            address_args=vault_args,
        ),
        rows=subnet_count,
        column_sets={"token_id": token_id_set},
        column_eq={"user": config.WRAPPER_USER_ADDRESS},
        column_positive=["alpha_out_rao", "shares"],
    )

    # Per netuid: 0 or 1 emission depending on whether the post-drain leftover
    # (emissions accrued between deposit and unwrap) clears the vault's tao stake
    # floor. Assert membership only.
    checks.assert_csv(
        run_observability_script(
            "get_rebalances",
            block_start=env.observation_block_start, block_end=block_end,
            address_args=vault_args,
        ),
        column_subsets={"token_id": token_id_set},
        column_positive=["amount"],
    )

    checks.assert_csv(
        run_observability_script(
            "get_validator_updates",
            block_start=env.registry_block_start, block_end=env.registry_block_end,
            address_args=["--registry-address", env.validator_registry_address],
        ),
        rows=subnet_count,
        column_sets={"netuid": {str(netuid) for netuid in env.netuids}},
        column_eq={"count": "3"},
        column_positive=["timestamp"],
    )

    for subnet_index, netuid in enumerate(env.netuids):
        token_id = env.token_ids[subnet_index]

        checks.assert_csv(
            run_observability_script(
                "get_volumes", "--netuid", str(netuid),
                block_start=env.observation_block_start, block_end=block_end,
                address_args=vault_args,
            ),
            rows=1,
            column_eq={
                "token_id": str(token_id),
                "user": "",
                "deposit_count": "3",
                "alpha_unwrap_count": "1",
                "tao_unwrap_count": "0",
                "dissolved_unwrap_count": "0",
                "unwrap_count": "1",
                "tao_received_wei": "0",
            },
            column_positive=[
                "alpha_deposited_rao", "shares_minted", "alpha_unwrapped_rao", "shares_burned",
            ],
        )

        checks.assert_csv(
            run_observability_script(
                "get_volumes", "--netuid", str(netuid), "--user", config.WRAPPER_USER_ADDRESS,
                block_start=env.observation_block_start, block_end=block_end,
                address_args=vault_args,
            ),
            rows=1,
            column_eq={
                "token_id": str(token_id),
                "user": config.WRAPPER_USER_ADDRESS,
                "deposit_count": "3",
                "alpha_unwrap_count": "1",
                "tao_unwrap_count": "0",
                "dissolved_unwrap_count": "0",
                "unwrap_count": "1",
            },
        )

        vault_state_csv = run_observability_script(
            "get_vault_state", "--netuid", str(netuid),
            address_args=[
                "--vault-address", env.vault_address,
                "--registry-address", env.validator_registry_address,
            ],
        )
        checks.assert_csv(
            vault_state_csv,
            rows=1,
            column_eq={
                "token_id": str(token_id),
                "total_supply": "0",
                "share_price": "",
                "share_price_error": "NoSharesOutstanding",
                "validators_count": "3",
            },
        )

    # --- Phase 11: reclaim mailbox alpha as TAO ------------------------------------
    reclaim_netuid = env.netuids[0]
    reclaim_hotkey_pubkey = env.hotkey_pubkeys[0]
    reclaim_hotkey_ss58 = env.hotkey_ss58s[0]

    reclaim_mailbox = env.mailbox_address(reclaim_netuid)
    reclaim_mailbox_coldkey = h160_to_substrate_b32(reclaim_mailbox)
    print(f"  User mailbox on netuid {reclaim_netuid}: {reclaim_mailbox}")

    extrinsics.transfer_stake(
        h160_to_ss58(reclaim_mailbox), reclaim_hotkey_ss58, reclaim_netuid,
        config.PER_HOTKEY_TRANSFER_RAO,
    )
    mailbox_alpha_before = env.stake(reclaim_hotkey_pubkey, reclaim_mailbox_coldkey, reclaim_netuid)
    assert mailbox_alpha_before > 0, "mailbox has zero alpha before reclaim"

    user_tao_before = env.user_tao_wei()
    env.vault_send(
        1_500_000, "reclaimMailboxAlphaAsTao failed",
        "reclaimMailboxAlphaAsTao(uint256,bytes32,uint256)",
        reclaim_netuid, reclaim_hotkey_pubkey, 0,
    )
    mailbox_alpha_after = env.stake(reclaim_hotkey_pubkey, reclaim_mailbox_coldkey, reclaim_netuid)
    assert mailbox_alpha_after == 0, (
        f"mailbox still holds {mailbox_alpha_after} RAO after reclaim"
    )
    gained = checks.assert_positive_gain(
        user_tao_before, env.user_tao_wei(), "user did not gain TAO from reclaim",
    )
    print(f"  User gained {gained} wei from the mailbox reclaim (net of gas)")

    # --- Phase 12: unwrap shares for TAO --------------------------------------------
    tao_exit_netuid = env.netuids[1]
    tao_exit_token_id = env.token_ids[1]
    tao_exit_hotkey_pubkey = env.hotkey_pubkeys[3]
    tao_exit_hotkey_ss58 = env.hotkey_ss58s[3]
    tao_exit_block_start = chain.cast_block_number()

    env.deposit_and_wrap(
        tao_exit_netuid, tao_exit_hotkey_pubkey, tao_exit_hotkey_ss58,
        config.PER_HOTKEY_TRANSFER_RAO, 1_500_000, "wrap for unwrapForTao setup failed",
    )
    tao_exit_shares = env.vault_shares(tao_exit_token_id)
    assert tao_exit_shares != 0, f"no shares minted by wrap on netuid {tao_exit_netuid}"

    user_tao_before = env.user_tao_wei()
    env.vault_send(
        2_500_000, "unwrapForTao failed",
        "unwrapForTao(uint256,uint256,uint256)", tao_exit_token_id, tao_exit_shares, 0,
    )
    remaining_shares = env.vault_shares(tao_exit_token_id)
    assert remaining_shares == 0, f"shares still {remaining_shares} after unwrapForTao"
    gained = checks.assert_positive_gain(
        user_tao_before, env.user_tao_wei(), "user did not gain TAO from unwrapForTao",
    )
    print(f"  User gained {gained} wei from unwrapForTao (net of gas)")

    tao_exit_block_end = chain.cast_block_number()
    checks.assert_csv(
        run_observability_script(
            "get_volumes", "--token-id", str(tao_exit_token_id),
            "--user", config.WRAPPER_USER_ADDRESS,
            block_start=tao_exit_block_start, block_end=tao_exit_block_end,
            address_args=vault_args,
        ),
        rows=1,
        column_eq={
            "token_id": str(tao_exit_token_id),
            "user": config.WRAPPER_USER_ADDRESS,
            "deposit_count": "1",
            "alpha_unwrap_count": "0",
            "tao_unwrap_count": "1",
            "dissolved_unwrap_count": "0",
            "unwrap_count": "1",
            "tao_from_dissolutions_wei": "0",
        },
        column_positive=[
            "alpha_sold_for_tao_rao", "tao_from_alpha_sales_wei", "tao_received_wei",
        ],
    )

    # --- Phase 13: emission accrual -> share-price appreciation (alpha rail) ---------
    # Real emissions accrue on the clone's staked alpha over blocks: the position
    # must appreciate above the deposit, and the holder must be able to unwrap that
    # gain. Mocks fake emissions, so only a live chain exercises this core
    # value-accrual property.
    emission_netuid = env.netuids[0]
    emission_token_id = env.token_ids[0]
    emission_hotkeys = env.subnet_hotkey_pubkeys(0)

    env.deposit_and_wrap(
        emission_netuid, env.hotkey_pubkeys[0], env.hotkey_ss58s[0],
        50_000_000_000, 1_500_000, "Phase 13 wrap failed",
    )
    emission_shares = env.vault_shares(emission_token_id)
    emission_deposited = env.vault_total_stake(emission_token_id)
    assert emission_shares != 0, "Phase 13: no shares minted"
    print(f"  Deposited 50 alpha -> shares={emission_shares}, "
          f"deposit-synced totalStake={emission_deposited} RAO")

    print("  Waiting ~30 blocks for emissions to accrue...")
    target_block = chain.cast_block_number() + 30
    while chain.cast_block_number() < target_block:
        time.sleep(1)

    previewed_alpha, _ = env.preview_unwrap(emission_token_id, emission_shares)
    assert previewed_alpha > emission_deposited, (
        f"Phase 13: no appreciation (previewUnwrap {previewed_alpha} <= "
        f"deposit {emission_deposited})"
    )

    # Sum the user's coldkey stake across the validators before and after, so the
    # payout is the delta.
    delivered_before = env.total_stake_across(
        env.wrapper_substrate_coldkey, emission_netuid, emission_hotkeys,
    )
    env.vault_send(
        2_000_000, "Phase 13 unwrap failed",
        "unwrap(uint256,uint256,bytes32)",
        emission_token_id, emission_shares, env.wrapper_substrate_coldkey,
    )
    delivered_after = env.total_stake_across(
        env.wrapper_substrate_coldkey, emission_netuid, emission_hotkeys,
    )
    emission_received = delivered_after - delivered_before
    assert emission_received > emission_deposited, (
        f"Phase 13: emissions not captured (received {emission_received} <= "
        f"deposit {emission_deposited})"
    )
    print(f"  User unwrapped {emission_received} RAO > deposited {emission_deposited} "
          "- appreciation captured on the alpha rail")

    # --- Phase 14: rotation leaves rotated-out stake -> unwrap consolidates it -------
    # Rotating a validator out of the registry strands the clone's stake under it.
    # The next unwrap must consolidate that rotated-out stake (real moveStake) and
    # still pay the holder full value.
    rotation_netuid = env.netuids[1]
    rotation_token_id = env.token_ids[1]
    kept_hotkey_first = env.hotkey_pubkeys[3]
    kept_hotkey_second = env.hotkey_pubkeys[4]
    rotated_out_hotkey = env.hotkey_pubkeys[5]

    env.deposit_and_wrap(
        rotation_netuid, kept_hotkey_first, env.hotkey_ss58s[3],
        60_000_000_000, 1_500_000, "Phase 14 wrap failed",
    )
    rotation_shares = env.vault_shares(rotation_token_id)
    rotation_deposited = env.vault_total_stake(rotation_token_id)
    rotation_clone_coldkey = env.clone_coldkey(rotation_token_id)
    rotated_out_stake = env.stake(rotated_out_hotkey, rotation_clone_coldkey, rotation_netuid)
    assert rotated_out_stake != 0, "Phase 14: no stake under the 3rd validator to rotate out"
    print(f"  Deposited 60 alpha -> shares={rotation_shares}; clone holds "
          f"{rotated_out_stake} RAO under the soon-rotated-out 3rd validator")

    # Drop the 3rd validator from the registry via a real EIP-712 attestation; no
    # vault call runs, so the vault's remembered set still references it and its
    # stake is left rotated out.
    env.set_validators(rotation_netuid, [kept_hotkey_first, kept_hotkey_second], [6000, 4000])

    rotation_hotkeys = [kept_hotkey_first, kept_hotkey_second, rotated_out_hotkey]
    delivered_before = env.total_stake_across(
        env.wrapper_substrate_coldkey, rotation_netuid, rotation_hotkeys,
    )
    env.vault_send(
        2_000_000, "Phase 14 unwrap failed",
        "unwrap(uint256,uint256,bytes32)",
        rotation_token_id, rotation_shares, env.wrapper_substrate_coldkey,
    )
    delivered_after = env.total_stake_across(
        env.wrapper_substrate_coldkey, rotation_netuid, rotation_hotkeys,
    )
    rotation_received = delivered_after - delivered_before
    rotated_out_stake_after = env.stake(
        rotated_out_hotkey, rotation_clone_coldkey, rotation_netuid,
    )

    # Phase 9's simpler single unwrap uses the tighter FULL_UNWRAP_TOLERANCE_RAO.
    assert rotation_received >= rotation_deposited - config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO, (
        f"Phase 14: rotated-out stake not consolidated (received {rotation_received} "
        f"<< deposit {rotation_deposited})"
    )
    assert rotated_out_stake_after == 0, (
        f"Phase 14: rotated-out stake NOT consolidated (3rd validator still holds "
        f"{rotated_out_stake_after} RAO)"
    )
    print(f"  Rotated-out stake consolidated; user received {rotation_received} RAO "
          f"(~ deposit {rotation_deposited}), rotated-out validator drained to 0")

    # --- Phase 15: unwrapForTao slippage guard against the real alpha->TAO price -----
    # minTaoOut must reject a payout below the threshold against the REAL realized
    # price. An unsatisfiable minTaoOut reverts with shares intact; minTaoOut=0 pays.
    slippage_netuid = env.netuids[2]
    slippage_token_id = env.token_ids[2]

    env.deposit_and_wrap(
        slippage_netuid, env.hotkey_pubkeys[6], env.hotkey_ss58s[6],
        40_000_000_000, 1_500_000, "Phase 15 wrap failed",
    )
    slippage_shares = env.vault_shares(slippage_token_id)
    assert slippage_shares != 0, "Phase 15: no shares minted"

    env.vault_send_expect_revert(
        2_500_000, "Phase 15: unwrapForTao with minTaoOut=1e30 did NOT revert",
        "unwrapForTao(uint256,uint256,uint256)",
        slippage_token_id, slippage_shares, 10**30,
    )
    shares_after_revert = env.vault_shares(slippage_token_id)
    assert shares_after_revert == slippage_shares, (
        f"Phase 15: shares changed after a reverted unwrapForTao "
        f"({slippage_shares} -> {shares_after_revert})"
    )

    user_tao_before = env.user_tao_wei()
    env.vault_send(
        2_500_000, "Phase 15 unwrapForTao(minTaoOut=0) failed",
        "unwrapForTao(uint256,uint256,uint256)", slippage_token_id, slippage_shares, 0,
    )
    final_shares = env.vault_shares(slippage_token_id)
    assert final_shares == 0, f"Phase 15: shares not burned ({final_shares})"
    gained = checks.assert_positive_gain(
        user_tao_before, env.user_tao_wei(), "Phase 15: user did not gain TAO",
    )
    print(f"  minTaoOut=0 paid {gained} wei net of gas against the real price; "
          "shares burned to 0")
