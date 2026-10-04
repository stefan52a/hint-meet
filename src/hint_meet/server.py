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
import os
import queue
import secrets
import sys
import threading
import time
from pathlib import Path

PROTOCOL_VERSION = 1
# Gedeelde sleutel tussen backend en HintMeet.app: loopback alleen is geen beveiliging, want elke
# app op deze Mac kan anders meeluisteren of de opname stoppen.
TOKEN_FILE = Path("~/Library/Application Support/hint-meet/ws-token").expanduser()


def load_or_create_token(path: Path = TOKEN_FILE) -> str:
    if path.exists():
        token = path.read_text(encoding="utf-8").strip()
        if len(token) >= 32:
            return token
    path.parent.mkdir(parents=True, exist_ok=True)
    token = secrets.token_urlsafe(32)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(token)
    return token


class Hub:
    """Verstuurt via een eigen thread, zodat een trage overlay de pijplijn niet ophoudt. Een overlay die
    later verbindt krijgt eerst het hello-bericht en de achterstand, en pas daarna nieuwe berichten."""

    def __init__(self, host: str = "127.0.0.1", port: int = 8765, on_message=None, token: str | None = None):
        self.host, self.port, self.on_message = host, port, on_message
        self.token = token or load_or_create_token()
        self.session = secrets.token_hex(4)   # nieuwe sessie = nieuwe id's in de overlay
        self.clients: set = set()
        self.lock = threading.Lock()
        self.server = None
        self.hello: str | None = None
        self.backlog: list[str] = []
        self.outbox: queue.Queue[str | None] = queue.Queue()

    def start(self):
        from websockets.sync.server import serve

        def authorized(ws) -> bool:
            req = ws.request
            if req.headers.get("Origin"):        # browsers sturen altijd Origin; HintMeet.app niet
                return False
            query = req.path.partition("?")[2]
            params = dict(p.partition("=")[::2] for p in query.split("&") if p)
            return secrets.compare_digest(params.get("token", ""), self.token)

        def handler(ws):
            if not authorized(ws):
                print("Overlay geweigerd (verkeerde sleutel of browser)", file=sys.stderr)
                ws.close(code=1008, reason="geen toegang")
                return
            print("Overlay verbonden", file=sys.stderr)
            with self.lock:  # achterstand versturen vóór de client nieuwe berichten kan krijgen
                for data in ([self.hello] if self.hello else []) + self.backlog:
                    ws.send(data)
                self.clients.add(ws)
            try:
                for raw in ws:
                    try:
                        msg = json.loads(raw)
                    except ValueError:
                        continue
                    if isinstance(msg, dict) and self.on_message:
                        try:
                            self.on_message(msg)
                        except (ValueError, TypeError):
                            continue   # onzin van een client mag de verbinding niet breken
            finally:
                with self.lock:
                    self.clients.discard(ws)

        self.server = serve(handler, self.host, self.port)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        threading.Thread(target=self._sender, daemon=True).start()

    def _sender(self):
        while True:
            data = self.outbox.get()
            if data is None:
                return
            with self.lock:
                for ws in list(self.clients):
                    try:
                        ws.send(data)
                    except Exception:  # noqa: BLE001 - een weggevallen overlay mag de pijplijn niet stoppen
                        self.clients.discard(ws)

    def send(self, **msg):
        msg.setdefault("session", self.session)
        data = json.dumps(msg, ensure_ascii=False)
        with self.lock:
            if msg.get("type") == "hello":
                self.hello, self.backlog = data, []
            else:
                self.backlog = (self.backlog + [data])[-200:]
        self.outbox.put(data)

    def stop(self):
        self.outbox.put(None)
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

    def record(self, hint_id, rating):
        try:
            hint_id, rating = int(hint_id), int(rating)
        except (TypeError, ValueError):
            return
        if rating not in (1, -1):
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        row = {"time": time.strftime("%Y-%m-%dT%H:%M:%S"), "id": hint_id, "rating": rating,
               **self.hints.get(hint_id, {})}
        with self.path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
