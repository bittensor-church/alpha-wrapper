"""Chainless unit tests for alpha_e2e.chain's cast-output and receipt parsing."""
from alpha_e2e import chain


def test_strip_cast_scientific_suffix():
    # cast prints: "1000000000000000000 [1e18]" -- keep the integer token only.
    assert chain._first_token("1000000000000000000 [1e18]") == "1000000000000000000"
    assert chain._first_token("0x70997970C51812dc3A010C7d01b50e0d17dc79C8") == \
        "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
    assert chain._first_token("") == ""


def test_tokens_per_line_parse_multi_return():
    raw = "123 [1.2e2]\n456 [4.5e2]\n"
    assert chain._tokens_per_line(raw) == ["123", "456"]


def test_receipt_ok():
    assert chain.receipt_ok({"status": "0x1"}) is True
    assert chain.receipt_ok({"status": "0x0"}) is False
    assert chain.receipt_ok({}) is False


def test_receipt_gas_used_parses_int_hex_and_decimal():
    assert chain.receipt_gas_used({"gasUsed": 21_000}) == 21_000
    assert chain.receipt_gas_used({"gasUsed": "0x5208"}) == 21_000
    assert chain.receipt_gas_used({"gasUsed": "21000"}) == 21_000


def test_receipt_gas_used_is_none_when_unparseable():
    assert chain.receipt_gas_used({}) is None
    assert chain.receipt_gas_used({"gasUsed": None}) is None
    assert chain.receipt_gas_used({"gasUsed": "not-a-number"}) is None
