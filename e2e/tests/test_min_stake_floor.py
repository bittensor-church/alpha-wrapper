"""Scenario: min-stake floor handling.

Tests that the vault respects the chain's minimum-stake rule without ever costing
users money: a deposit below the minimum is refused cheaply and goes through once
topped up; leftovers stranded by a validator change are picked up by the next
deposit; an internal move too small for the chain is skipped rather than attempted
and failed, and a later, larger deposit corrects the imbalance.

The legs run in order inside one test: leg 1's healthy first wrap anchors the gas
baseline leg 3's budget is measured against.
"""
import pytest

from alpha_e2e import bootstrap, chain, config, extrinsics
from alpha_e2e.checks import assert_gas_within
from alpha_e2e.substrate import h160_to_ss58


@pytest.mark.scenario
def test_min_stake_floor(env):
    chain_min_stake = env.chain_min_stake_tao()
    print(f"  chain minimum stake = {chain_min_stake} RAO")

    # --- Leg 1: the wrap gate refuses a sub-floor deposit up front ---------------
    # Parking clears a far lower bar than staking, so a sub-minimum deposit still reaches
    # the mailbox and the vault's gate is all that stands between it and a chain move that
    # would burn the whole gas budget.
    gate_netuid = env.netuids[0]
    gate_hotkey_pubkey = env.hotkey_pubkeys[0]
    gate_hotkey_ss58 = env.hotkey_ss58s[0]

    gate_price, gate_boundary = env.floor_boundary(gate_netuid, chain_min_stake)
    # Two of these park below the boundary individually but clear it together.
    sub_floor_alpha = gate_boundary * 2 // 3
    print(f"  Alpha price={gate_price} -> floor boundary={gate_boundary} alpha RAO, "
          f"parking {sub_floor_alpha}")

    gate_mailbox = env.mailbox_address(gate_netuid)
    try:
        extrinsics.transfer_stake(
            h160_to_ss58(gate_mailbox), gate_hotkey_ss58, gate_netuid, sub_floor_alpha,
        )
    except extrinsics.ExtrinsicError as error:
        raise AssertionError(
            "Floor gate: parking transfer refused - the deposit must sit between the "
            f"chain's parking bar and its minimum stake ({sub_floor_alpha} alpha = 2/3 "
            "of the boundary); has either moved past this test's sizing?"
        ) from error

    gate_refusal_receipt = env.assert_vault_reverts_with(
        "DepositTooSmall()", 1_500_000,
        "Floor gate: sub-floor wrap did NOT revert as DepositTooSmall",
        "wrap(address,uint256,bytes32)",
        config.WRAPPER_USER_ADDRESS, gate_netuid, gate_hotkey_pubkey,
    )
    assert_gas_within(
        gate_refusal_receipt, config.REVERT_GAS_BOUND, "Floor gate: sub-floor wrap refusal",
    )
    print("  wrap refused a deposit below the chain minimum as DepositTooSmall, "
          "without burning the gas budget")

    extrinsics.transfer_stake(
        h160_to_ss58(gate_mailbox), gate_hotkey_ss58, gate_netuid, sub_floor_alpha,
    )
    above_floor_wrap_receipt = env.vault_send(
        1_500_000, "Floor gate: above-floor wrap failed",
        "wrap(address,uint256,bytes32)",
        config.WRAPPER_USER_ADDRESS, gate_netuid, gate_hotkey_pubkey,
    )
    print("  wrap accepted the deposit once it cleared the minimum")

    # A healthy first wrap - clone deploy, flush, skipped sub-floor moves - anchors leg 3.
    wrap_gas_baseline = chain.receipt_gas_used(above_floor_wrap_receipt)
    assert wrap_gas_baseline is not None, (
        "Floor gate: could not parse gasUsed for the wrap baseline"
    )
    print(f"  Healthy first-wrap gas baseline: {wrap_gas_baseline}")

    # --- Leg 2: rotated-out dust is consolidated by the next wrap ------------------
    # The next wrap's fresh deposit starts the roller, so deposit and dust roll over the
    # chain floor in one transaction - no keeper, no forfeiture.
    dust_netuid = env.netuids[2]
    dust_token_id = env.token_ids[2]
    dust_hotkey_pubkey = env.hotkey_pubkeys[6]
    dust_hotkey_ss58 = env.hotkey_ss58s[6]
    kept_hotkey_b_pubkey = env.hotkey_pubkeys[7]
    kept_hotkey_b_ss58 = env.hotkey_ss58s[7]
    kept_hotkey_c_pubkey = env.hotkey_pubkeys[8]

    rotated_in_pubkey, _ = bootstrap.register_hotkey(dust_netuid, "hk_e2e_3d")
    print(f"  Registered replacement validator {rotated_in_pubkey[:18]}... "
          f"on netuid {dust_netuid}")

    # The bootstrap's 50/30/20 set is already attested, with the dust hotkey first.
    dust_price, dust_boundary = env.floor_boundary(dust_netuid, chain_min_stake)
    # 1.5x the boundary clears the deposit floor while every corrective move stays below
    # it, keeping the whole deposit on the dust hotkey.
    dust_deposit = dust_boundary * 3 // 2
    env.deposit_and_wrap(
        dust_netuid, dust_hotkey_pubkey, dust_hotkey_ss58, dust_deposit,
        1_500_000, "Dust consolidation: wrap failed",
    )

    dust_shares = env.vault_shares(dust_token_id)
    dust_clone_coldkey = env.clone_coldkey(dust_token_id)

    # Delivers ~1.25x the boundary and leaves ~0.25x of it behind as sub-floor dust.
    dust_burn = dust_shares * 5 // 6
    env.vault_send(
        2_500_000, "Dust consolidation: partial unwrap failed",
        "unwrap(uint256,uint256,bytes32)",
        dust_token_id, dust_burn, env.wrapper_substrate_coldkey,
    )
    dust_residue = env.stake(dust_hotkey_pubkey, dust_clone_coldkey, dust_netuid)
    assert dust_residue * dust_price // 10**18 < chain_min_stake, (
        f"Dust consolidation: residual {dust_residue} is not sub-floor (price {dust_price})"
    )
    print(f"  Left sub-floor dust of {dust_residue} alpha RAO under the "
          "soon-rotated hotkey")

    env.set_validators(
        dust_netuid, [rotated_in_pubkey, kept_hotkey_b_pubkey, kept_hotkey_c_pubkey],
        [5000, 3000, 2000],
    )
    dust_total_before = env.vault_total_stake(dust_token_id)
    consolidating_deposit = dust_boundary * 3
    env.deposit_and_wrap(
        dust_netuid, kept_hotkey_b_pubkey, kept_hotkey_b_ss58, consolidating_deposit,
        2_500_000, "Dust consolidation: consolidating wrap failed",
    )

    dust_residue_after = env.stake(dust_hotkey_pubkey, dust_clone_coldkey, dust_netuid)
    assert dust_residue_after <= config.ROUNDING_DUST_SLOT_RAO, (
        f"Dust consolidation: rotated dust NOT consolidated "
        f"({dust_residue_after} > {config.ROUNDING_DUST_SLOT_RAO})"
    )
    print(f"  Next wrap consolidated the rotated dust: rotated-out hotkey left with "
          f"{dust_residue_after} RAO")

    assert not env.hotkey_in_last_seen(dust_token_id, dust_hotkey_pubkey), (
        "Dust consolidation: consolidated hotkey still present in lastSeenHotkeys"
    )
    dust_total_after = env.vault_total_stake(dust_token_id)
    assert dust_total_after >= (
        dust_total_before + consolidating_deposit - config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO
    ), (
        f"Dust consolidation: backing did not fold in deposit + reclaimed dust "
        f"({dust_total_after})"
    )
    print("  Backing folded in the fresh deposit and the reclaimed dust; "
          "remembered set refreshed to the current set")

    # --- Leg 3: a sub-floor rebalance move is skipped, not attempted ----------------
    # The chain rejects a sub-floor move at full forwarded-gas cost, so the vault must skip
    # such moves pre-call and leave the split drifted.
    skip_netuid = env.netuids[1]
    skip_token_id = env.token_ids[1]
    over_hotkey_pubkey = env.hotkey_pubkeys[3]
    over_hotkey_ss58 = env.hotkey_ss58s[3]
    under_hotkey_b_pubkey = env.hotkey_pubkeys[4]
    under_hotkey_c_pubkey = env.hotkey_pubkeys[5]
    env.set_validators(
        skip_netuid, [over_hotkey_pubkey, under_hotkey_b_pubkey, under_hotkey_c_pubkey],
        [5000, 3000, 2000],
    )

    _, skip_boundary = env.floor_boundary(skip_netuid, chain_min_stake)
    # 1.5x the boundary clears the deposit floor while the corrective moves (0.45x and
    # 0.3x) stay below it.
    skip_deposit = skip_boundary * 3 // 2
    skip_wrap_receipt = env.deposit_and_wrap(
        skip_netuid, over_hotkey_pubkey, over_hotkey_ss58, skip_deposit, 1_500_000,
        "Sub-floor skip: wrap with sub-floor residue failed (doomed move attempted?)",
    )
    skip_gas_used = chain.receipt_gas_used(skip_wrap_receipt)
    assert skip_gas_used is not None, "Sub-floor skip: could not parse gasUsed"

    skip_clone_coldkey = env.clone_coldkey(skip_token_id)
    under_b_stake = env.stake(under_hotkey_b_pubkey, skip_clone_coldkey, skip_netuid)
    under_c_stake = env.stake(under_hotkey_c_pubkey, skip_clone_coldkey, skip_netuid)
    assert under_b_stake == 0 and under_c_stake == 0, (
        f"Sub-floor skip: a sub-floor move was executed "
        f"({under_b_stake} / {under_c_stake} RAO moved)"
    )
    # Baseline-derived bound tracks chain-side gas re-pricing; a doomed move burns
    # far past +25%.
    skip_gas_bound = wrap_gas_baseline * 5 // 4
    assert skip_gas_used <= skip_gas_bound, (
        f"Sub-floor skip: wrap consumed {skip_gas_used} gas (bound {skip_gas_bound}; "
        "doomed move burned the budget)"
    )
    print(f"  Sub-floor moves skipped: wrap used {skip_gas_used} gas "
          f"(bound {skip_gas_bound}), split left drifted")

    env.deposit_and_wrap(
        skip_netuid, over_hotkey_pubkey, over_hotkey_ss58, skip_boundary * 6,
        1_500_000, "Sub-floor skip: follow-up wrap failed",
    )
    under_b_stake = env.stake(under_hotkey_b_pubkey, skip_clone_coldkey, skip_netuid)
    under_c_stake = env.stake(under_hotkey_c_pubkey, skip_clone_coldkey, skip_netuid)
    assert under_b_stake != 0 and under_c_stake != 0, (
        f"Sub-floor skip: drift did not clear on the follow-up deposit "
        f"({under_b_stake} / {under_c_stake} RAO)"
    )
    print(f"  Follow-up deposit cleared the drift: {under_b_stake} and {under_c_stake} RAO "
          "on the under-validators")
