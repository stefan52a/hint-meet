import pytest


@pytest.fixture(autouse=True)
def _usage_ledger(tmp_path, monkeypatch):
    """Tests tellen kosten (ook met nep-antwoorden) in een eigen bestand, nooit in het echte van de app."""
    monkeypatch.setenv("HINT_MEET_USAGE", str(tmp_path / "usage.json"))
