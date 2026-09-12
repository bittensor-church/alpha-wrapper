"""Chainless tests for the wallet the suite generates: it never touches a key it did not make."""
import os

import pytest

from alpha_e2e import bootstrap, chain, config, validators


def _refuse_btcli(monkeypatch):
    def refuse(args, **kwargs):
        raise AssertionError(f"btcli was invoked: {args}")

    monkeypatch.setattr(chain, "btcli_local", refuse)


def test_ensure_alice_wallet_keeps_a_private_key_that_lacks_its_public_file(tmp_path, monkeypatch):
    wallet_dir = tmp_path / config.ALICE_WALLET
    wallet_dir.mkdir()
    (wallet_dir / "coldkey").write_text("someone's key")
    monkeypatch.setattr(config, "WALLET_PATH", str(tmp_path))
    _refuse_btcli(monkeypatch)

    with pytest.raises(RuntimeError, match="without a readable coldkeypub"):
        bootstrap._ensure_alice_wallet()
    assert (wallet_dir / "coldkey").read_text() == "someone's key"


def test_ensure_alice_wallet_keeps_a_foreign_coldkey(tmp_path, monkeypatch):
    wallet_dir = tmp_path / config.ALICE_WALLET
    wallet_dir.mkdir()
    (wallet_dir / "coldkeypub.txt").write_text('{"ss58Address": "5Foreign"}')
    monkeypatch.setattr(config, "WALLET_PATH", str(tmp_path))
    _refuse_btcli(monkeypatch)

    with pytest.raises(RuntimeError, match="not the dev Alice"):
        bootstrap._ensure_alice_wallet()


def test_ensure_alice_wallet_generates_only_into_an_absent_directory(tmp_path, monkeypatch):
    wallet_dir = tmp_path / config.ALICE_WALLET
    monkeypatch.setattr(config, "WALLET_PATH", str(tmp_path))
    commands = []

    def record(args, **kwargs):
        commands.append(args)
        if args[:2] == ["wallet", "regen-coldkey"]:
            wallet_dir.mkdir()
            (wallet_dir / "coldkeypub.txt").write_text(config.ALICE_COLDKEY_SS58)
        else:
            os.makedirs(wallet_dir / "hotkeys", exist_ok=True)
            (wallet_dir / "hotkeys" / config.ALICE_HOTKEY_NAME).write_text("{}")

    monkeypatch.setattr(chain, "btcli_local", record)

    bootstrap._ensure_alice_wallet()

    assert commands[0][:2] == ["wallet", "regen-coldkey"]
    assert "--overwrite" not in commands[0]
    assert commands[1][:2] == ["wallet", "new-hotkey"]


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
