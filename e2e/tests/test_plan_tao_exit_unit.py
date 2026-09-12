"""Chainless tests for the TAO exit planner's per-slot decisions and quote classification."""

import pytest
from web3.exceptions import ContractLogicError, Web3RPCError

import plan_tao_exit as planner

FIRST = bytes.fromhex("11" * 32)
SECOND = bytes.fromhex("22" * 32)
THIRD = bytes.fromhex("33" * 32)


def test_plan_exit_excludes_the_slots_the_pool_will_not_pay_for():
    refused = {2: None, 3: 0}
    plan = planner.plan_exit(
        [FIRST, SECOND, THIRD], [1, 2, 3], [False, False, False],
        lambda balance: refused.get(balance, balance * 7),
    )
    assert plan.refusal is None
    assert plan.mask == 0b110
    assert plan.verdicts[0].endswith("quote 7 sellable")
    assert "EXCLUDED: the pool refused the quote" in plan.verdicts[1]
    assert "EXCLUDED: quotes zero" in plan.verdicts[2]


def test_plan_exit_leaves_an_empty_slot_unquoted_and_included():
    plan = planner.plan_exit([FIRST], [0], [False], _unreachable_quote)
    assert (plan.mask, plan.refusal) == (0, None)
    assert plan.verdicts == [f"slot 0: 0x{FIRST.hex()} is empty"]


def test_plan_exit_refuses_to_plan_around_a_short_slot():
    plan = planner.plan_exit(
        [FIRST, SECOND], [5, 5], [False, True], lambda balance: balance,
    )
    assert plan.refusal is not None
    assert f"slot 1: 0x{SECOND.hex()}" in plan.refusal
    assert len(plan.verdicts) == 1


def _unreachable_quote(balance: int) -> int:
    raise AssertionError(f"an empty slot was quoted with {balance}")


class _Quoter:
    def __init__(self, outcome):
        self._outcome = outcome
        self.functions = self

    def simSwapAlphaForTao(self, _netuid, _alpha):  # noqa: N802 - mirrors the ABI
        return self

    def call(self, block_identifier=None):
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
