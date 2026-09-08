"""Chainless tests for the harness's position arithmetic and record parsing."""
import pytest

from alpha_e2e import chain, environment
from alpha_e2e.environment import largest_burn_leaving_alpha

VIRTUAL_SHARES = 10**9


def _payout(total: int, supply: int, shares: int) -> int:
    return shares * (total + 1) // (supply + VIRTUAL_SHARES)


@pytest.mark.parametrize(
    "total, supply",
    [
        (33_333_333_333, 33_333_333_333 * VIRTUAL_SHARES),
        (1_000_000_001, 10**18),
        (7, 7 * VIRTUAL_SHARES + 12345),
        (5, 4 * VIRTUAL_SHARES),
    ],
)
def test_largest_burn_leaves_alpha_and_a_share(total, supply):
    shares = largest_burn_leaving_alpha(total, supply)
    assert 0 < shares < supply
    assert _payout(total, supply, shares) < total
    assert shares == supply - 1 or _payout(total, supply, shares + 1) >= total


def test_largest_burn_on_appreciated_backing_keeps_the_last_share():
    total, supply = 1_000_000_001, 10**18
    shares = largest_burn_leaving_alpha(total, supply)
    assert shares == supply - 1
    assert _payout(total, supply, shares) == 1_000_000_000


def test_recorded_slot_index_reads_the_active_key_of_each_slot(monkeypatch):
    logical_a, active_a = "0x" + "aa" * 32, "0x" + "ab" * 32
    logical_b, active_b = "0x" + "ba" * 32, "0x" + "bb" * 32
    monkeypatch.setattr(
        chain, "cast_call_raw",
        lambda *args, **kwargs: f"[({logical_a}, {active_a}, 100), ({logical_b}, {active_b}, 5)]\n",
    )
    env = environment.Environment.__new__(environment.Environment)
    env.vault_address = "0x1"
    assert env.recorded_slot_index(7, active_b.upper()) == 1
    assert env.recorded_slot_index(7, active_a) == 0
