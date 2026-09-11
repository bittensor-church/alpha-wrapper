"""Chainless unit tests for alpha_e2e.chain's cast-output and receipt parsing."""
import json
from subprocess import CompletedProcess, TimeoutExpired

import pytest

from alpha_e2e import chain


def test_cast_call_returns_the_integer_without_the_scientific_suffix(monkeypatch):
    # cast prints: "1000000000000000000 [1e18]" -- keep the integer token only.
    monkeypatch.setattr(chain, "run", lambda cmd, **kwargs: CompletedProcess(cmd, 0, "1000000000000000000 [1e18]\n", ""))
    assert chain.cast_call("0x123", "totalSupply()(uint256)") == "1000000000000000000"


def test_cast_call_lines_preserves_the_order_of_multiple_return_values(monkeypatch):
    raw = "123 [1.2e2]\n456 [4.5e2]\n"
    monkeypatch.setattr(chain, "run", lambda cmd, **kwargs: CompletedProcess(cmd, 0, raw, ""))
    assert chain.cast_call_lines("0x123", "previewUnwrap()(uint256,uint256)") == ["123", "456"]


@pytest.mark.parametrize("output", ["", "error: connection refused", "[]", "{}", '{"status":"0x0"}'])
def test_cast_send_rejects_failures_without_a_mined_receipt(monkeypatch, output):
    monkeypatch.setattr(chain, "run", lambda *args, **kwargs: CompletedProcess([], 1, output, "submission failed"))
    with pytest.raises(chain.ChainError, match="receipt"):
        chain.cast_send("0x123", "claimTao(uint256,address)", 1, "0x456", private_key="test-key", gas_limit=100_000)


@pytest.mark.parametrize("status", ["0x0", "0x1"])
def test_cast_send_returns_mined_successes_and_reverts(monkeypatch, status):
    receipt = {"status": status, "transactionHash": "0x" + "ab" * 32, "blockNumber": "0x7", "gasUsed": "0x5208"}
    exit_code = 1 if status == "0x0" else 0
    monkeypatch.setattr(chain, "run", lambda *args, **kwargs: CompletedProcess([], exit_code, json.dumps(receipt), ""))
    actual = chain.cast_send(
        "0x123", "claimTao(uint256,address)", 1, "0x456", private_key="test-key", gas_limit=100_000,
    )
    assert actual == receipt


@pytest.mark.parametrize("missing", ["transactionHash", "blockNumber", "gasUsed"])
def test_cast_send_rejects_a_revert_without_execution_evidence(monkeypatch, missing):
    receipt = {"status": "0x0", "transactionHash": "0x" + "ab" * 32, "blockNumber": "0x7", "gasUsed": "0x5208"}
    del receipt[missing]
    monkeypatch.setattr(chain, "run", lambda *args, **kwargs: CompletedProcess([], 1, json.dumps(receipt), ""))
    with pytest.raises(chain.ChainError, match="incomplete receipt"):
        chain.cast_send("0x123", "claimTao(uint256,address)", 1, "0x456", private_key="test-key", gas_limit=100_000)


def test_run_reports_a_command_that_never_returns(monkeypatch):
    def never_returns(cmd, **kwargs):
        raise TimeoutExpired(cmd, kwargs["timeout"])

    monkeypatch.setattr(chain.subprocess, "run", never_returns)
    with pytest.raises(chain.ChainError, match="cast block-number"):
        chain.cast_block_number()


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



def _probe(monkeypatch, returncode: int, stdout: str = "", stderr: str = ""):
    monkeypatch.setattr(chain, "run", lambda cmd, **kwargs: CompletedProcess(cmd, returncode, stdout, stderr))


def test_quote_returns_the_pool_answer(monkeypatch):
    _probe(monkeypatch, 0, stdout="1234\n")
    assert chain.quote_alpha_for_tao(2, 5) == 1234


def test_quote_reports_a_refusal_as_none(monkeypatch):
    refusal = 'Error: server returned an error response: error code -32603: evm error: Other("ReservesTooLow")'
    _probe(monkeypatch, 1, stderr=refusal)
    assert chain.quote_alpha_for_tao(2, 1) is None


def test_quote_raises_on_a_transport_failure(monkeypatch):
    _probe(monkeypatch, 1, stderr="error sending request for url: connection refused")
    with pytest.raises(chain.ChainError):
        chain.quote_alpha_for_tao(2, 1)
