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


NETUID = 7
EXIT_BLOCK = 32
EXIT_GAS = 100_000
EXIT_GAS_WEI = EXIT_GAS * config.LOCALNET_GAS_PRICE_WEI
QUOTED_ALPHA_RAO = 500
# The stubbed chain prices alpha flat, so a fair payout is the alpha sold times this.
PRICE_RAO = 2
FAIR_PAYOUT_WEI = QUOTED_ALPHA_RAO * PRICE_RAO * checks.RAO_WEI


@pytest.fixture
def flat_quote(monkeypatch):
    """The chain's alpha->TAO quote at a flat price, answering only for the block
    before the exit."""
    def quote(netuid, alpha_rao, block=None):
        assert (netuid, block) == (NETUID, EXIT_BLOCK - 1)
        return alpha_rao * PRICE_RAO
    monkeypatch.setattr(checks.environment, "alpha_to_tao_quote", quote)


def _tao_exit_receipt(
    alpha_sold: int, emitted_wei: int, gas_used: int = EXIT_GAS,
    sale: checks.TaoSale = checks.VAULT_TAO_EXIT,
) -> dict:
    words = [0] * (max(sale.alpha_word, sale.tao_word) + 1)
    words[sale.alpha_word] = alpha_sold
    words[sale.tao_word] = emitted_wei
    data = "0x" + "".join(f"{word:064x}" for word in words)
    return {
        "gasUsed": gas_used, "blockNumber": hex(EXIT_BLOCK),
        "logs": [{"topics": [chain.cast_sig_event(sale.event)], "data": data}],
    }


def _check_payout(
    payout_wei: int, alpha_sold: int = QUOTED_ALPHA_RAO,
    sale: checks.TaoSale = checks.VAULT_TAO_EXIT,
) -> int:
    """Run the near-quote check on an exit that paid `payout_wei` before gas."""
    return checks.assert_payout_near_quote(
        0, payout_wei - EXIT_GAS_WEI, _tao_exit_receipt(alpha_sold, 0, sale=sale),
        NETUID, QUOTED_ALPHA_RAO, "ctx", sale,
    )


@pytest.mark.parametrize("tenths", [9, 10, 11])
def test_assert_payout_near_quote_accepts_within_ten_percent(flat_quote, tenths):
    assert _check_payout(FAIR_PAYOUT_WEI * tenths // 10) == QUOTED_ALPHA_RAO


@pytest.mark.parametrize("tenths", [8, 12])
def test_assert_payout_near_quote_rejects_outside_ten_percent(flat_quote, tenths):
    with pytest.raises(AssertionError, match="quoted .* wei"):
        _check_payout(FAIR_PAYOUT_WEI * tenths // 10)


def test_assert_payout_near_quote_adds_gas_back(flat_quote):
    # The fair payout is smaller than the gas burned, so the raw balance delta is
    # negative and only verifies once gas is added back.
    assert FAIR_PAYOUT_WEI < EXIT_GAS_WEI
    _check_payout(FAIR_PAYOUT_WEI)


def test_assert_payout_near_quote_prices_the_alpha_the_exit_sold(flat_quote):
    # A dividend landing before the exit multiplies what it sells; the payout is
    # judged against that amount, not the one quoted beforehand.
    grown_alpha = QUOTED_ALPHA_RAO * 10
    assert _check_payout(FAIR_PAYOUT_WEI * 10, alpha_sold=grown_alpha) == grown_alpha
    with pytest.raises(AssertionError, match="quoted .* wei"):
        _check_payout(FAIR_PAYOUT_WEI, alpha_sold=grown_alpha)


def test_assert_payout_near_quote_tolerates_rounding_dust_on_the_alpha_sold(flat_quote):
    sold = QUOTED_ALPHA_RAO - config.ROUNDING_DUST_TOTAL_RAO
    _check_payout(sold * PRICE_RAO * checks.RAO_WEI, alpha_sold=sold)


def test_assert_payout_near_quote_rejects_selling_short(flat_quote):
    sold = QUOTED_ALPHA_RAO - config.ROUNDING_DUST_TOTAL_RAO - 1
    with pytest.raises(AssertionError, match="of the 500 quoted"):
        _check_payout(sold * PRICE_RAO * checks.RAO_WEI, alpha_sold=sold)


def test_assert_payout_near_quote_leaves_a_partial_exit_unfloored(flat_quote):
    sold = QUOTED_ALPHA_RAO // 2
    assert checks.assert_payout_near_quote(
        0, sold * PRICE_RAO * checks.RAO_WEI - EXIT_GAS_WEI, _tao_exit_receipt(sold, 0),
        NETUID, None, "ctx",
    ) == sold


def test_assert_payout_near_quote_reads_the_mailbox_sale(flat_quote):
    mailbox = checks.MAILBOX_TAO_RECLAIM
    assert _check_payout(FAIR_PAYOUT_WEI, sale=mailbox) == QUOTED_ALPHA_RAO
    with pytest.raises(AssertionError, match="UnwrappedForTao"):
        checks.assert_payout_near_quote(
            0, 0, _tao_exit_receipt(QUOTED_ALPHA_RAO, 0, sale=mailbox),
            NETUID, QUOTED_ALPHA_RAO, "ctx",
        )


@pytest.mark.parametrize("missing, match", [
    ("gasUsed", "gasUsed"), ("blockNumber", "blockNumber"), ("logs", "UnwrappedForTao"),
])
def test_assert_payout_near_quote_rejects_an_incomplete_receipt(flat_quote, missing, match):
    receipt = _tao_exit_receipt(QUOTED_ALPHA_RAO, 0)
    del receipt[missing]
    with pytest.raises(AssertionError, match=match):
        checks.assert_payout_near_quote(
            0, FAIR_PAYOUT_WEI, receipt, NETUID, QUOTED_ALPHA_RAO, "ctx",
        )


def test_assert_payout_matches_emitted_accepts_the_reported_amount():
    emitted = 5 * checks.RAO_WEI
    receipt = _tao_exit_receipt(5, emitted)
    checks.assert_payout_matches_emitted(0, emitted - EXIT_GAS_WEI, receipt, "ctx")


def test_assert_payout_matches_emitted_reads_the_mailbox_sale():
    emitted = 5 * checks.RAO_WEI
    receipt = _tao_exit_receipt(5, emitted, sale=checks.MAILBOX_TAO_RECLAIM)
    checks.assert_payout_matches_emitted(
        0, emitted - EXIT_GAS_WEI, receipt, "ctx", checks.MAILBOX_TAO_RECLAIM,
    )


def test_assert_payout_matches_emitted_tolerates_the_sub_rao_remainder():
    emitted = 5 * checks.RAO_WEI + 7
    receipt = _tao_exit_receipt(5, emitted)
    checks.assert_payout_matches_emitted(0, emitted - 7 - EXIT_GAS_WEI, receipt, "ctx")


def test_assert_payout_matches_emitted_rejects_a_shortfall():
    emitted = 5 * checks.RAO_WEI
    receipt = _tao_exit_receipt(5, emitted)
    with pytest.raises(AssertionError, match="emitted"):
        checks.assert_payout_matches_emitted(0, emitted // 2 - EXIT_GAS_WEI, receipt, "ctx")


def test_assert_payout_matches_emitted_rejects_a_receipt_without_the_event():
    with pytest.raises(AssertionError, match="UnwrappedForTao"):
        checks.assert_payout_matches_emitted(0, 0, {"gasUsed": 1, "logs": []}, "ctx")
