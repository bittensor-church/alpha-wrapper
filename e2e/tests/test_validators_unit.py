"""Chainless checks for validator update transactions."""
import pytest

from alpha_e2e import chain, config, validators


@pytest.mark.parametrize("status", ["0x1", "0x0"])
def test_basic_transaction_uses_owner_and_checks_receipt(monkeypatch, status):
    calls = []
    receipt = {"status": status, "transactionHash": "0x01"}
    def send(*args, **kwargs):
        calls.append((args, kwargs))
        return receipt
    monkeypatch.setattr(chain, "cast_send", send)
    monkeypatch.setattr(chain, "report_gas", lambda *args, **kwargs: None)
    if status == "0x1":
        assert validators.set_basic_validator("registry", 7, "A") == "0x01"
    else:
        with pytest.raises(validators.ValidatorUpdateError, match="setValidator failed"):
            validators.set_basic_validator("registry", 7, "A")
    assert calls == [(("registry", "setValidator(uint256,bytes32)", 7, "A"),
                      {"private_key": config.DEPLOYER_PRIVATE_KEY, "gas_limit": 500_000})]
