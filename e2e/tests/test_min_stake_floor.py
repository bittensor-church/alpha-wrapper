"""Scenario: min-stake floor handling.

Tests that the vault respects the chain's minimum-stake rule without ever
costing users money, in three legs:
  1. A deposit below the vault's minimum is refused outright with a clear
     error, and a deposit above it goes through. (The vault's minimum is
     raised above the chain's for this leg, because the chain itself blocks
     anything smaller before the vault ever sees it.)
  2. Small leftovers stranded when the validator set changes are picked up
     by the next deposit - nothing is ever forfeited.
  3. An internal move too small for the chain to accept is skipped up front
     rather than attempted and failed, so the transaction doesn't waste gas;
     the imbalance is corrected by a later, larger deposit.

The legs run in order inside one test: leg 1's healthy first wrap anchors the
gas baseline leg 3's budget is measured against.
"""
import pytest

from alpha_e2e import bootstrap, chain, config, extrinsics
from alpha_e2e.substrate import h160_to_ss58


@pytest.mark.scenario
def test_min_stake_floor(env):
    vault_floor = env.min_stake_tao_floor()
    print(f"  minStakeTaoFloor = {vault_floor} RAO")

    # --- Leg 1: the wrap gate binds at the raised vault floor --------------------
    # A sub-chain-floor deposit cannot even park, so exercise the vault's gate by
    # raising its floor to 2x the chain's: a between-floors deposit must be
    # refused, a top-up past the raised floor must wrap.
    gate_netuid = env.netuids[0]
    gate_hotkey_pubkey = env.hotkey_pubkeys[0]
    gate_hotkey_ss58 = env.hotkey_ss58s[0]
    raised_floor = vault_floor * 2
    env.set_vault_floor(raised_floor, "Floor gate: raising the vault floor failed")

    gate_price, gate_boundary = env.floor_boundary(gate_netuid, vault_floor)
    between_floors_alpha = gate_boundary * 3 // 2
    print(f"  Alpha price={gate_price} -> chain-floor boundary={gate_boundary} alpha RAO, "
          f"parking {between_floors_alpha}")

    gate_mailbox = env.mailbox_address(gate_netuid)
    # 1.5x the boundary clears the chain's transfer floor only while the chain's
    # minimum stake matches the vault's deploy floor; fail with context if the
    # localnet image drifts.
    try:
        extrinsics.transfer_stake(
            h160_to_ss58(gate_mailbox), gate_hotkey_ss58, gate_netuid, between_floors_alpha,
        )
    except extrinsics.ExtrinsicError as error:
        raise AssertionError(
            "Floor gate: parking transfer refused - has the chain's minimum stake moved "
            f"past this test's sizing ({between_floors_alpha} alpha = 1.5x the vault "
            "deploy floor)?"
        ) from error

    env.assert_vault_reverts_with(
        "DepositTooSmall()", 1_500_000,
        "Floor gate: between-floors wrap did NOT revert as DepositTooSmall",
        "wrap(address,uint256,bytes32)",
        config.WRAPPER_USER_ADDRESS, gate_netuid, gate_hotkey_pubkey,
    )
    print("  wrap refused a deposit between the chain floor and the raised vault floor "
          "as DepositTooSmall")

    # A second parking transfer doubles the mailbox to ~3x the chain floor, above
    # the raised floor.
    extrinsics.transfer_stake(
        h160_to_ss58(gate_mailbox), gate_hotkey_ss58, gate_netuid, between_floors_alpha,
    )
    above_floor_wrap_receipt = env.vault_send(
        1_500_000, "Floor gate: above-floor wrap failed",
        "wrap(address,uint256,bytes32)",
        config.WRAPPER_USER_ADDRESS, gate_netuid, gate_hotkey_pubkey,
    )
    print("  wrap accepted the deposit once it cleared the raised floor")

    # A healthy first wrap (clone deploys + flush + skipped sub-floor moves)
    # anchors the gas budget below.
    wrap_gas_baseline = chain.receipt_gas_used(above_floor_wrap_receipt)
    assert wrap_gas_baseline is not None, (
        "Floor gate: could not parse gasUsed for the wrap baseline"
    )
    print(f"  Healthy first-wrap gas baseline: {wrap_gas_baseline}")

    # Restore the deploy-time floor for the remaining legs.
    env.set_vault_floor(vault_floor, "Floor gate: restoring the vault floor failed")

    # --- Leg 2: rotated-out dust is consolidated by the next wrap ------------------
    # Park sub-floor dust under a soon-rotated hotkey; the next wrap's fresh deposit
    # starts the roller, so deposit + dust roll over the chain floor in one
    # transaction - no keeper, no forfeiture.
    dust_netuid = env.netuids[2]
    dust_token_id = env.token_ids[2]
    dust_hotkey_pubkey = env.hotkey_pubkeys[6]
    dust_hotkey_ss58 = env.hotkey_ss58s[6]
    kept_hotkey_b_pubkey = env.hotkey_pubkeys[7]
    kept_hotkey_b_ss58 = env.hotkey_ss58s[7]
    kept_hotkey_c_pubkey = env.hotkey_pubkeys[8]

    # A fresh validator to take the dust hotkey's slot after the rotation.
    rotated_in_pubkey, _ = bootstrap.register_hotkey(dust_netuid, "hk_e2e_3d")
    print(f"  Registered replacement validator {rotated_in_pubkey[:18]}... "
          f"on netuid {dust_netuid}")

    # The bootstrap's 50/30/20 three-validator set is already attested, with the
    # dust hotkey first.
    dust_price, dust_boundary = env.floor_boundary(dust_netuid, vault_floor)
    # 1.5x the boundary clears the deposit floor while every corrective move toward
    # the 50/30/20 split stays below it, keeping the whole deposit on the dust hotkey.
    dust_deposit = dust_boundary * 3 // 2
    env.deposit_and_wrap(
        dust_netuid, dust_hotkey_pubkey, dust_hotkey_ss58, dust_deposit,
        1_500_000, "Dust consolidation: wrap failed",
    )

    dust_shares = env.vault_shares(dust_token_id)
    dust_clone_coldkey = env.clone_coldkey(dust_token_id)

    # Burn 5/6 of the shares: delivers ~1.25x the boundary and leaves ~0.25x the
    # boundary (sub-floor) dust.
    dust_burn = dust_shares * 5 // 6
    env.vault_send(
        2_500_000, "Dust consolidation: partial unwrap failed",
        "unwrap(uint256,uint256,bytes32)",
        dust_token_id, dust_burn, env.wrapper_substrate_coldkey,
    )
    dust_residue = env.stake(dust_hotkey_pubkey, dust_clone_coldkey, dust_netuid)
    assert dust_residue * dust_price // 10**18 < vault_floor, (
        f"Dust consolidation: residual {dust_residue} is not sub-floor (price {dust_price})"
    )
    print(f"  Left sub-floor dust of {dust_residue} alpha RAO under the "
          "soon-rotated hotkey")

    # Rotate the dust hotkey out for the replacement, then wrap a fresh above-floor
    # deposit under a surviving validator.
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

    # The remembered set must drop the drained hotkey and the backing must fold in
    # deposit + reclaimed dust.
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
    # Against a 50/30/20 three-validator split, a 1.5x-floor deposit leaves every
    # corrective move sub-floor; the chain would reject such a move at full
    # forwarded-gas cost, so the vault must skip them pre-call and leave the split
    # drifted.
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

    _, skip_boundary = env.floor_boundary(skip_netuid, vault_floor)
    # 1.5x the boundary clears the deposit floor while the corrective moves (0.45x
    # and 0.3x) stay below it.
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

    # A later above-floor deposit makes both corrective moves land and clears the drift.
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
