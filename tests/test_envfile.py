import os
import subprocess
import sys

from hint_meet import envfile


def test_plain_env_file_is_loaded_and_existing_vars_win(tmp_path, monkeypatch):
    (tmp_path / ".env").write_text("HM_TEST_A=from_file\nHM_TEST_B=from_file\n")
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("HM_TEST_B", "from_keychain")
    monkeypatch.delenv("HM_TEST_A", raising=False)
    envfile.load()
    assert os.environ["HM_TEST_A"] == "from_file" and os.environ["HM_TEST_B"] == "from_keychain"
    monkeypatch.delenv("HM_TEST_A")


def test_pipe_env_is_skipped_without_hanging(tmp_path):
    # in een subproces met tijdslimiet: komt de fout terug, dan faalt de test in plaats van dat de suite hangt
    os.mkfifo(tmp_path / ".env")
    src = os.path.join(os.path.dirname(envfile.__file__), "..")
    r = subprocess.run([sys.executable, "-c", "from hint_meet import envfile; envfile.load()"], cwd=tmp_path,
                       env={**os.environ, "PYTHONPATH": src}, capture_output=True, text=True, timeout=10)
    assert r.returncode == 0, r.stderr
    assert "geen gewoon bestand" in r.stderr, r.stderr
