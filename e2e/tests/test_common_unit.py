"""Chainless tests for the observability scripts' block-range handling."""
import argparse

import pytest

import common


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


class _MovingHead:
    """A head that advances on every read, the way a live node's does."""

    def __init__(self):
        self.reads = 0

    @property
    def block_number(self):
        self.reads += 1
        return 1_000 + self.reads


class _FakeWeb3:
    def __init__(self):
        self.eth = _MovingHead()


def test_resolve_block_reads_the_head_exactly_once():
    w3 = _FakeWeb3()
    assert common.resolve_block(w3, None) == 1_001
    assert w3.eth.reads == 1


def test_resolve_block_keeps_an_explicit_block_without_touching_the_head():
    w3 = _FakeWeb3()
    assert common.resolve_block(w3, 42) == 42
    assert w3.eth.reads == 0


def test_resolve_block_rejects_a_relative_offset():
    with pytest.raises(ValueError, match="non-negative"):
        common.resolve_block(_FakeWeb3(), -1)


def test_block_number_argument_rejects_a_relative_offset():
    with pytest.raises(argparse.ArgumentTypeError, match="non-negative"):
        common.block_number("-1")
    assert common.block_number("7") == 7
