#!/usr/bin/env python3

"""
Assert invariants over a CSV stream from stdin. Exits 1 with a message on the first
failure.
"""

import argparse
import csv
import sys


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rows", type=int, help="Expected row count")
    parser.add_argument(
        "--column-set", action="append", default=[], metavar="COL=v1,v2,...",
        help="Distinct values of COL must equal this set (order-independent)",
    )
    parser.add_argument(
        "--column-subset", action="append", default=[], metavar="COL=v1,v2,...",
        help="Distinct values of COL must be a subset of this set (order-independent)",
    )
    parser.add_argument(
        "--column-eq", action="append", default=[], metavar="COL=value",
        help="All rows must have COL == value",
    )
    parser.add_argument(
        "--column-positive", action="append", default=[], metavar="COL",
        help="All rows must have COL parseable as a strictly positive integer",
    )
    args = parser.parse_args()

    rows = list(csv.DictReader(sys.stdin))

    def fail(msg: str) -> None:
        print(f"verify_csv: {msg}", file=sys.stderr)
        sys.exit(1)

    if args.rows is not None and len(rows) != args.rows:
        fail(f"row count: expected {args.rows}, got {len(rows)}")

    for spec in args.column_set:
        col, vals = spec.split("=", 1)
        expected = set(vals.split(","))
        actual = {r[col] for r in rows}
        if actual != expected:
            fail(f"'{col}' set: expected {sorted(expected)}, got {sorted(actual)}")

    for spec in args.column_subset:
        col, vals = spec.split("=", 1)
        allowed = set(vals.split(","))
        actual = {r[col] for r in rows}
        extras = actual - allowed
        if extras:
            fail(f"'{col}' subset: unexpected value(s) {sorted(extras)} (allowed: {sorted(allowed)})")

    for spec in args.column_eq:
        col, val = spec.split("=", 1)
        bad = [r[col] for r in rows if r[col] != val]
        if bad:
            fail(f"'{col}': expected all '{val}', got {len(bad)} mismatch(es), e.g. {bad[0]!r}")

    for col in args.column_positive:
        bad = [r[col] for r in rows if not (r[col].lstrip("-").isdigit() and int(r[col]) > 0)]
        if bad:
            fail(f"'{col}': expected positive ints, got bad value e.g. {bad[0]!r}")

    print(f"verify_csv: {len(rows)} rows ok", file=sys.stderr)


if __name__ == "__main__":
    main()
