"""Chainless tests for the observability scripts' block-range handling."""
import pathlib
import sys

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "scripts"))

import common  # noqa: E402


def test_block_chunks_covers_the_range_exactly_once():
    assert list(common.block_chunks(0, 9, 4)) == [(0, 3), (4, 7), (8, 9)]


def test_block_chunks_keeps_a_range_that_fits_in_one_request_whole():
    assert list(common.block_chunks(100, 120, 1_000)) == [(100, 120)]


def test_block_chunks_yields_one_window_for_a_single_block():
    assert list(common.block_chunks(7, 7, 10)) == [(7, 7)]


@pytest.mark.parametrize("size", [0, -1])
def test_block_chunks_rejects_a_chunk_size_that_makes_no_progress(size):
    with pytest.raises(ValueError, match="at least 1 block"):
        list(common.block_chunks(0, 10, size))


@pytest.mark.parametrize("block_start,block_end", [(-1, 10), (10, 9)])
def test_fetch_event_logs_rejects_an_impossible_range(block_start, block_end):
    with pytest.raises(ValueError, match="0 <= start <= end"):
        common.fetch_event_logs(None, "0x" + "11" * 20, "AlphaVault", "Deposited", block_start, block_end)
