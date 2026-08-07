"""Scenario: hostile dust cannot stop the vault.

Tests that alpha planted around the vault by a third party -- in a user's
deposit mailbox and on the vault's own staking account -- can never stop
deposits or withdrawals, even after a rotation and a price drop turn the
plant into sub-minimum dust the vault is forced to deal with:
  - a withdrawal consolidates the planted dust and delivers in full,
  - deposits keep working and ignore mailbox stake parked under other
    validators,
  - a mailbox plant too small to wrap is refused with a clear error and
    folds into the user's next real deposit,
  - every foreign coin ends up donated to the vault's holders, never the
    other way around.
"""
import pytest

from alpha_e2e import bootstrap, config, extrinsics
from alpha_e2e.checks import assert_gas_within
from alpha_e2e.substrate import h160_to_ss58, h160_to_substrate_b32


@pytest.mark.scenario
def test_hostile_dust(env):
    chain_min_stake = env.chain_min_stake_tao()
    print(f"  chain minimum stake = {chain_min_stake} RAO")

    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkey_a_pubkey = env.hotkey_pubkeys[0]
    hotkey_a_ss58 = env.hotkey_ss58s[0]
    hotkey_b_pubkey = env.hotkey_pubkeys[1]
    hotkey_b_ss58 = env.hotkey_ss58s[1]
    hotkey_c_pubkey = env.hotkey_pubkeys[2]
    hotkey_c_ss58 = env.hotkey_ss58s[2]

    # --- The victim builds a normal position on the 50/30/20 set -----------------
    # A fresh validator to take hotkey C's slot after the rotation.
    rotated_in_pubkey, _ = bootstrap.register_hotkey(netuid, "hk_e2e_1d")
    print(f"  Registered replacement validator {rotated_in_pubkey[:18]}... on netuid {netuid}")

    _, floor_boundary_alpha = env.floor_boundary(netuid, chain_min_stake)
    # 4.5x the boundary: the corrective move to B (1.35x) lands while the move to C
    # (0.9x) is floor-skipped, so C sits at zero while still in the set - a common
    # drifted split.
    victim_deposit = floor_boundary_alpha * 9 // 2
    victim_wrap_receipt = env.deposit_and_wrap(
        netuid, hotkey_a_pubkey, hotkey_a_ss58, victim_deposit, 1_500_000,
        "Hostile dust: victim wrap failed",
    )
    assert_gas_within(victim_wrap_receipt, config.WRAP_GAS_BOUND, "Hostile dust: victim wrap")
    clone_coldkey = env.clone_coldkey(token_id)
    assert env.stake(hotkey_c_pubkey, clone_coldkey, netuid) == 0, (
        "Hostile dust: expected the C slot to sit at zero after the floor-skipped move"
    )
    print("  Victim position split across A and B; C at zero via the floor-skipped move")

    # --- The attacker plants the smallest stake the chain allows ------------------
    # The chain floors every transfer, so the smallest plantable stake is
    # floor-sized; 1.2x leaves margin. One plant goes into the victim's mailbox
    # under B, one onto the vault's own staking account under C.
    plant = floor_boundary_alpha * 12 // 10
    victim_mailbox = env.mailbox_address(netuid)
    mailbox_coldkey = h160_to_substrate_b32(victim_mailbox)
    extrinsics.transfer_stake(h160_to_ss58(victim_mailbox), hotkey_b_ss58, netuid, plant)
    extrinsics.transfer_stake(
        h160_to_ss58(env.clone_address(token_id)), hotkey_c_ss58, netuid, plant,
    )
    print(f"  Planted {plant} alpha RAO in the victim's mailbox (under B) and on the "
          "clone (under C)")

    # Rotate C out, then push the price down: the clone plant becomes sub-floor
    # foreign rotated-out stake the vault must consolidate, and the mailbox plant
    # becomes too small to wrap on its own.
    env.set_validators(
        netuid, [hotkey_a_pubkey, hotkey_b_pubkey, rotated_in_pubkey], [5000, 3000, 2000],
    )
    env.crash_price_until_below(
        netuid, hotkey_a_pubkey, hotkey_a_ss58, plant, chain_min_stake * 8 // 10, "Hostile dust",
    )
    plant_value = env.alpha_value_tao(netuid, env.stake(hotkey_c_pubkey, clone_coldkey, netuid))
    richest_slot_value = env.alpha_value_tao(
        netuid, env.stake(hotkey_a_pubkey, clone_coldkey, netuid),
    )
    assert plant_value < chain_min_stake and richest_slot_value > chain_min_stake, (
        f"Hostile dust: bad crash split (plant {plant_value}, richest slot "
        f"{richest_slot_value}, floor {chain_min_stake})"
    )
    print(f"  Rotated-out C now holds sub-floor foreign stake ({plant_value} RAO); "
          "victim's slot stays healthy")

    # --- The victim's withdrawal consolidates the plant and delivers in full ------
    # One transaction must start the roll from the richest slot (not the plant),
    # absorb it, refresh the remembered set, gather across slots, and deliver. A
    # roll started from the plant would be rejected by the chain at full
    # forwarded-gas cost - the exact regression this leg pins.
    all_hotkeys = [hotkey_a_pubkey, hotkey_b_pubkey, hotkey_c_pubkey, rotated_in_pubkey]
    total_before = env.vault_total_stake(token_id)
    unwrap_burn = env.vault_shares(token_id) * 9 // 10
    quoted_first, _ = env.preview_unwrap(token_id, unwrap_burn)
    withdrawal_receipt = env.vault_send(
        2_500_000, "Hostile dust: withdrawal over the hostile plant failed",
        "unwrap(uint256,uint256,bytes32)", token_id, unwrap_burn, env.wrapper_substrate_coldkey,
    )
    assert_gas_within(
        withdrawal_receipt, config.UNWRAP_GAS_BOUND,
        "Hostile dust: withdrawal over the hostile plant",
    )
    delivered_first = env.total_stake_across(env.wrapper_substrate_coldkey, netuid, all_hotkeys)
    assert delivered_first >= quoted_first - config.ROUNDING_DUST_TOTAL_RAO, (
        f"Hostile dust: withdrawal delivered {delivered_first} against a quote of {quoted_first}"
    )
    plant_residue = env.stake(hotkey_c_pubkey, clone_coldkey, netuid)
    assert plant_residue <= config.ROUNDING_DUST_SLOT_RAO, (
        f"Hostile dust: hostile plant not consolidated ({plant_residue} RAO left)"
    )
    assert not env.hotkey_in_last_seen(token_id, hotkey_c_pubkey), (
        "Hostile dust: consolidated hotkey still present in lastSeenHotkeys"
    )
    total_after = env.vault_total_stake(token_id)
    assert total_after >= (
        total_before - delivered_first - config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO
    ), "Hostile dust: backing lost while absorbing the plant"
    print(f"  Withdrawal delivered {delivered_first} alpha RAO and absorbed the plant "
          "as a holder donation")

    # The remaining slice is sub-floor: the alpha rail refuses it cheaply (the TAO
    # rail and top-ups remain, as covered by the dust-DoS scenarios).
    refusal_receipt = env.assert_vault_reverts_with(
        "WithdrawTooSmall()", 1_500_000,
        "Hostile dust: sub-floor remainder did NOT revert as WithdrawTooSmall",
        "unwrap(uint256,uint256,bytes32)",
        token_id, env.vault_shares(token_id), env.wrapper_substrate_coldkey,
    )
    assert_gas_within(
        refusal_receipt, config.REVERT_GAS_BOUND, "Hostile dust: sub-floor remainder refusal",
    )
    print("  Sub-floor remainder refused up front on the alpha rail")

    # --- Deposits keep working and the mailbox plant stays inert -------------------
    # A wrap under A must ignore the mailbox stake parked under B: mailbox
    # accounting is per-hotkey.
    mailbox_plant_before = env.stake(hotkey_b_pubkey, mailbox_coldkey, netuid)
    _, floor_boundary_alpha = env.floor_boundary(netuid, chain_min_stake)
    fresh_deposit = floor_boundary_alpha * 3 // 2
    fresh_wrap_receipt = env.deposit_and_wrap(
        netuid, hotkey_a_pubkey, hotkey_a_ss58, fresh_deposit, 1_500_000,
        "Hostile dust: wrap alongside the mailbox plant failed",
    )
    assert_gas_within(
        fresh_wrap_receipt, config.WRAP_GAS_BOUND,
        "Hostile dust: wrap alongside the mailbox plant",
    )
    assert env.stake(hotkey_b_pubkey, mailbox_coldkey, netuid) >= mailbox_plant_before, (
        "Hostile dust: wrap under A touched the mailbox plant under B"
    )
    print("  Wrap under A succeeded and left the mailbox plant under B untouched")

    # On its own the devalued plant is too small to wrap; refused with the designed
    # error, cheaply.
    plant_refusal_receipt = env.assert_vault_reverts_with(
        "DepositTooSmall()", 1_500_000,
        "Hostile dust: sub-floor mailbox plant did NOT revert as DepositTooSmall",
        "wrap(uint256,bytes32)", netuid, hotkey_b_pubkey,
    )
    assert_gas_within(
        plant_refusal_receipt, config.REVERT_GAS_BOUND,
        "Hostile dust: sub-floor mailbox wrap refusal",
    )
    print("  Wrapping only the sub-floor mailbox plant refused as DepositTooSmall")

    # A real deposit under B folds the plant in: the victim gains it, and the
    # mailbox drains.
    merging_wrap_receipt = env.deposit_and_wrap(
        netuid, hotkey_b_pubkey, hotkey_b_ss58, fresh_deposit, 1_500_000,
        "Hostile dust: wrap merging the mailbox plant failed",
    )
    assert_gas_within(
        merging_wrap_receipt, config.WRAP_GAS_BOUND,
        "Hostile dust: wrap merging the mailbox plant",
    )
    mailbox_plant_after = env.stake(hotkey_b_pubkey, mailbox_coldkey, netuid)
    assert mailbox_plant_after <= config.ROUNDING_DUST_SLOT_RAO, (
        f"Hostile dust: mailbox plant not folded into the real deposit "
        f"({mailbox_plant_after} RAO left)"
    )
    print("  Real deposit under B absorbed the mailbox plant into the victim's position")

    # --- The full exit leaves nothing behind ----------------------------------------
    final_shares = env.vault_shares(token_id)
    quoted_final, _ = env.preview_unwrap(token_id, final_shares)
    final_exit_receipt = env.vault_send(
        2_500_000, "Hostile dust: final exit failed",
        "unwrap(uint256,uint256,bytes32)",
        token_id, final_shares, env.wrapper_substrate_coldkey,
    )
    assert_gas_within(final_exit_receipt, config.UNWRAP_GAS_BOUND, "Hostile dust: final exit")
    delivered_total = env.total_stake_across(env.wrapper_substrate_coldkey, netuid, all_hotkeys)
    delivered_final = delivered_total - delivered_first
    assert delivered_final >= quoted_final - config.ROUNDING_DUST_TOTAL_RAO, (
        f"Hostile dust: final exit delivered {delivered_final} against a quote of {quoted_final}"
    )
    assert env.vault_shares(token_id) == 0, "Hostile dust: shares not fully burned"
    leftover_stake = env.vault_total_stake(token_id)
    assert leftover_stake <= config.ROUNDING_DUST_TOTAL_RAO, (
        f"Hostile dust: stake left behind after the full exit ({leftover_stake} RAO)"
    )
    print("  Victim exited in full, including both absorbed plants")
