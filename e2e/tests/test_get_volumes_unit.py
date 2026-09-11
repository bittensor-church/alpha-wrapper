"""Chainless tests for the volume tool's aggregation of TAO exits."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "scripts"))

from get_volumes import EventTotals, build_volume_row  # noqa: E402


def _totals(summed, *events):
    totals = EventTotals(tuple(summed))
    for args in events:
        totals.add(args)
    return totals


def test_build_volume_row_reports_gross_burns_and_a_refund_larger_than_the_burn():
    deposits = _totals(("assets", "shares"), {"assets": 100, "shares": 100_000})
    alpha_unwraps = _totals(("shares", "alphaOut"))
    tao_unwraps = _totals(
        ("sharesBurned", "sharesRefunded", "alphaSold", "taoOut"),
        {"sharesBurned": 100_000, "sharesRefunded": 240_000, "alphaSold": 60, "taoOut": 60},
        {"sharesBurned": 6_000, "sharesRefunded": 1_000, "alphaSold": 5, "taoOut": 5},
    )
    dissolved = _totals(("shares", "taoOut"))

    row = build_volume_row(7, "", deposits, alpha_unwraps, tao_unwraps, dissolved)

    assert row["shares_minted"] == 100_000
    assert row["tao_unwrap_shares_burned"] == 106_000
    assert row["tao_unwrap_shares_refunded"] == 241_000
    assert row["shares_burned"] == 106_000
    assert row["alpha_sold_for_tao_rao"] == 65
    assert row["tao_received_wei"] == 65


def test_event_totals_rejects_an_event_missing_a_summed_field():
    totals = EventTotals(("sharesBurned",))
    try:
        totals.add({"shares": 1})
    except KeyError:
        return
    raise AssertionError("a renamed field must not silently read as zero")
