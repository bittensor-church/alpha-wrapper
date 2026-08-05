"""Chainless unit tests for alpha_e2e.checks assertion helpers."""
import pytest

from alpha_e2e import chain, checks, config

CSV_TEXT = (
    "token_id,user,amount\n"
    "10,0xabc,5\n"
    "20,0xabc,7\n"
)


def test_assert_csv_passes_on_matching_invariants():
    rows = checks.assert_csv(
        CSV_TEXT, rows=2,
        column_sets={"token_id": {"10", "20"}},
        column_subsets={"token_id": {"10", "20", "30"}},
        column_eq={"user": "0xabc"},
        column_positive=["amount"],
    )
    assert [row["token_id"] for row in rows] == ["10", "20"]


def test_assert_csv_rejects_wrong_row_count():
    with pytest.raises(AssertionError, match="row count"):
        checks.assert_csv(CSV_TEXT, rows=3)


def test_assert_csv_rejects_wrong_column_set():
    with pytest.raises(AssertionError, match="'token_id' set"):
        checks.assert_csv(CSV_TEXT, column_sets={"token_id": {"10"}})


def test_assert_csv_rejects_value_outside_subset():
    with pytest.raises(AssertionError, match="'token_id' subset"):
        checks.assert_csv(CSV_TEXT, column_subsets={"token_id": {"10"}})


def test_assert_csv_rejects_column_mismatch():
    with pytest.raises(AssertionError, match="'user'"):
        checks.assert_csv(CSV_TEXT, column_eq={"user": "0xdef"})


def test_assert_csv_rejects_non_positive_column():
    with pytest.raises(AssertionError, match="'amount'"):
        checks.assert_csv("token_id,amount\n10,0\n", column_positive=["amount"])


def test_assert_gas_within_accepts_gas_under_bound():
    checks.assert_gas_within({"gasUsed": "0x5208"}, 30_000, "context")


def test_assert_gas_within_rejects_gas_over_bound():
    with pytest.raises(AssertionError, match="consumed 21000 gas"):
        checks.assert_gas_within({"gasUsed": 21_000}, 20_000, "context")


def test_assert_gas_within_rejects_unparseable_receipt():
    # A missing gasUsed must fail loudly, not pass the bound vacuously.
    with pytest.raises(AssertionError, match="could not parse gasUsed"):
        checks.assert_gas_within({}, 1_000_000, "context")


def test_assert_positive_gain_returns_delta():
    assert checks.assert_positive_gain(100, 150, "context") == 50


def test_assert_positive_gain_rejects_loss():
    with pytest.raises(AssertionError, match="net -50 wei"):
        checks.assert_positive_gain(150, 100, "context")


def test_assert_tao_gain_near_quote_bounds():
    quote_rao = 1_000
    quote_wei = quote_rao * 10**9
    assert checks.assert_tao_gain_near_quote(0, quote_wei, quote_rao, "ctx") == quote_wei
    checks.assert_tao_gain_near_quote(0, quote_wei * 9 // 10, quote_rao, "ctx")
    checks.assert_tao_gain_near_quote(0, quote_wei * 11 // 10, quote_rao, "ctx")
    with pytest.raises(AssertionError):
        checks.assert_tao_gain_near_quote(0, quote_wei * 8 // 10, quote_rao, "ctx")
    with pytest.raises(AssertionError):
        checks.assert_tao_gain_near_quote(0, quote_wei * 12 // 10, quote_rao, "ctx")


def test_assert_payout_near_quote_reconstructs_gas():
    quote_rao = 1_000
    quote_wei = quote_rao * 10**9
    gas_used = 100_000
    gas_cost_wei = gas_used * config.LOCALNET_GAS_PRICE_WEI
    receipt = {"gasUsed": gas_used}
    # A payout smaller than the gas burned still verifies once gas is added back.
    checks.assert_payout_near_quote(0, quote_wei - gas_cost_wei, receipt, quote_rao, "ctx")
    with pytest.raises(AssertionError, match="payout"):
        checks.assert_payout_near_quote(0, quote_wei * 3 - gas_cost_wei, receipt, quote_rao, "ctx")
    with pytest.raises(AssertionError, match="could not parse gasUsed"):
        checks.assert_payout_near_quote(0, quote_wei, {}, quote_rao, "ctx")


def _tao_exit_receipt(gas_used: int, emitted_wei: int) -> dict:
    topic = chain.cast_sig_event(checks.UNWRAPPED_FOR_TAO)
    data = "0x" + "".join(f"{word:064x}" for word in (0, 0, emitted_wei))
    return {"gasUsed": gas_used, "logs": [{"topics": [topic], "data": data}]}


def test_assert_payout_matches_emitted_accepts_the_reported_amount():
    emitted = 5 * checks.RAO_WEI
    gas_cost = 100_000 * config.LOCALNET_GAS_PRICE_WEI
    receipt = _tao_exit_receipt(100_000, emitted)
    checks.assert_payout_matches_emitted(0, emitted - gas_cost, receipt, "ctx")


def test_assert_payout_matches_emitted_tolerates_the_sub_rao_remainder():
    emitted = 5 * checks.RAO_WEI + 7
    gas_cost = 100_000 * config.LOCALNET_GAS_PRICE_WEI
    receipt = _tao_exit_receipt(100_000, emitted)
    checks.assert_payout_matches_emitted(0, emitted - 7 - gas_cost, receipt, "ctx")


def test_assert_payout_matches_emitted_rejects_a_shortfall():
    emitted = 5 * checks.RAO_WEI
    gas_cost = 100_000 * config.LOCALNET_GAS_PRICE_WEI
    receipt = _tao_exit_receipt(100_000, emitted)
    with pytest.raises(AssertionError, match="emitted"):
        checks.assert_payout_matches_emitted(0, emitted // 2 - gas_cost, receipt, "ctx")


def test_assert_payout_matches_emitted_rejects_a_receipt_without_the_event():
    with pytest.raises(AssertionError, match="UnwrappedForTao"):
        checks.assert_payout_matches_emitted(0, 0, {"gasUsed": 1, "logs": []}, "ctx")
