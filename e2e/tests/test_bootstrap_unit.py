"""Chainless tests for the wallet the suite generates: it never touches a key it did not make."""
import os

import pytest

from alpha_e2e import bootstrap, chain, config


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
