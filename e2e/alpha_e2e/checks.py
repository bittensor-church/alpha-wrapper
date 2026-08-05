"""Shared assertion helpers for balance deltas, gas budgets, and CSV output.

These encode the suite's cross-cutting measurement rules: payouts are judged
against pre-captured chain quotes, gas budgets separate designed pre-check
reverts from attempted-and-burned precompile dispatches, and the observability
scripts' CSV output is asserted row-by-row.
"""
import csv
import io
from typing import Dict, Iterable, List, Optional

from . import chain, config


def run_observability_script(
    script_name: str, *extra_args: str,
    address_args: List[str],
    block_start: Optional[int] = None, block_end: Optional[int] = None,
) -> str:
    """Run scripts/<script_name>.py and return its CSV stdout. Pass the block
    window for the event readers; omit it for the state readers that take none."""
    cmd = ["python3", f"scripts/{script_name}.py", "--rpc-url", config.RPC_URL, *address_args]
    if block_start is not None:
        cmd += ["--block-start", str(block_start), "--block-end", str(block_end)]
    cmd += list(extra_args)
    return chain.run(cmd).stdout


def min_tao_out_for(quote_rao: int) -> int:
    """Half the alpha->TAO quote, in wei: a slippage threshold loose enough to
    stay inside assert_payout_near_quote's factor-of-two acceptance band while
    still rejecting a broken payout."""
    return quote_rao * 10**9 // 2


def assert_gas_within(receipt: dict, bound: int, message: str) -> None:
    """Assert the transaction consumed at most `bound` gas. A rejected precompile
    dispatch consumes all forwarded gas, so staying far under the limit separates
    a designed pre-check revert (or a healthy call) from an attempted-and-burned
    dispatch."""
    gas_used = chain.receipt_gas_used(receipt)
    assert gas_used is not None, f"{message}: could not parse gasUsed"
    assert gas_used <= bound, f"{message} (consumed {gas_used} gas, bound {bound})"


def assert_positive_gain(balance_before_wei: int, balance_after_wei: int, message: str) -> int:
    """Assert a strictly positive wei delta and return it."""
    gain = balance_after_wei - balance_before_wei
    assert gain > 0, f"{message} (net {gain} wei)"
    return gain


def assert_tao_gain_near_quote(
    balance_before_wei: int, balance_after_wei: int, quote_rao: int, message: str,
) -> int:
    """Assert the caller's native-TAO gain matches a pre-captured alpha->TAO quote
    within +/-10% (which absorbs gas and a block or two of emission drift) -- a
    real value check, not just a positive delta. The precompile quotes in RAO,
    so x1e9 -> wei. Returns the wei gain."""
    gain = balance_after_wei - balance_before_wei
    expected_wei = quote_rao * 10**9
    assert expected_wei * 9 // 10 <= gain <= expected_wei * 11 // 10, (
        f"{message} (gained {gain} wei, quote {quote_rao} RAO)"
    )
    return gain


def reconstructed_payout(
    balance_before_wei: int, balance_after_wei: int, receipt: dict, message: str,
) -> int:
    """The caller's balance delta plus the gas it paid (fixed localnet gas
    price): dust-scale payouts are smaller than gas, so the raw delta alone
    proves nothing."""
    gas_used = chain.receipt_gas_used(receipt)
    assert gas_used is not None, f"{message}: could not parse gasUsed for payout reconstruction"
    return balance_after_wei - balance_before_wei + gas_used * config.LOCALNET_GAS_PRICE_WEI


UNWRAPPED_FOR_TAO = "UnwrappedForTao(address,uint256,uint256,uint256,uint256)"

# Native delivery is RAO-granular, so the sub-RAO remainder of what the vault reports stays behind.
RAO_WEI = 10**9


def assert_payout_matches_emitted(
    balance_before_wei: int, balance_after_wei: int, receipt: dict, message: str,
) -> None:
    """Assert the caller actually received what the TAO exit reported paying, to the RAO. The event
    is the vault's own claim; the balance delta is the chain's, so the two are independent."""
    payout = reconstructed_payout(balance_before_wei, balance_after_wei, receipt, message)
    emitted = chain.event_word(receipt, UNWRAPPED_FOR_TAO, 2, message)
    assert 0 <= emitted - payout < RAO_WEI, (
        f"{message} (emitted {emitted} wei, received {payout} wei)"
    )


def assert_payout_near_quote(
    balance_before_wei: int, balance_after_wei: int, receipt: dict,
    quote_rao: int, message: str,
) -> None:
    """Require the reconstructed payout within a factor of two of the
    pre-captured chain quote."""
    payout = reconstructed_payout(balance_before_wei, balance_after_wei, receipt, message)
    quote_wei = quote_rao * 10**9
    assert quote_wei // 2 <= payout <= 2 * quote_wei, (
        f"{message} (payout {payout} wei vs quote {quote_rao} RAO)"
    )


def assert_csv(
    csv_text: str, *, rows: Optional[int] = None,
    column_sets: Optional[Dict[str, Iterable[str]]] = None,
    column_subsets: Optional[Dict[str, Iterable[str]]] = None,
    column_eq: Optional[Dict[str, str]] = None,
    column_positive: Optional[Iterable[str]] = None,
) -> List[dict]:
    """Assert invariants over CSV text (one observability-script invocation):
    exact row count, per-column distinct-value set / subset, per-column constant
    value, and per-column strictly-positive integers. Returns the parsed rows."""
    parsed = list(csv.DictReader(io.StringIO(csv_text)))

    if rows is not None:
        assert len(parsed) == rows, f"row count: expected {rows}, got {len(parsed)}: {parsed}"

    for column, expected in (column_sets or {}).items():
        actual = {row[column] for row in parsed}
        assert actual == set(expected), (
            f"'{column}' set: expected {sorted(set(expected))}, got {sorted(actual)}"
        )

    for column, allowed in (column_subsets or {}).items():
        actual = {row[column] for row in parsed}
        extras = actual - set(allowed)
        assert not extras, (
            f"'{column}' subset: unexpected value(s) {sorted(extras)} "
            f"(allowed: {sorted(set(allowed))})"
        )

    for column, value in (column_eq or {}).items():
        mismatches = [row[column] for row in parsed if row[column] != value]
        assert not mismatches, (
            f"'{column}': expected all '{value}', got {len(mismatches)} mismatch(es), "
            f"e.g. {mismatches[0]!r}"
        )

    for column in column_positive or []:
        bad = [
            row[column] for row in parsed
            if not (row[column].lstrip("-").isdigit() and int(row[column]) > 0)
        ]
        assert not bad, f"'{column}': expected positive ints, got bad value e.g. {bad[0]!r}"

    return parsed
