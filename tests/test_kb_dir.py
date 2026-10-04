import os
from pathlib import Path

import pytest

from hint_meet.kb import kb_dir


def test_project_from_env_and_tilde_expanded(monkeypatch):
    monkeypatch.setenv("KB_ROOT", "~/KB_md")
    monkeypatch.setenv("KB_PROJECT", "fabrikam")
    assert kb_dir() == Path.home() / "KB_md" / "fabrikam"


def test_argument_overrides_env(monkeypatch, tmp_path):
    monkeypatch.setenv("KB_ROOT", str(tmp_path))
    monkeypatch.setenv("KB_PROJECT", "fabrikam")
    assert kb_dir("acme") == tmp_path / "acme"


def test_default_root(monkeypatch):
    monkeypatch.delenv("KB_ROOT", raising=False)
    assert kb_dir("x") == Path.home() / "KB_md" / "x"


def test_missing_project(monkeypatch):
    monkeypatch.delenv("KB_PROJECT", raising=False)
    with pytest.raises(ValueError, match="Geen project"):
        kb_dir()


@pytest.mark.parametrize("name", ["../weg", "a/b", ".verborgen"])
def test_invalid_project(name):
    with pytest.raises(ValueError, match="Ongeldige"):
        kb_dir(name)


def test_empty_argument_does_not_fall_back_to_env(monkeypatch):
    monkeypatch.setenv("KB_PROJECT", "fabrikam")
    with pytest.raises(ValueError):
        kb_dir("")


@pytest.fixture
def clean_env(monkeypatch):
    """Eigen kopie van os.environ: load_dotenv schrijft erin en mag niet naar andere tests lekken."""
    env = {k: v for k, v in os.environ.items() if k not in ("KB_ROOT", "KB_PROJECT")}
    monkeypatch.setattr(os, "environ", env)


def test_cli_reads_project_from_dotenv(clean_env, monkeypatch, tmp_path, capsys):
    from hint_meet.cli import main
    monkeypatch.chdir(tmp_path)
    (tmp_path / ".env").write_text(f"KB_ROOT={tmp_path}\nKB_PROJECT=acme\n", encoding="utf-8")
    main(["live"])
    assert f"KB: {tmp_path / 'acme'}" in capsys.readouterr().out


def test_cli_project_flag_beats_dotenv(clean_env, monkeypatch, tmp_path, capsys):
    from hint_meet.cli import main
    monkeypatch.chdir(tmp_path)
    (tmp_path / ".env").write_text(f"KB_ROOT={tmp_path}\nKB_PROJECT=acme\n", encoding="utf-8")
    main(["--project", "fabrikam", "live"])
    assert f"KB: {tmp_path / 'fabrikam'}" in capsys.readouterr().out
