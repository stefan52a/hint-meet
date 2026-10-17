from types import SimpleNamespace as NS

import pytest

from hint_meet.summary import load_meta, meta_path, save_meta, write_report

CONFIG = {"advise": {"model": "claude-x"}}
TRANSCRIPT = """# Live-transcript hint-meet, 2026-10-17 21:57
[00:00] Anna: Goedemorgen Stefan.
[00:04] Stefan: Ik heb het dossier bij me.
[00:08] Anna: De koopsom is 650.000 euro?
"""


class FakeClaude:
    def __init__(self):
        self.calls = []
        self.messages = self

    def create(self, **kw):
        self.calls.append(kw)
        return NS(content=[NS(type="text", text="## Samenvatting\nKoopsom besproken.")])


def test_report_from_a_crashed_meeting_uses_its_meta(tmp_path):
    transcript = tmp_path / "logs" / "live-20261017-215747.txt"
    transcript.parent.mkdir()
    transcript.write_text(TRANSCRIPT, encoding="utf-8")
    kb = tmp_path / "kb"
    save_meta(transcript, {"project": "acme", "info": "Anna", "language": "nl", "started": 1792000000.0,
                           "report_dir": str(kb), "summary": True, "hints": ["Koopsom is 600.000."], "report": None})
    claude = FakeClaude()
    note = write_report(transcript, CONFIG, client=claude)
    assert note.parent == kb / "meetings" and "acme" in note.name and "Anna" in note.name
    text = note.read_text(encoding="utf-8")
    assert "Koopsom besproken." in text and "Koopsom is 600.000." in text and "De koopsom is 650.000 euro?" in text
    assert load_meta(transcript)["report"] == str(note)   # de app biedt hem daarna niet meer aan
    assert not list(transcript.parent.glob("*.tmp"))


def test_report_without_meta_goes_to_logs_and_short_meetings_get_none(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    transcript = tmp_path / "live-1.txt"
    transcript.write_text(TRANSCRIPT, encoding="utf-8")
    note = write_report(transcript, CONFIG, client=FakeClaude())
    assert note.resolve().parent == (tmp_path / "logs" / "meetings").resolve() and not meta_path(transcript).exists()
    transcript.write_text(TRANSCRIPT.splitlines()[0] + "\n[00:00] Anna: Hoi.\n", encoding="utf-8")
    with pytest.raises(ValueError):
        write_report(transcript, CONFIG, client=FakeClaude())
