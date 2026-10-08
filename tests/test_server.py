import json
import socket
import time

import pytest

from hint_meet.server import FeedbackLog, Hub, source_paths
from hint_meet.summary import write_note
from hint_meet.transcript import Utterance


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def test_hub_backlog_and_messages_roundtrip():
    from websockets.sync.client import connect
    got = []
    hub = Hub(port=free_port(), on_message=got.append, token="t" * 40)
    hub.start()
    try:
        hub.send(type="hello", project="acme")
        with connect(f"ws://127.0.0.1:{hub.port}/?token={'t' * 40}") as ws:
            assert json.loads(ws.recv(timeout=2))["type"] == "hello"   # late verbinding krijgt de backlog
            hub.send(type="hint", id=3, state="final", text="Rente 3%.", sources=[])
            assert json.loads(ws.recv(timeout=2))["text"] == "Rente 3%."
            ws.send(json.dumps({"type": "feedback", "id": 3, "rating": 1}))
            for _ in range(20):
                if got:
                    break
                time.sleep(0.05)
        assert got == [{"type": "feedback", "id": 3, "rating": 1}]
        assert all(m.get("type") != "x" for m in got)
    finally:
        hub.stop()


def test_hub_rejects_wrong_token_and_browsers():
    from websockets.exceptions import ConnectionClosed, InvalidStatus
    from websockets.sync.client import connect
    hub = Hub(port=free_port(), token="t" * 40)
    hub.start()
    try:
        hub.send(type="hello", project="geheim")
        for url, headers in [(f"ws://127.0.0.1:{hub.port}/?token=fout", None),
                             (f"ws://127.0.0.1:{hub.port}/?token={'t' * 40}", {"Origin": "https://evil.example"})]:
            with pytest.raises((ConnectionClosed, InvalidStatus)):
                with connect(url, additional_headers=headers) as ws:
                    ws.recv(timeout=2)
    finally:
        hub.stop()


def test_hello_resets_backlog_and_carries_session():
    hub = Hub(port=free_port(), token="t" * 40)
    hub.send(type="hint", id=1, text="oud")
    hub.send(type="hello", project="acme")
    hub.send(type="hint", id=1, text="nieuw")
    assert json.loads(hub.hello)["session"] == hub.session
    assert [json.loads(b)["text"] for b in hub.backlog] == ["nieuw"]


def test_token_file_is_private(tmp_path):
    import os
    import stat
    from hint_meet.server import load_or_create_token
    path = tmp_path / "sub" / "token"
    token = load_or_create_token(path)
    assert len(token) >= 32 and load_or_create_token(path) == token
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600


def test_feedback_ignores_garbage(tmp_path):
    log = FeedbackLog(tmp_path / "f.jsonl")
    log.record("x", "y")
    log.record(None, 1)
    assert not (tmp_path / "f.jsonl").exists()


def test_meeting_note_never_overwrites(tmp_path):
    u = [Utterance(5, "Maria", "Hoi")]
    t = time.time()
    a = write_note(tmp_path, u, [], "## Samenvatting\nA", t)
    b = write_note(tmp_path, u, [], "## Samenvatting\nB", t)
    assert a != b and "A" in a.read_text() and "B" in b.read_text()


def test_hub_send_without_clients_is_fine():
    hub = Hub(port=free_port(), token="t" * 40)
    hub.send(type="utterance", id=0, text="x")  # niet gestart, geen overlay: geen fout
    assert len(hub.backlog) == 1


def test_source_paths_from_manifest(tmp_path):
    (tmp_path / "_manifest.json").write_text(json.dumps({"files": {
        "dossier/memo.md.kb-hint-meet.md": {"source": "/Users/x/dossier/memo.md"}}}), encoding="utf-8")
    assert source_paths(tmp_path) == {"dossier/memo.md": "/Users/x/dossier/memo.md"}
    assert source_paths(tmp_path / "leeg") == {}


def test_feedback_log_appends_with_context(tmp_path):
    log = FeedbackLog(tmp_path / "f.jsonl")
    log.remember(4, hint="Rente 3%.", sources=["r.md"])
    log.record(4, -1)
    log.record(4, 5)   # ongeldig: genegeerd
    rows = [json.loads(l) for l in (tmp_path / "f.jsonl").read_text().splitlines()]
    assert len(rows) == 1 and rows[0]["rating"] == -1 and rows[0]["hint"] == "Rente 3%."


def test_meeting_note_lands_in_kb_meetings(tmp_path):
    u = [Utterance(5, "Maria", "Wat is de rente?"), Utterance(9, "Stefan", "Drie procent.")]
    path = write_note(tmp_path, u, ["Rente 3%."], "## Samenvatting\nOver de rente.", time.time())
    text = path.read_text(encoding="utf-8")
    assert path.parent.name == "meetings" and path.suffix == ".md"
    assert "## Samenvatting" in text and "**Maria:** Wat is de rente?" in text and "1. Rente 3%." in text


def test_meeting_note_name_has_project_and_partner(tmp_path):
    u = [Utterance(5, "Maria", "Hoi")]
    t = time.mktime((2026, 10, 5, 10, 47, 36, 0, 0, -1))
    path = write_note(tmp_path, u, [], "## Samenvatting\nA", t, project="Finance", info="Jan / Piet: VvE, Utrecht")
    assert path.name == "2026-10-05-104736-Finance-Jan - Piet- VvE, Utrecht.md"
    assert path.read_text(encoding="utf-8").startswith("# Gesprek · Jan - Piet- VvE, Utrecht · Finance · 05-10-2026 10:47")
    plain = write_note(tmp_path, u, [], "## Samenvatting\nB", t, project="Finance")
    assert plain.name == "2026-10-05-104736-Finance-gesprek.md"


def test_meeting_note_follows_conversation_language(tmp_path):
    u = [Utterance(5, "Maria", "Hello")]
    en = write_note(tmp_path, u, [], "## Summary\nAbout the loan.", time.time(), project="acme", language="en")
    text = en.read_text(encoding="utf-8")
    assert text.startswith("# Meeting · acme") and "## Hints shown" in text and "## Transcript" in text
    multi = write_note(tmp_path, u, [], "## Zusammenfassung\nÜber das Darlehen.", time.time(), language="multi")
    assert "## Angezeigte Hinweise" in multi.read_text(encoding="utf-8")
    nl = write_note(tmp_path, u, [], "## Samenvatting\nOver de lening.", time.time(), language="multi")
    assert "## Getoonde hints" in nl.read_text(encoding="utf-8")


def test_bullet_hints_render_as_numbered_points(tmp_path):
    u = [Utterance(5, "Anna", "VAT?")]
    path = write_note(tmp_path, u, ["- No VAT: going concern.\n- Payment on 1 July 2026.", "Single line hint."],
                      "## Summary\nX", time.time(), language="en")
    text = path.read_text(encoding="utf-8")
    assert "1. No VAT: going concern.\n   - Payment on 1 July 2026.\n2. Single line hint." in text
    assert "- - " not in text


def test_nested_points_line_up_after_double_digit_numbers():
    from hint_meet.summary import hint_lines
    assert hint_lines(10, "- a\n- b") == ["10. a", "    - b"]


def test_other_language_gets_english_report_scaffolding(tmp_path):
    u = [Utterance(5, "Ana", "Hola")]
    es = write_note(tmp_path, u, [], "## Resumen\nSobre el préstamo.", time.time(), language="es")
    assert "## Hints shown" in es.read_text(encoding="utf-8")


def test_search_results_are_not_replayed_to_new_clients():
    hub = Hub(port=free_port(), token="t" * 40)
    hub.send(type="hint", id=1, text="x")
    hub.send(type="search_results", id=7, results=[])
    assert len(hub.backlog) == 1   # alleen de hint


def test_document_results_give_ref_snippet_and_path(tmp_path):
    import zlib
    import numpy as np
    from hint_meet.cli import document_results
    from hint_meet.kb import KB

    class Fake:
        name = "fake"
        def _v(self, t):
            v = np.zeros(64, dtype=np.float32)
            for w in t.lower().split():
                v[zlib.crc32(w.encode()) % 64] += 1
            return v / (np.linalg.norm(v) or 1)
        def passages(self, texts):
            return np.stack([self._v(t) for t in texts])
        def query(self, t):
            return self._v(t)

    (tmp_path / "loan.md").write_text("# Loan\nThe loan of 250,000 was cancelled.", encoding="utf-8")
    (tmp_path / "vat.md").write_text("# VAT\nNo VAT: transfer of a going concern.", encoding="utf-8")
    kb = KB(tmp_path, Fake())
    res, reranked = document_results(kb, [tmp_path], {"vat.md": "/bron/vat.eml"}, "VAT going concern")
    assert not reranked
    assert res[0]["ref"] == "vat.md" and res[0]["path"] == "/bron/vat.eml" and "going concern" in res[0]["snippet"]
    assert res[1]["path"] == str(tmp_path / "loan.md")
