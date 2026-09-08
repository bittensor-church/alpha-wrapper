"""Chainless tests for the TAO exit planner's slot resolution and quote classification."""
import pathlib
import sys

import pytest
from web3.exceptions import ContractLogicError, Web3RPCError

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "scripts"))

import plan_tao_exit as planner  # noqa: E402

OLD = bytes.fromhex("11" * 32)
SUCCESSOR = bytes.fromhex("22" * 32)


def test_resolve_slot_follows_a_covering_successor_past_a_residue():
    balances = {OLD: 3, SUCCESSOR: 10_000_000}
    key, balance = planner.resolve_slot(OLD, 10_000_000, balances.__getitem__, lambda _hotkey: SUCCESSOR)
    assert (key, balance) == (SUCCESSOR, 10_000_000)


def test_resolve_slot_keeps_a_recorded_key_that_covers_within_slack():
    key, balance = planner.resolve_slot(OLD, 10_000_000, lambda _hotkey: 9_999_500, lambda _hotkey: None)
    assert (key, balance) == (OLD, 9_999_500)


def test_resolve_slot_refuses_to_plan_an_unlocated_slot():
    with pytest.raises(planner.Unresolved):
        planner.resolve_slot(OLD, 10_000_000, lambda _hotkey: 0, lambda _hotkey: None)


class _Quoter:
    def __init__(self, outcome):
        self._outcome = outcome
        self.functions = self

    def simSwapAlphaForTao(self, _netuid, _alpha):  # noqa: N802 - mirrors the ABI
        return self

    def call(self):
        if isinstance(self._outcome, Exception):
            raise self._outcome
        return self._outcome


def test_quote_reports_an_evm_refusal_as_none():
    assert planner.quote(_Quoter(ContractLogicError("execution reverted")), 2, 1) is None
    refused = Web3RPCError(
        "refused", rpc_response={"error": {"code": -32603, "message": 'evm error: Other("ReservesTooLow")'}},
    )
    assert planner.quote(_Quoter(refused), 2, 1) is None


def test_quote_lets_a_transport_failure_through():
    with pytest.raises(ConnectionError):
        planner.quote(_Quoter(ConnectionError("connection refused")), 2, 1)
    node_trouble = Web3RPCError("unavailable", rpc_response={"error": {"code": -32603, "message": "client is syncing"}})
    with pytest.raises(Web3RPCError):
        planner.quote(_Quoter(node_trouble), 2, 1)
