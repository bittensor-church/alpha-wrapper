"""Chainless tests for the pool quote probe: a refusal is not a transport failure."""
import subprocess

import pytest

from alpha_e2e import chain


def _probe(monkeypatch, returncode: int, stdout: str = "", stderr: str = ""):
    monkeypatch.setattr(
        chain, "run",
        lambda cmd, **kwargs: subprocess.CompletedProcess(cmd, returncode, stdout=stdout, stderr=stderr),
    )


def test_quote_returns_the_pool_answer(monkeypatch):
    _probe(monkeypatch, 0, stdout="1234\n")
    assert chain.quote_alpha_for_tao(2, 5) == 1234


def test_quote_reports_a_refusal_as_none(monkeypatch):
    _probe(monkeypatch, 1, stderr='Error: server returned an error response: error code -32603: evm error: Other("ReservesTooLow")')
    assert chain.quote_alpha_for_tao(2, 1) is None


def test_quote_raises_on_a_transport_failure(monkeypatch):
    _probe(monkeypatch, 1, stderr="error sending request for url: connection refused")
    with pytest.raises(chain.ChainError):
        chain.quote_alpha_for_tao(2, 1)
