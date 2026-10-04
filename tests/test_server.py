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
    hub = Hub(port=free_port(), on_message=got.append)
    hub.start()
    try:
        hub.send(type="hello", project="acme")
        with connect(f"ws://127.0.0.1:{hub.port}") as ws:
            assert json.loads(ws.recv(timeout=2))["type"] == "hello"   # late verbinding krijgt de backlog
            hub.send(type="hint", id=3, state="final", text="Rente 3%.", sources=[])
            assert json.loads(ws.recv(timeout=2))["text"] == "Rente 3%."
            ws.send(json.dumps({"type": "feedback", "id": 3, "rating": 1}))
            for _ in range(20):
                if got:
                    break
                time.sleep(0.05)
        assert got == [{"type": "feedback", "id": 3, "rating": 1}]
    finally:
        hub.stop()


def test_hub_send_without_clients_is_fine():
    hub = Hub(port=free_port())
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
    assert "## Samenvatting" in text and "**Maria:** Wat is de rente?" in text and "- Rente 3%." in text
