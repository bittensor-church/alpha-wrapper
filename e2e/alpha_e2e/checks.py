"""Shared assertion helpers for balance deltas, gas budgets, and CSV output.

These encode the suite's cross-cutting measurement rules: TAO payouts are judged
against the chain's own alpha->TAO quote at the block before the exit, gas budgets
separate designed pre-check reverts from attempted-and-burned precompile
dispatches, and the observability scripts' CSV output is asserted row-by-row.
"""
import csv
import io
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional

from . import chain, config, environment

# Native delivery is RAO-granular, so the sub-RAO remainder of what the vault reports stays behind.
RAO_WEI = 10**9


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
    """Half a pre-call alpha->TAO quote, in wei: a slippage floor that a dividend
    landing before the exit can only lift the payout further above, while a payout
    that halves is still rejected."""
    return quote_rao * RAO_WEI // 2


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


def reconstructed_payout(
    balance_before_wei: int, balance_after_wei: int, receipt: dict, message: str,
) -> int:
    """The caller's balance delta plus the gas it paid (fixed localnet gas
    price): dust-scale payouts are smaller than gas, so the raw delta alone
    proves nothing."""
    gas_used = chain.receipt_gas_used(receipt)
    assert gas_used is not None, f"{message}: could not parse gasUsed for payout reconstruction"
    return balance_after_wei - balance_before_wei + gas_used * config.LOCALNET_GAS_PRICE_WEI


@dataclass(frozen=True)
class TaoSale:
    """Where an exit that pays TAO reports the alpha it sold and the TAO it paid: the
    event's signature and the data-word index of each."""
    event: str
    alpha_word: int
    tao_word: int


VAULT_TAO_EXIT = TaoSale("UnwrappedForTao(address,uint256,uint256,uint256,uint256)", 1, 2)
MAILBOX_TAO_RECLAIM = TaoSale(
    "MailboxAlphaSoldForTao(address,uint256,bytes32,uint256,uint256)", 0, 1,
)


def assert_payout_matches_emitted(
    balance_before_wei: int, balance_after_wei: int, receipt: dict, message: str,
    sale: TaoSale = VAULT_TAO_EXIT,
) -> None:
    """Assert the caller actually received what the TAO exit reported paying, to the RAO. The event
    is the vault's own claim; the balance delta is the chain's, so the two are independent."""
    payout = reconstructed_payout(balance_before_wei, balance_after_wei, receipt, message)
    emitted = chain.event_word(receipt, sale.event, sale.tao_word, message)
    assert 0 <= emitted - payout < RAO_WEI, (
        f"{message} (emitted {emitted} wei, received {payout} wei)"
    )


def assert_payout_near_quote(
    balance_before_wei: int, balance_after_wei: int, receipt: dict,
    netuid: int, quoted_alpha_rao: Optional[int], message: str,
    sale: TaoSale = VAULT_TAO_EXIT,
) -> int:
    """Assert the exit paid within +/-10% of the chain's quote for the alpha it reports
    selling, priced at the block before the exit, and sold at least `quoted_alpha_rao`.
    Returns the alpha sold (RAO).

    An exit sells whatever backs the position when it runs, and a staking dividend
    landing first can multiply that, so no amount captured earlier bounds the payout;
    the reported amount priced at the exit's own block does. The quoted amount keeps
    that report honest against selling short. Pass None for a partial exit: the vault
    cuts one short wherever a slot's leftover would fall under the chain's dust
    threshold and refunds those shares, so its caller holds the report to the shares
    that actually burned instead.
    """
    payout = reconstructed_payout(balance_before_wei, balance_after_wei, receipt, message)
    alpha_sold = chain.event_word(receipt, sale.event, sale.alpha_word, message)
    if quoted_alpha_rao is not None:
        assert alpha_sold >= quoted_alpha_rao - config.ROUNDING_DUST_TOTAL_RAO, (
            f"{message} (sold {alpha_sold} alpha RAO of the {quoted_alpha_rao} quoted)"
        )
    pre_exit_block = chain.receipt_block_number(receipt, message) - 1
    quote_wei = environment.alpha_to_tao_quote(netuid, alpha_sold, block=pre_exit_block) * RAO_WEI
    assert quote_wei * 9 // 10 <= payout <= quote_wei * 11 // 10, (
        f"{message} (payout {payout} wei for {alpha_sold} alpha RAO, "
        f"quoted {quote_wei} wei at block {pre_exit_block})"
    )
    return alpha_sold


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
