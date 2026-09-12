"""Chainless checks for registry selection; no scenario may silently truncate a set."""
from types import SimpleNamespace

import pytest

from alpha_e2e import bootstrap, chain, config, validators
from alpha_e2e.environment import Environment


def _environment(registry_type):
    env = Environment.__new__(Environment)
    env.registry_type = registry_type
    env.validator_registry_address = "registry"
    return env


@pytest.mark.parametrize("hotkeys, weights", [(["A", "B"], [5000, 5000]), (["A"], [9999]), ([], [])])
def test_basic_update_rejects_implicit_conversion(hotkeys, weights):
    with pytest.raises(ValueError, match="explicitly select"):
        _environment("basic").set_validators(7, hotkeys, weights)


def test_basic_update_rejects_a_target_outside_the_requested_set():
    with pytest.raises(ValueError, match="must belong"):
        _environment("basic").set_validators(7, ["A"], [10000], basic_hotkey="B")


@pytest.mark.parametrize("explicit", [False, True])
def test_basic_update_submits_only_the_selected_hotkey(monkeypatch, explicit):
    calls = []
    monkeypatch.setattr(validators, "set_basic_validator", lambda *args: calls.append(args))
    def refuse_attestation(*args, **kwargs):
        raise AssertionError("Basic must not sign an attestation")
    monkeypatch.setattr(validators, "set_validators", refuse_attestation)
    env = _environment("basic")
    if explicit:
        env.set_validators(7, ["A", "B"], [5000, 5000], basic_hotkey="B")
    else:
        env.set_validators(7, ["B"], [10000])
    assert calls == [("registry", 7, "B")]


def test_attested_update_preserves_the_whole_set(monkeypatch):
    calls = []
    monkeypatch.setattr(validators, "set_validators", lambda *args: calls.append(args))
    _environment("attested").set_validators(7, ["A", "B"], [5000, 5000], basic_hotkey="B")
    assert calls == [("registry", [config.DEPLOYER_PRIVATE_KEY, config.WRAPPER_USER_PRIVATE_KEY],
                      7, ["A", "B"], [5000, 5000])]


@pytest.mark.parametrize("status", ["0x1", "0x0"])
def test_basic_transaction_uses_admin_and_checks_receipt(monkeypatch, status):
    calls = []
    receipt = {"status": status}
    def send(*args, **kwargs):
        calls.append((args, kwargs))
        return receipt
    monkeypatch.setattr(chain, "cast_send", send)
    monkeypatch.setattr(chain, "report_gas", lambda *args, **kwargs: None)
    if status == "0x1":
        assert validators.set_basic_validator("registry", 7, "A") == receipt
    else:
        with pytest.raises(validators.ValidatorUpdateError, match="setValidator failed"):
            validators.set_basic_validator("registry", 7, "A")
    assert calls == [(("registry", "setValidator(uint256,bytes32)", 7, "A"),
                      {"private_key": config.DEPLOYER_PRIVATE_KEY, "gas_limit": 500_000})]


@pytest.mark.parametrize("registry_kind", ["attested", "basic"])
def test_bootstrap_deploys_and_configures_the_selected_registry(monkeypatch, registry_kind):
    deployments, updates, attestations = [], [], []
    def create(artifact, **kwargs):
        deployments.append((artifact, kwargs))
        return artifact.split(":")[-1]
    monkeypatch.setattr(chain, "forge_create", create)
    monkeypatch.setattr(chain, "forge_build", lambda: None)
    monkeypatch.setattr(chain, "cast_block_number", lambda: 42)
    monkeypatch.setattr(chain, "cast_call", lambda *args: "65543")
    monkeypatch.setattr(validators, "set_basic_validator", lambda *args: updates.append(args))
    monkeypatch.setattr(validators, "set_validators", lambda *args: attestations.append(args))
    result = bootstrap._deploy_contracts([7, 8], ["A", "B", "C", "D", "E", "F"],
                                         recovery_window=180, registry_type=registry_kind)
    contract = "BasicValidatorRegistry" if registry_kind == "basic" else "ValidatorRegistry"
    assert result[3].validator_registry_address == contract
    registry_deploy = next(kwargs for artifact, kwargs in deployments if artifact.endswith(":" + contract))
    vault_deploy = next(kwargs for artifact, kwargs in deployments if artifact.endswith(":AlphaVault"))
    assert vault_deploy["constructor_args"][3] == contract
    if registry_kind == "basic":
        assert registry_deploy["constructor_args"] == [config.DEPLOYER_ADDRESS]
        assert updates == [(contract, 7, "A"), (contract, 8, "D")]
        assert not attestations
    else:
        assert registry_deploy["constructor_args"] == [config.DEPLOYER_ADDRESS,
                f"[{config.DEPLOYER_ADDRESS},{config.WRAPPER_USER_ADDRESS}]", "2"]
        assert not updates
        assert [(call[2], call[3], call[4]) for call in attestations] == [
            (7, ["A", "B", "C"], [5000, 3000, 2000]), (8, ["D", "E", "F"], [5000, 3000, 2000]),
        ]


@pytest.mark.parametrize("registry_kind, expected_count", [("attested", 3), ("basic", 1)])
def test_observability_decodes_the_selected_registry_event(monkeypatch, capsys, registry_kind, expected_count):
    import pathlib
    import sys
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "scripts"))
    import get_validator_updates as script

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
