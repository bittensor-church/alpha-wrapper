"""Scenario: the vault stays live through every dust state.

Tests that no sequence of deposits, withdrawals, and validator changes can
leave the vault stuck because of leftovers too small for the chain to move:
  - Two full churn cycles, each leaving every kind of small leftover behind
    (withdrawal remainders, skipped rebalances, sale leftovers, balances
    left on rotated-out validators): every deposit and withdrawal along the
    way keeps working at normal gas cost.
  - The owner then raises the vault's minimum (as it would to track a chain
    increase) above every validator slot while the position as a whole stays
    above it: withdrawing alpha is refused cheaply with a clear error, and
    the next deposit unlocks it.
  - A closing ledger checks nothing was ever forfeited: everything the user
    put in came back out, as delivered alpha or as TAO from sales.
"""
import pytest

from alpha_e2e import bootstrap, config
from alpha_e2e.checks import assert_gas_within, assert_payout_near_quote, min_tao_out_for


class ChurnLedger:
    """Drives deposits, withdrawals, and rotations on one subnet while keeping
    the closing-ledger accumulators (alpha RAO) and the union of every hotkey a
    delivery can land under."""

    def __init__(self, env, netuid, token_id, vault_floor, union_hotkey_pubkeys):
        self.env = env
        self.netuid = netuid
        self.token_id = token_id
        self.vault_floor = vault_floor
        # Every hotkey a delivery can land under; rotation replacements are
        # appended as they register.
        self.union_hotkey_pubkeys = list(union_hotkey_pubkeys)
        self.deposited_total = 0
        self.sold_total = 0
        self._clone_coldkey = None

    @property
    def clone_coldkey(self) -> str:
        # The clone deploys on the first wrap, so resolve its coldkey lazily on
        # first use (always after the fixture deposit) and cache it.
        if self._clone_coldkey is None:
            self._clone_coldkey = self.env.clone_coldkey(self.token_id)
        return self._clone_coldkey

    def delivered_sum(self) -> int:
        """Cumulative alpha delivered to the user across all withdrawals so far."""
        return self.env.total_stake_across(
            self.env.wrapper_substrate_coldkey, self.netuid, self.union_hotkey_pubkeys,
        )

    def floor_boundary_alpha(self) -> int:
        _, boundary = self.env.floor_boundary(self.netuid, self.vault_floor)
        return boundary

    def deposit_step(self, label: str, hotkey_pubkey: str, hotkey_ss58: str,
                     amount_rao: int) -> None:
        """Deposit `amount_rao` under the hotkey and assert the wrap lands at
        normal gas cost."""
        receipt = self.env.deposit_and_wrap(
            self.netuid, hotkey_pubkey, hotkey_ss58, amount_rao,
            1_500_000, f"{label}: wrap failed",
        )
        assert_gas_within(receipt, config.WRAP_GAS_BOUND, f"{label}: wrap")
        self.deposited_total += amount_rao
        print(f"  {label}: wrapped {amount_rao} alpha RAO")

    def unwrap_step(self, label: str, percent: int) -> None:
        """Burn `percent` of the user's shares on the alpha rail and assert full
        delivery at normal gas."""
        assets_before = self.env.holder_assets(self.token_id, config.WRAPPER_USER_ADDRESS)
        delivered_before = self.delivered_sum()
        burn = self.env.vault_shares(self.token_id) * percent // 100
        receipt = self.env.vault_send(
            2_500_000, f"{label}: unwrap failed",
            "unwrap(uint256,uint256,bytes32)",
            self.token_id, burn, self.env.wrapper_substrate_coldkey,
        )
        assert_gas_within(receipt, config.UNWRAP_GAS_BOUND, f"{label}: unwrap")
        delivered = self.delivered_sum() - delivered_before
        assert delivered >= assets_before * percent // 100 * 98 // 100, (
            f"{label}: unwrap under-delivered ({delivered} alpha RAO)"
        )
        print(f"  {label}: unwrapped {percent}% of shares, delivered {delivered} alpha RAO")

    def unwrap_for_tao_step(self, label: str, percent: int) -> None:
        """Burn `percent` of the user's shares on the TAO rail and assert the
        payout matches the quote."""
        total_before = self.env.vault_total_stake(self.token_id)
        burn = self.env.vault_shares(self.token_id) * percent // 100
        sold_assets = (
            self.env.holder_assets(self.token_id, config.WRAPPER_USER_ADDRESS) * percent // 100
        )
        quote = self.env.alpha_to_tao_quote(self.netuid, sold_assets)
        min_tao_out = min_tao_out_for(quote)
        balance_before = self.env.user_tao_wei()
        receipt = self.env.vault_send(
            2_500_000, f"{label}: TAO exit failed",
            "unwrapForTao(uint256,uint256,uint256)", self.token_id, burn, min_tao_out,
        )
        assert_gas_within(receipt, config.UNWRAP_GAS_BOUND, f"{label}: TAO exit")
        assert_payout_near_quote(
            balance_before, self.env.user_tao_wei(), receipt, quote,
            f"{label}: TAO exit payout off quote",
        )
        self.sold_total += total_before - self.env.vault_total_stake(self.token_id)
        print(f"  {label}: sold {percent}% of shares for TAO")

    def churn_cycle(
        self, round_number: int,
        primary_pubkey: str, primary_ss58: str,
        secondary_pubkey: str, secondary_ss58: str,
        kept_pubkey: str, replacement_name: str,
    ) -> str:
        """One churn cycle: deposit, withdraw most of it (leaving a remainder),
        deposit again, rotate the primary validator out for a fresh one, withdraw
        across the rotated-out balances, deposit, and sell a slice for TAO.
        Leaves the union sprinkled with every kind of small leftover. Returns
        the replacement hotkey's pubkey."""
        label = f"Cycle {round_number}"
        print(f"\n=== Churn cycle {round_number} ===")

        boundary = self.floor_boundary_alpha()
        self.deposit_step(label, primary_pubkey, primary_ss58, boundary * 9 // 2)
        self.unwrap_step(label, 80)
        self.deposit_step(label, secondary_pubkey, secondary_ss58, boundary * 5 // 2)

        replacement_pubkey, _ = bootstrap.register_hotkey(self.netuid, replacement_name)
        self.union_hotkey_pubkeys.append(replacement_pubkey)
        self.env.set_validators(
            self.netuid, [replacement_pubkey, secondary_pubkey, kept_pubkey],
            [5000, 3000, 2000],
        )
        print(f"  {label}: rotated {primary_pubkey[:18]}... out for {replacement_pubkey[:18]}...")

        self.unwrap_step(f"{label} (over the rotated-out balances)", 50)
        rotated_out_leftover = self.env.stake(primary_pubkey, self.clone_coldkey, self.netuid)
        assert rotated_out_leftover <= config.ROUNDING_DUST_SLOT_RAO, (
            f"{label}: rotated-out validator still holds stake ({rotated_out_leftover} RAO)"
        )
        assert not self.env.hotkey_in_last_seen(self.token_id, primary_pubkey), (
            f"{label}: rotated-out validator still present in lastSeenHotkeys"
        )
        print(f"  {label}: withdrawal consolidated the rotated-out balances")

        self.deposit_step(label, secondary_pubkey, secondary_ss58, boundary * 3)
        self.unwrap_for_tao_step(label, 40)
        return replacement_pubkey


@pytest.mark.scenario
def test_min_stake_liveness(env):
    vault_floor = env.min_stake_tao_floor()
    print(f"  minStakeTaoFloor = {vault_floor} RAO")

    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkey_a_pubkey = env.hotkey_pubkeys[0]
    hotkey_a_ss58 = env.hotkey_ss58s[0]
    hotkey_b_pubkey = env.hotkey_pubkeys[1]
    hotkey_b_ss58 = env.hotkey_ss58s[1]
    hotkey_c_pubkey = env.hotkey_pubkeys[2]
    hotkey_c_ss58 = env.hotkey_ss58s[2]

    ledger = ChurnLedger(
        env, netuid, token_id, vault_floor,
        [hotkey_a_pubkey, hotkey_b_pubkey, hotkey_c_pubkey],
    )

    # --- Fixture position ---------------------------------------------------------
    ledger.deposit_step(
        "Bootstrap deposit", hotkey_a_pubkey, hotkey_a_ss58,
        ledger.floor_boundary_alpha() * 3 // 2,
    )

    cycle1_replacement_pubkey = ledger.churn_cycle(
        1, hotkey_a_pubkey, hotkey_a_ss58, hotkey_b_pubkey, hotkey_b_ss58,
        hotkey_c_pubkey, "hk_e2e_1d",
    )
    cycle2_replacement_pubkey = ledger.churn_cycle(
        2, hotkey_b_pubkey, hotkey_b_ss58, hotkey_c_pubkey, hotkey_c_ss58,
        cycle1_replacement_pubkey, "hk_e2e_1e",
    )

    # --- A raised floor devalues every slot while the position stays above it ------
    # Rebuild a full 50/30/20 split first, then raise the vault floor above the
    # largest slot (as the owner would to track a chain increase): every slot is
    # below the floor while the position as a whole stays above it - the one
    # state where the alpha rail must refuse a position worth exiting.
    original_floor = vault_floor
    ledger.deposit_step(
        "Split devaluation", hotkey_c_pubkey, hotkey_c_ss58,
        ledger.floor_boundary_alpha() * 6,
    )
    largest_slot = max(
        env.stake(cycle2_replacement_pubkey, ledger.clone_coldkey, netuid),
        env.stake(hotkey_c_pubkey, ledger.clone_coldkey, netuid),
        env.stake(cycle1_replacement_pubkey, ledger.clone_coldkey, netuid),
    )
    largest_value = env.alpha_value_tao(netuid, largest_slot)
    total_value = env.alpha_value_tao(netuid, env.vault_total_stake(token_id))
    raised_floor = largest_value * 13 // 10
    assert raised_floor <= total_value * 9 // 10 - 1, (
        f"Split devaluation: split too skewed to raise the floor between largest and "
        f"total (largest {largest_value}, total {total_value})"
    )
    env.set_vault_floor(raised_floor, "Split devaluation: raising the vault floor failed")
    # The healing deposit below sizes against the raised floor, which it must clear.
    ledger.vault_floor = raised_floor
    print(f"  Floor raised to {raised_floor} RAO: every slot below it "
          f"(largest {largest_value} RAO), position worth {total_value} RAO above it")

    refusal_receipt = env.assert_vault_reverts_with(
        "GatherBelowFloor()", 2_500_000,
        "Split devaluation: alpha exit did NOT revert as GatherBelowFloor",
        "unwrap(uint256,uint256,bytes32)",
        token_id, env.vault_shares(token_id), env.wrapper_substrate_coldkey,
    )
    assert_gas_within(
        refusal_receipt, config.REVERT_GAS_BOUND, "Split devaluation: alpha-exit refusal",
    )
    print("  Alpha exit refused up front as GatherBelowFloor, without burning the gas budget")

    # The next deposit creates a slot the withdrawal can gather from, unlocking
    # the alpha rail.
    ledger.deposit_step(
        "Split devaluation (healing)", hotkey_c_pubkey, hotkey_c_ss58,
        ledger.floor_boundary_alpha() * 5 // 2,
    )
    ledger.unwrap_step("Split devaluation (healed)", 50)
    env.set_vault_floor(original_floor, "Split devaluation: restoring the vault floor failed")

    # --- Full exit and closing ledger ------------------------------------------------
    ledger.unwrap_for_tao_step("Closing", 100)
    assert env.vault_shares(token_id) == 0, "Closing: shares not fully burned"
    leftover_stake = env.vault_total_stake(token_id)
    assert leftover_stake <= config.ROUNDING_DUST_TOTAL_RAO, (
        f"Closing: stake left behind after the full exit ({leftover_stake} RAO)"
    )

    # Everything deposited must have come back out as delivered alpha or as alpha
    # sold for TAO; emissions only push the left side up, so a shortfall means
    # stake was forfeited along the way.
    delivered_total = ledger.delivered_sum()
    assert delivered_total + ledger.sold_total >= ledger.deposited_total * 99 // 100, (
        f"Closing: ledger shortfall (delivered {delivered_total} + sold {ledger.sold_total} "
        f"< deposited {ledger.deposited_total})"
    )
    print(f"  Ledger closed: deposited {ledger.deposited_total}, delivered "
          f"{delivered_total}, sold {ledger.sold_total} alpha RAO")
