"""Scenario: the vault stays live through every dust state.

No sequence of deposits, withdrawals, and validator changes can leave the vault
stuck behind leftovers too small for the chain to move. Two churn cycles scatter
every kind of leftover - withdrawal remainders, skipped rebalances, sale
leftovers, balances on rotated-out validators - and every call along the way
keeps working at normal gas cost. A closing ledger then checks that everything
deposited came back out, as delivered alpha or as TAO from sales.
"""
import pytest

from alpha_e2e import bootstrap, config
from alpha_e2e.checks import (
    assert_gas_within, assert_payout_at_least_quote_floor, assert_payout_matches_emitted,
    assert_payout_near_quote, min_tao_out_for,
)


class ChurnLedger:
    """Deposits, withdrawals, and rotations on one subnet, tracking the closing-ledger
    totals (alpha RAO) and every hotkey a delivery can land under."""

    def __init__(self, env, netuid, token_id, chain_min_stake, union_hotkey_pubkeys):
        self.env = env
        self.netuid = netuid
        self.token_id = token_id
        self.chain_min_stake = chain_min_stake
        self.union_hotkey_pubkeys = list(union_hotkey_pubkeys)
        self.deposited_alpha_total = 0
        self.sold_alpha_total = 0
        self._clone_coldkey = None

    @property
    def clone_coldkey(self) -> str:
        # The clone only exists after the first wrap, so resolve it lazily.
        if self._clone_coldkey is None:
            self._clone_coldkey = self.env.clone_coldkey(self.token_id)
        return self._clone_coldkey

    def delivered_alpha_total(self) -> int:
        return self.env.total_stake_across(
            self.env.wrapper_substrate_coldkey, self.netuid, self.union_hotkey_pubkeys,
        )

    def floor_boundary_alpha(self) -> int:
        _, boundary = self.env.floor_boundary(self.netuid, self.chain_min_stake)
        return boundary

    def deposit_step(self, label: str, hotkey_pubkey: str, hotkey_ss58: str,
                     amount_rao: int) -> None:
        receipt = self.env.deposit_and_wrap(
            self.netuid, hotkey_pubkey, hotkey_ss58, amount_rao,
            1_500_000, f"{label}: wrap failed",
        )
        assert_gas_within(receipt, config.WRAP_GAS_BOUND, f"{label}: wrap")
        self.deposited_alpha_total += amount_rao
        print(f"  {label}: wrapped {amount_rao} alpha RAO")

    def unwrap_for_alpha_step(self, label: str, percent: int) -> None:
        delivered_before = self.delivered_alpha_total()
        burn = self.env.vault_shares(self.token_id) * percent // 100
        quoted_alpha, _ = self.env.preview_unwrap(self.token_id, burn)
        receipt = self.env.vault_send(
            2_500_000, f"{label}: unwrap failed",
            "unwrap(uint256,uint256,bytes32)",
            self.token_id, burn, self.env.wrapper_substrate_coldkey,
        )
        assert_gas_within(receipt, config.UNWRAP_GAS_BOUND, f"{label}: unwrap")
        delivered = self.delivered_alpha_total() - delivered_before
        # Only a floor: this reads the user's whole stake, and everything delivered earlier is
        # still earning emissions under the same hotkeys, so any surplus is yield. Over-delivery
        # is asserted where it is observable, in the co-holder scenario's backing check.
        assert delivered >= quoted_alpha - config.ROUNDING_DUST_TOTAL_RAO, (
            f"{label}: unwrap delivered {delivered} alpha RAO against a quote of {quoted_alpha}"
        )
        print(f"  {label}: unwrapped {percent}% of shares, delivered {delivered} alpha RAO")

    def unwrap_for_tao_step(self, label: str, percent: int) -> None:
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
        balance_after = self.env.user_tao_wei()
        if percent == 100:
            assert_payout_at_least_quote_floor(
                balance_before, balance_after, receipt, quote,
                f"{label}: TAO exit payout below quote floor",
            )
        else:
            assert_payout_near_quote(
                balance_before, balance_after, receipt, quote,
                f"{label}: TAO exit payout off quote",
            )
        assert_payout_matches_emitted(
            balance_before, balance_after, receipt,
            f"{label}: TAO exit paid less than it reported",
        )
        self.sold_alpha_total += total_before - self.env.vault_total_stake(self.token_id)
        print(f"  {label}: sold {percent}% of shares for TAO")

    def churn_cycle(
        self, round_number: int,
        primary_pubkey: str, primary_ss58: str,
        secondary_pubkey: str, secondary_ss58: str,
        kept_pubkey: str, replacement_name: str,
    ) -> str:
        """Deposit, withdraw most of it, deposit again, rotate the primary validator
        out for a fresh one, withdraw across the rotated-out balances, deposit, and sell
        a slice for TAO. Returns the replacement hotkey's pubkey."""
        label = f"Cycle {round_number}"
        print(f"\n=== Churn cycle {round_number} ===")

        boundary = self.floor_boundary_alpha()
        self.deposit_step(label, primary_pubkey, primary_ss58, boundary * 9 // 2)
        self.unwrap_for_alpha_step(label, 80)
        self.deposit_step(label, secondary_pubkey, secondary_ss58, boundary * 5 // 2)

        replacement_pubkey, _ = bootstrap.register_hotkey(self.netuid, replacement_name)
        self.union_hotkey_pubkeys.append(replacement_pubkey)
        self.env.set_validators(
            self.netuid, [replacement_pubkey, secondary_pubkey, kept_pubkey],
            [5000, 3000, 2000],
        )
        print(f"  {label}: rotated {primary_pubkey[:18]}... out for {replacement_pubkey[:18]}...")

        self.unwrap_for_alpha_step(f"{label} (over the rotated-out balances)", 50)
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

    ledger = ChurnLedger(
        env, netuid, token_id, chain_min_stake,
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
    ledger.churn_cycle(
        2, hotkey_b_pubkey, hotkey_b_ss58, hotkey_c_pubkey, hotkey_c_ss58,
        cycle1_replacement_pubkey, "hk_e2e_1e",
    )

    # --- Full exit and closing ledger ------------------------------------------------
    ledger.unwrap_for_tao_step("Closing", 100)
    assert env.vault_shares(token_id) == 0, "Closing: shares not fully burned"
    leftover_stake = env.vault_total_stake(token_id)
    assert leftover_stake <= config.ROUNDING_DUST_TOTAL_RAO, (
        f"Closing: stake left behind after the full exit ({leftover_stake} RAO)"
    )

    # Emissions only push the delivered side up, so a shortfall means stake was forfeited.
    delivered_total = ledger.delivered_alpha_total()
    assert delivered_total + ledger.sold_alpha_total >= ledger.deposited_alpha_total * 99 // 100, (
        f"Closing: ledger shortfall (delivered {delivered_total} + sold "
        f"{ledger.sold_alpha_total} < deposited {ledger.deposited_alpha_total})"
    )
    print(f"  Ledger closed: deposited {ledger.deposited_alpha_total}, delivered "
          f"{delivered_total}, sold {ledger.sold_alpha_total} alpha RAO")
