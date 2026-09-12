"""Chainless checks for both registry event formats."""
import sys
from types import SimpleNamespace

import pytest

import get_validator_updates as script


@pytest.mark.parametrize("registry_kind, expected_count", [("attested", 3), ("basic", 1)])
def test_observability_decodes_the_selected_registry_event(monkeypatch, capsys, registry_kind, expected_count):
    monkeypatch.setattr(sys, "argv", ["get_validator_updates", "--registry-address", "registry",
                        "--registry-type", registry_kind, "--rpc-url", "http://unused",
                        "--block-start", "1", "--block-end", "42"])
    connection = SimpleNamespace(eth=SimpleNamespace(get_block=lambda number: SimpleNamespace(timestamp=123)))
    monkeypatch.setattr(script, "get_web3_connection", lambda url: connection)
    calls = []
    def logs(*args, **kwargs):
        calls.append(args)
        event = {"netuid": 7, "nonce": 2}
        if registry_kind == "basic":
            event.update(hotkey="A", owner="owner")
        else:
            event.update(hotkeys=["A", "B", "C"], weights=[5000, 3000, 2000])
        return [({"transactionHash": SimpleNamespace(to_0x_hex=lambda: "0x01"), "blockNumber": 42}, event)]
    monkeypatch.setattr(script, "fetch_event_logs", logs)
    script.main()
    contract, event = ("BasicValidatorRegistry", "ValidatorUpdated") if registry_kind == "basic" else (
        "ValidatorRegistry", "ValidatorsUpdated")
    assert calls[0][2:4] == (contract, event)
    assert f"0x01,7,2,{expected_count},123" in capsys.readouterr().out
