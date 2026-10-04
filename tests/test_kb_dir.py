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
