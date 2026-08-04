"""Scenario: dust cannot lock the vault.

Tests that no dust state can permanently block deposits or withdrawals, in
three scenarios (one test each, all sharing the session localnet on separate
subnets):
  1. A position reduced to dust under a validator that dropped out of the
     set: the alpha exit is refused cheaply with a clear error, the TAO
     exit still pays out in full, and the vault works normally afterwards.
  2. A market crash that devalues a position below the chain's minimum:
     the alpha exit is refused clearly instead of failing forever, the TAO
     exit still pays out, and deposits keep working at the crashed price.
  3. A small holder alongside a large one, its slice below the minimum:
     both exits refuse without touching the large holder's backing, and a
     top-up lets the small holder leave in full; the large holder exits
     unharmed.
"""
import pytest

from alpha_e2e import bootstrap, chain, config
from alpha_e2e.checks import (
    assert_gas_within, assert_payout_matches_emitted, assert_payout_near_quote, min_tao_out_for,
)
from alpha_e2e.substrate import h160_to_ss58, h160_to_substrate_b32


@pytest.mark.scenario
def test_rotated_out_dust_cannot_lock_the_vault(env):
    chain_min_stake = env.chain_min_stake_tao()
    print(f"  chain minimum stake = {chain_min_stake} RAO")

    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    rotated_out_hotkey_pubkey = env.hotkey_pubkeys[0]
    rotated_out_hotkey_ss58 = env.hotkey_ss58s[0]
    kept_hotkey_b_pubkey = env.hotkey_pubkeys[1]
    kept_hotkey_b_ss58 = env.hotkey_ss58s[1]
    kept_hotkey_c_pubkey = env.hotkey_pubkeys[2]

    # A fresh validator to take the dust hotkey's slot after the rotation.
    replacement_pubkey, _ = bootstrap.register_hotkey(netuid, "hk_e2e_1d")
    print(f"  Registered replacement validator {replacement_pubkey[:18]}... on netuid {netuid}")

    _, floor_boundary_alpha = env.floor_boundary(netuid, chain_min_stake)
    # 1.5x the boundary clears the deposit floor while every corrective move toward
    # the 50/30/20 split stays below it, keeping the whole deposit on the
    # soon-rotated hotkey.
    initial_deposit = floor_boundary_alpha * 3 // 2
    env.deposit_and_wrap(
        netuid, rotated_out_hotkey_pubkey, rotated_out_hotkey_ss58, initial_deposit,
        1_500_000, "Rotated-out dust: wrap failed",
    )

    # Burn 5/6 of the shares, then rotate: the leftover is sub-floor dust on a
    # rotated-out hotkey and there is no fresh deposit to consolidate it - the
    # worst stranded state the vault can reach.
    clone_coldkey = env.clone_coldkey(token_id)
    partial_burn = env.vault_shares(token_id) * 5 // 6
    env.vault_send(
        2_500_000, "Rotated-out dust: partial unwrap failed",
        "unwrap(uint256,uint256,bytes32)", token_id, partial_burn, env.wrapper_substrate_coldkey,
    )
    dust_residue = env.stake(rotated_out_hotkey_pubkey, clone_coldkey, netuid)
    assert env.alpha_value_tao(netuid, dust_residue) < chain_min_stake, (
        f"Rotated-out dust: residual {dust_residue} alpha RAO is not sub-floor"
    )
    env.set_validators(
        netuid, [replacement_pubkey, kept_hotkey_b_pubkey, kept_hotkey_c_pubkey],
        [5000, 3000, 2000],
    )
    print(f"  Position is now {dust_residue} alpha RAO of dust under a rotated-out hotkey")

    remaining_shares = env.vault_shares(token_id)
    refusal_receipt = env.assert_vault_reverts_with(
        "ConsolidationBelowFloor()", 1_500_000,
        "Rotated-out dust: alpha exit did NOT revert as ConsolidationBelowFloor",
        "unwrap(uint256,uint256,bytes32)",
        token_id, remaining_shares, env.wrapper_substrate_coldkey,
    )
    assert_gas_within(
        refusal_receipt, config.REVERT_GAS_BOUND, "Rotated-out dust: alpha-exit refusal",
    )
    print("  Alpha exit refused up front as ConsolidationBelowFloor, without burning "
          "the gas budget")

    # The TAO exit needs no consolidation and full drains are floor-exempt on the
    # chain: it must pay out even from this state.
    tao_exit_quote = env.alpha_to_tao_quote(netuid, env.vault_total_stake(token_id))
    min_tao_out = min_tao_out_for(tao_exit_quote)
    balance_before = env.user_tao_wei()
    tao_exit_receipt = env.vault_send(
        2_500_000, "Rotated-out dust: TAO exit failed from the dust state",
        "unwrapForTao(uint256,uint256,uint256)", token_id, remaining_shares, min_tao_out,
    )
    balance_after = env.user_tao_wei()
    assert_payout_near_quote(
        balance_before, balance_after, tao_exit_receipt, tao_exit_quote,
        "Rotated-out dust: TAO exit payout off quote",
    )
    assert_payout_matches_emitted(
        balance_before, balance_after, tao_exit_receipt,
        "Rotated-out dust: TAO exit paid less than it reported",
    )
    assert env.vault_shares(token_id) == 0, "Rotated-out dust: shares not fully burned"
    rotated_out_leftover = env.stake(rotated_out_hotkey_pubkey, clone_coldkey, netuid)
    assert rotated_out_leftover <= config.ROUNDING_DUST_SLOT_RAO, (
        f"Rotated-out dust: rotated-out hotkey still holds stake after the TAO exit "
        f"({rotated_out_leftover} RAO)"
    )
    total_leftover = env.vault_total_stake(token_id)
    assert total_leftover <= config.ROUNDING_DUST_TOTAL_RAO, (
        f"Rotated-out dust: stake left behind after the TAO exit ({total_leftover} RAO)"
    )
    print("  TAO exit drained the dust in full and paid out per the chain quote")

    # The token stays fully usable after the episode.
    _, floor_boundary_alpha = env.floor_boundary(netuid, chain_min_stake)
    retry_deposit = floor_boundary_alpha * 3 // 2
    env.deposit_and_wrap(
        netuid, kept_hotkey_b_pubkey, kept_hotkey_b_ss58, retry_deposit, 1_500_000,
        "Rotated-out dust: follow-up wrap failed",
    )
    env.vault_send(
        2_500_000, "Rotated-out dust: follow-up unwrap failed",
        "unwrap(uint256,uint256,bytes32)",
        token_id, env.vault_shares(token_id), env.wrapper_substrate_coldkey,
    )
    print("  Round-trip after the dust episode: wrap and unwrap both clean")


@pytest.mark.scenario
def test_price_crash_cannot_lock_exits(env):
    chain_min_stake = env.chain_min_stake_tao()

    netuid = env.netuids[1]
    token_id = env.token_ids[1]
    position_hotkey_pubkey = env.hotkey_pubkeys[3]
    position_hotkey_ss58 = env.hotkey_ss58s[3]
    sell_hotkey_pubkey = env.hotkey_pubkeys[4]
    sell_hotkey_ss58 = env.hotkey_ss58s[4]

    crash_price, floor_boundary_alpha = env.floor_boundary(netuid, chain_min_stake)
    # Just above the floor, so a sell that roughly halves the price (the crash
    # helper's reach) drops the whole position well under it.
    crash_deposit = floor_boundary_alpha * 12 // 10
    env.deposit_and_wrap(
        netuid, position_hotkey_pubkey, position_hotkey_ss58, crash_deposit, 1_500_000,
        "Price crash: wrap failed",
    )
    print(f"  Healthy position wrapped at price {crash_price}")

    # Alice dumps alpha until the whole position is worth less than the floor -
    # devalued by the market alone, with no stake moved.
    env.crash_price_until_below(
        netuid, sell_hotkey_pubkey, sell_hotkey_ss58,
        env.vault_total_stake(token_id), chain_min_stake * 9 // 10, "Price crash",
    )
    crashed_value = env.alpha_value_tao(netuid, env.vault_total_stake(token_id))
    print(f"  Position devalued to {crashed_value} RAO, below the {chain_min_stake} RAO floor")

    crashed_shares = env.vault_shares(token_id)
    refusal_receipt = env.assert_vault_reverts_with(
        "WithdrawTooSmall()", 1_500_000,
        "Price crash: alpha exit did NOT revert as WithdrawTooSmall",
        "unwrap(uint256,uint256,bytes32)",
        token_id, crashed_shares, env.wrapper_substrate_coldkey,
    )
    assert_gas_within(refusal_receipt, config.REVERT_GAS_BOUND, "Price crash: alpha-exit refusal")
    print("  Alpha exit refused up front as WithdrawTooSmall, without burning the gas budget")

    tao_exit_quote = env.alpha_to_tao_quote(netuid, env.vault_total_stake(token_id))
    min_tao_out = min_tao_out_for(tao_exit_quote)
    balance_before = env.user_tao_wei()
    tao_exit_receipt = env.vault_send(
        2_500_000, "Price crash: TAO exit failed at the crashed price",
        "unwrapForTao(uint256,uint256,uint256)", token_id, crashed_shares, min_tao_out,
    )
    balance_after = env.user_tao_wei()
    assert_payout_near_quote(
        balance_before, balance_after, tao_exit_receipt, tao_exit_quote,
        "Price crash: TAO exit payout off quote",
    )
    assert_payout_matches_emitted(
        balance_before, balance_after, tao_exit_receipt,
        "Price crash: TAO exit paid less than it reported",
    )
    assert env.vault_shares(token_id) == 0, "Price crash: shares not fully burned"
    total_leftover = env.vault_total_stake(token_id)
    assert total_leftover <= config.ROUNDING_DUST_TOTAL_RAO, (
        f"Price crash: stake left behind after the TAO exit ({total_leftover} RAO)"
    )
    print("  TAO exit paid out the devalued position in full")

    # Deposits and alpha exits keep working at the crashed price.
    _, floor_boundary_alpha = env.floor_boundary(netuid, chain_min_stake)
    retry_deposit = floor_boundary_alpha * 3 // 2
    env.deposit_and_wrap(
        netuid, position_hotkey_pubkey, position_hotkey_ss58, retry_deposit, 1_500_000,
        "Price crash: post-crash wrap failed",
    )
    post_crash_shares = env.vault_shares(token_id)
    quoted_alpha, _ = env.preview_unwrap(token_id, post_crash_shares)
    env.vault_send(
        2_500_000, "Price crash: post-crash unwrap failed",
        "unwrap(uint256,uint256,bytes32)",
        token_id, post_crash_shares, env.wrapper_substrate_coldkey,
    )
    delivered = env.total_stake_across(
        env.wrapper_substrate_coldkey, netuid,
        [position_hotkey_pubkey, sell_hotkey_pubkey, env.hotkey_pubkeys[5]],
    )
    assert delivered >= quoted_alpha - config.ROUNDING_DUST_TOTAL_RAO, (
        f"Price crash: post-crash unwrap delivered {delivered} against a quote of {quoted_alpha}"
    )
    print(f"  Post-crash round-trip clean: wrap accepted, unwrap delivered {delivered} alpha RAO")


@pytest.mark.scenario
def test_sub_floor_co_holder_cannot_be_locked_in_or_leak_the_other_holder(env):
    chain_min_stake = env.chain_min_stake_tao()
    assert chain.cast_wallet_address(config.SECOND_HOLDER_PRIVATE_KEY) == config.SECOND_HOLDER_ADDRESS, (
        "holder-2 key/address mismatch"
    )

    netuid = env.netuids[2]
    token_id = env.token_ids[2]
    position_hotkey_pubkey = env.hotkey_pubkeys[6]
    position_hotkey_ss58 = env.hotkey_ss58s[6]
    sell_hotkey_pubkey = env.hotkey_pubkeys[7]
    second_holder_coldkey = h160_to_substrate_b32(config.SECOND_HOLDER_ADDRESS)

    chain.btcli(
        ["wallet", "transfer", "--wallet-name", config.ALICE_WALLET,
         "--dest", h160_to_ss58(config.SECOND_HOLDER_ADDRESS), "--amount", "10",
         "--allow-death", "--no-prompt"],
        check=True,
    )
    print("  Funded holder 2 with 10 TAO for gas")

    _, floor_boundary_alpha = env.floor_boundary(netuid, chain_min_stake)
    # The large holder's corrective moves (3x and 2x the boundary) land, so the
    # position carries a real 50/30/20 split; the small holder sits just above
    # the floor.
    large_deposit = floor_boundary_alpha * 10
    small_deposit = floor_boundary_alpha * 12 // 10
    env.deposit_and_wrap(
        netuid, position_hotkey_pubkey, position_hotkey_ss58, large_deposit, 2_500_000,
        "Co-holder: large wrap failed",
    )
    env.deposit_and_wrap(
        netuid, position_hotkey_pubkey, position_hotkey_ss58, small_deposit, 1_500_000,
        "Co-holder: small wrap failed",
        user=config.SECOND_HOLDER_ADDRESS, private_key=config.SECOND_HOLDER_PRIVATE_KEY,
    )
    print(f"  Two holders wrapped: large {large_deposit}, small {small_deposit} alpha RAO")

    # Selling most of a healthy position leaves the seller with a slice worth less than
    # the chain will move or sell. The large co-holder's stake deepens the pool, so a
    # market sell could not devalue the slice this far; a share sale gets there without
    # touching the price.
    small_holder_shares_before = env.vault_shares(token_id, config.SECOND_HOLDER_ADDRESS)
    env.transfer_shares(
        token_id, config.SECOND_HOLDER_ADDRESS, config.WRAPPER_USER_ADDRESS,
        small_holder_shares_before * 2 // 3, "Co-holder: share sale failed",
        private_key=config.SECOND_HOLDER_PRIVATE_KEY,
    )

    small_holder_value = env.alpha_value_tao(
        netuid, env.holder_assets(token_id, config.SECOND_HOLDER_ADDRESS),
    )
    large_holder_value = env.alpha_value_tao(
        netuid, env.holder_assets(token_id, config.WRAPPER_USER_ADDRESS),
    )
    assert small_holder_value < chain_min_stake, (
        f"Co-holder: small slice not below the floor "
        f"({small_holder_value} RAO, floor {chain_min_stake})"
    )
    assert large_holder_value >= chain_min_stake * 2, (
        f"Co-holder: large holder not clear of the floor ({large_holder_value} RAO)"
    )
    print(f"  Small holder sold down to {small_holder_value} RAO, below the "
          f"{chain_min_stake} RAO floor; large holder healthy at {large_holder_value} RAO")

    # Both rails refuse the sub-floor slice: the chain cannot move or sell that
    # little, and force-selling it would sweep value out of the co-holder's backing.
    small_holder_shares = env.vault_shares(token_id, config.SECOND_HOLDER_ADDRESS)
    alpha_refusal_receipt = env.assert_vault_reverts_with(
        "WithdrawTooSmall()", 1_500_000,
        "Co-holder: sub-floor alpha exit did NOT revert as WithdrawTooSmall",
        "unwrap(uint256,uint256,bytes32)", token_id, small_holder_shares, second_holder_coldkey,
        private_key=config.SECOND_HOLDER_PRIVATE_KEY, sender=config.SECOND_HOLDER_ADDRESS,
    )
    assert_gas_within(
        alpha_refusal_receipt, config.REVERT_GAS_BOUND, "Co-holder: alpha-exit refusal",
    )
    tao_refusal_receipt = env.assert_vault_reverts_with(
        "WithdrawTooSmall()", 2_500_000,
        "Co-holder: sub-floor TAO exit did NOT revert as WithdrawTooSmall",
        "unwrapForTao(uint256,uint256,uint256)", token_id, small_holder_shares, 1,
        private_key=config.SECOND_HOLDER_PRIVATE_KEY, sender=config.SECOND_HOLDER_ADDRESS,
    )
    assert_gas_within(
        tao_refusal_receipt, config.REVERT_GAS_BOUND, "Co-holder: TAO-exit refusal",
    )
    print("  Both exits refused the sub-floor slice cleanly")

    large_holder_assets_before = env.holder_assets(token_id, config.WRAPPER_USER_ADDRESS)

    # Escape: topping up past the floor unlocks a full exit on the alpha rail.
    _, floor_boundary_alpha = env.floor_boundary(netuid, chain_min_stake)
    top_up_deposit = floor_boundary_alpha * 2
    env.deposit_and_wrap(
        netuid, position_hotkey_pubkey, position_hotkey_ss58, top_up_deposit, 1_500_000,
        "Co-holder: top-up wrap failed",
        user=config.SECOND_HOLDER_ADDRESS, private_key=config.SECOND_HOLDER_PRIVATE_KEY,
    )
    small_holder_shares = env.vault_shares(token_id, config.SECOND_HOLDER_ADDRESS)
    small_holder_quote, _ = env.preview_unwrap(token_id, small_holder_shares)
    env.vault_send(
        2_500_000, "Co-holder: post-top-up exit failed",
        "unwrap(uint256,uint256,bytes32)",
        token_id, small_holder_shares, second_holder_coldkey,
        private_key=config.SECOND_HOLDER_PRIVATE_KEY,
    )
    assert env.vault_shares(token_id, config.SECOND_HOLDER_ADDRESS) == 0, (
        "Co-holder: small holder shares not fully burned"
    )
    small_holder_delivered = env.total_stake_across(
        second_holder_coldkey, netuid,
        [position_hotkey_pubkey, sell_hotkey_pubkey, env.hotkey_pubkeys[8]],
    )
    assert small_holder_delivered >= small_holder_quote - config.ROUNDING_DUST_TOTAL_RAO, (
        f"Co-holder: top-up exit delivered {small_holder_delivered} against a quote of "
        f"{small_holder_quote}"
    )
    print(f"  Top-up unlocked the alpha exit: small holder left in full "
          f"({small_holder_delivered} alpha RAO delivered)")

    # The episode must not have cost the large holder anything.
    large_holder_assets_after = env.holder_assets(token_id, config.WRAPPER_USER_ADDRESS)
    assert large_holder_assets_after >= (
        large_holder_assets_before - config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO
    ), "Co-holder: large holder's backing shrank"

    large_exit_quote = env.alpha_to_tao_quote(netuid, large_holder_assets_after)
    min_tao_out = min_tao_out_for(large_exit_quote)
    balance_before = env.user_tao_wei()
    large_exit_receipt = env.vault_send(
        2_500_000, "Co-holder: large holder's exit failed",
        "unwrapForTao(uint256,uint256,uint256)",
        token_id, env.vault_shares(token_id), min_tao_out,
    )
    balance_after = env.user_tao_wei()
    assert_payout_near_quote(
        balance_before, balance_after, large_exit_receipt, large_exit_quote,
        "Co-holder: large holder's payout off quote",
    )
    assert_payout_matches_emitted(
        balance_before, balance_after, large_exit_receipt,
        "Co-holder: large holder's exit paid less than it reported",
    )
    total_leftover = env.vault_total_stake(token_id)
    assert total_leftover <= config.ROUNDING_DUST_TOTAL_RAO, (
        f"Co-holder: stake left behind after both holders exited ({total_leftover} RAO)"
    )
    print("  Large holder exited in full; vault position fully drained")
