"""Lokale WebSocket-server tussen de pijplijn en de overlay (127.0.0.1, alleen deze Mac).

Server → overlay, één JSON-bericht per gebeurtenis:
  {"type": "hello", "project": ..}
  {"type": "utterance", "id": n, "time": "mm:ss", "speaker": .., "text": ..}
  {"type": "hint", "id": n, "state": "streaming", "text": ..}
  {"type": "hint", "id": n, "state": "final", "text": .., "sources": [{"ref": .., "path": ..}]}
  {"type": "hint", "id": n, "state": "retracted", "text": .., "reason": ..}
  {"type": "summary", "markdown": .., "path": ..}
  {"type": "stopped"}
Overlay → server:
  {"type": "feedback", "id": n, "rating": 1 | -1}
  {"type": "stop"}
"""
from __future__ import annotations

import json
import threading
import time
from pathlib import Path

PROTOCOL_VERSION = 1


class Hub:
    def __init__(self, host: str = "127.0.0.1", port: int = 8765, on_message=None):
        self.host, self.port, self.on_message = host, port, on_message
        self.clients: set = set()
        self.lock = threading.Lock()
        self.server = None
        self.backlog: list[str] = []   # zodat een overlay die later verbindt de stand van zaken krijgt

    def start(self):
        from websockets.sync.server import serve

        def handler(ws):
            with self.lock:
                self.clients.add(ws)
                backlog = list(self.backlog)
            try:
                for msg in backlog:
                    ws.send(msg)
                for raw in ws:
                    try:
                        msg = json.loads(raw)
                    except ValueError:
                        continue
                    if self.on_message:
                        self.on_message(msg)
            finally:
                with self.lock:
                    self.clients.discard(ws)

        self.server = serve(handler, self.host, self.port)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def send(self, **msg):
        data = json.dumps(msg, ensure_ascii=False)
        with self.lock:
            self.backlog.append(data)
            self.backlog = self.backlog[-200:]
            clients = list(self.clients)
        for ws in clients:
            try:
                ws.send(data)
            except Exception:  # noqa: BLE001 - een weggevallen overlay mag de pijplijn niet stoppen
                pass

    def stop(self):
        if self.server:
            self.server.shutdown()


def source_paths(kb_root: Path) -> dict[str, str]:
    """KB-referentie → oorspronkelijk bronbestand (via het kb_prep-manifest), om te openen."""
    manifest = kb_root / "_manifest.json"
    out: dict[str, str] = {}
    if manifest.exists():
        files = json.loads(manifest.read_text(encoding="utf-8")).get("files", {})
        for key, entry in files.items():
            out[key[:-len(".kb-hint-meet.md")] if key.endswith(".kb-hint-meet.md") else key] = entry.get("source", "")
    return out


class FeedbackLog:
    """👍/👎 van de overlay, met de hint en de context erbij, voor latere kalibratie."""

    def __init__(self, path: Path):
        self.path = path
        self.hints: dict[int, dict] = {}

    def remember(self, hint_id: int, **info):
        self.hints[hint_id] = info

    def record(self, hint_id: int, rating: int):
        if rating not in (1, -1):
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        row = {"time": time.strftime("%Y-%m-%dT%H:%M:%S"), "id": hint_id, "rating": rating,
               **self.hints.get(hint_id, {})}
        with self.path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
