import os
import threading
import time

from hint_meet import apierrors, envfile


def test_plain_env_file_is_loaded_and_existing_vars_win(tmp_path, monkeypatch):
    (tmp_path / ".env").write_text("HM_TEST_A=from_file\nHM_TEST_B=from_file\n")
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("HM_TEST_B", "from_keychain")
    monkeypatch.delenv("HM_TEST_A", raising=False)
    assert envfile.load() is None
    assert os.environ["HM_TEST_A"] == "from_file" and os.environ["HM_TEST_B"] == "from_keychain"
    monkeypatch.delenv("HM_TEST_A")


def test_1password_pipe_is_read_when_it_delivers(tmp_path, monkeypatch):
    pipe = tmp_path / ".env"
    os.mkfifo(pipe)
    monkeypatch.chdir(tmp_path)
    monkeypatch.delenv("HM_TEST_C", raising=False)

    def onepassword():   # schrijft zodra er een lezer is, zoals 1Password
        with open(pipe, "w") as f:
            f.write("HM_TEST_C=secret\n")
    threading.Thread(target=onepassword, daemon=True).start()
    assert envfile.load(timeout_s=5) is None
    assert os.environ["HM_TEST_C"] == "secret"
    monkeypatch.delenv("HM_TEST_C")


def test_silent_1password_pipe_does_not_hang_and_explains_missing_key(tmp_path, monkeypatch):
    os.mkfifo(tmp_path / ".env")
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(envfile, "problem", None)
    t0 = time.monotonic()
    assert envfile.load(timeout_s=0.3) == envfile.PROBLEM
    assert time.monotonic() - t0 < 2
    try:
        assert "1Password" in apierrors.key_problem(TypeError("Could not resolve authentication method"))
    finally:
        envfile.problem = None
        # de hangende lezer losmaken, zodat er geen draad blijft wachten
        fd = os.open(tmp_path / ".env", os.O_WRONLY | os.O_NONBLOCK)
        os.close(fd)


def test_empty_1password_pipe_says_so(tmp_path, monkeypatch):
    pipe = tmp_path / ".env"
    os.mkfifo(pipe)
    monkeypatch.chdir(tmp_path)

    def onepassword():
        with open(pipe, "w"):
            pass
    threading.Thread(target=onepassword, daemon=True).start()
    try:
        assert envfile.load(timeout_s=5) == envfile.EMPTY
    finally:
        envfile.problem = None
