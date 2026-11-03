import os

from hint_meet import envfile


def test_plain_env_file_is_loaded_and_existing_vars_win(tmp_path, monkeypatch):
    (tmp_path / ".env").write_text("HM_TEST_A=from_file\nHM_TEST_B=from_file\n")
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("HM_TEST_B", "from_keychain")
    monkeypatch.delenv("HM_TEST_A", raising=False)
    envfile.load()
    assert os.environ["HM_TEST_A"] == "from_file" and os.environ["HM_TEST_B"] == "from_keychain"
    monkeypatch.delenv("HM_TEST_A")


def test_pipe_env_is_skipped_without_hanging(tmp_path, monkeypatch):
    os.mkfifo(tmp_path / ".env")
    monkeypatch.chdir(tmp_path)
    envfile.load()   # zou anders eeuwig wachten op een schrijver
