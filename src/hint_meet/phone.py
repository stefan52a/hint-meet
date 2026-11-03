"""Telefoonaudio: frames van de telefoon → gededupliceerde, gaten-gevulde `live.Block`s.

Een frame is een kop van 16 bytes (meeting u64, seq u32, offset u32, little-endian) plus 16-bit PCM
op 16 kHz. `offset` is de positie van het eerste sample in de stroom (in samples). De tijd van een blok
volgt uit die offset en niet uit het moment van binnenkomen, zodat opnieuw verstuurde frames op de
juiste plek in het gesprek landen. Hier zit geen socket in; dat doet een latere laag."""
from __future__ import annotations

import json
import queue
import secrets
import struct
import sys
import threading
import time

import numpy as np

from .live import Block

RATE_HZ = 16000
HEADER = struct.Struct("<QII")
MAX_FRAME = 16000      # samples per frame (1 s)
MAX_AHEAD_S = 600      # verder vooruit dan dit t.o.v. de eigen klok van de stroom is onzin
WATCHDOG_S = 1800      # zo lang zonder frames → stroom beschouwd als dood


class FrameError(ValueError):
    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def encode_frame(meeting: int, seq: int, offset: int, pcm16: np.ndarray) -> bytes:
    return HEADER.pack(meeting, seq, offset) + np.asarray(pcm16, dtype="<i2").tobytes()


class PhoneStream:
    def __init__(self, meeting: int, channel: str = "Unknown", clock=time.monotonic, wall=time.time):
        self.meeting, self.channel, self._clock = meeting, channel, clock
        self.mono_base = clock()
        self.started_at_ms = int(wall() * 1000)
        self.acked = 0                      # cumulatieve sample-offset die binnen is
        self.lost_s = 0.0                   # totaal ingevoegde stilte
        self.last_frame_at: float | None = None

    def _block(self, samples: np.ndarray, offset: int) -> Block:
        return Block(self.channel, samples, self.mono_base + offset / RATE_HZ)

    def accept(self, data: bytes) -> list[Block]:
        # eerst alles valideren; pas daarna de toestand aanpassen
        if len(data) < HEADER.size:
            raise FrameError("header too short")
        meeting, _seq, offset = HEADER.unpack_from(data)
        if meeting != self.meeting:
            raise FrameError("wrong meeting")
        body = data[HEADER.size:]
        if len(body) % 2:
            raise FrameError("odd payload length")
        n = len(body) // 2
        if n == 0:
            raise FrameError("empty frame")
        if n > MAX_FRAME:
            raise FrameError("frame too long")
        if offset / RATE_HZ > (self._clock() - self.mono_base) + MAX_AHEAD_S:
            raise FrameError("offset too far ahead")

        self.last_frame_at = self._clock()
        pcm = np.frombuffer(body, dtype="<i2")
        blocks: list[Block] = []
        if offset > self.acked:                       # gat: stilte invullen
            gap = offset - self.acked
            blocks.append(self._block(np.zeros(gap, dtype=np.float32), self.acked))
            self.lost_s += gap / RATE_HZ
            self.acked = offset
        skip = self.acked - offset                    # al binnen: wegknippen
        if skip < n:
            samples = (pcm[skip:] / 32768.0).astype(np.float32)
            blocks.append(self._block(samples, self.acked))
            self.acked += len(samples)
        return blocks

    def timed_out(self, now: float | None = None) -> bool:
        now = self._clock() if now is None else now
        since = self.last_frame_at if self.last_frame_at is not None else self.mono_base
        return now - since > WATCHDOG_S


class PhoneSource:
    """Zelfde vorm als `live.DeviceSource`, maar de audio komt via een websocket op localhost binnen
    (de gateway in HintMeet.app zet de verbinding van de telefoon daarheen door). Eén producent tegelijk: een nieuwe
    verbinding sluit de vorige. PhoneStream is niet thread-safe, dus alle toegang gaat onder `lock`."""

    def __init__(self, meeting: int, port: int, token: str, label: str = "Unknown"):
        self.meeting, self.port, self.token, self.label = meeting, port, token, label
        self.overflows = 0
        self.stream = PhoneStream(meeting, label)
        self.lock = threading.Lock()          # beschermt stream en _ws
        self._send_lock = threading.Lock()    # websocket-sends van handler- en ack-thread niet door elkaar
        self._ws = None
        self._q: queue.Queue | None = None
        self._server = None
        self._stopped = threading.Event()

    @property
    def meeting_hex(self) -> str:
        return f"{self.meeting:016x}"

    @property
    def finished(self) -> bool:
        with self.lock:
            return self.stream.timed_out()

    def _authorized(self, ws) -> bool:
        req = ws.request
        if req.headers.get("Origin"):        # browsers sturen altijd Origin; de telefoon niet
            return False
        query = req.path.partition("?")[2]
        params = dict(p.partition("=")[::2] for p in query.split("&") if p)
        return secrets.compare_digest(params.get("token", ""), self.token)

    def _send(self, ws, **msg) -> bool:
        msg["meeting"] = self.meeting_hex
        try:
            with self._send_lock:
                ws.send(json.dumps(msg))
            return True
        except Exception:  # noqa: BLE001 - een weggevallen telefoon mag de pijplijn niet stoppen
            return False

    def _send_ack(self):
        with self.lock:
            ws, offset = self._ws, self.stream.acked
        if ws is not None:
            self._send(ws, type="audio_ack", offset=offset)

    def _handler(self, ws):
        if not self._authorized(ws):
            print("Telefoon geweigerd (verkeerde sleutel of browser)", file=sys.stderr)
            ws.close(code=1008, reason="geen toegang")
            return
        if not self._stopped.is_set():
            self._send(ws, type="audio_ready")   # eerst ready, pas daarna ziet de ack-draad deze verbinding
        with self.lock:
            stopped = self._stopped.is_set()     # stop() liep al: niet meer aannemen
            if not stopped:
                old, self._ws = self._ws, ws
        if stopped:                              # sluiten buiten het slot: close() wacht op de handshake
            ws.close(code=1001, reason="meeting gestopt")
            return
        if old is not None:
            try:
                old.close(code=1000, reason="vervangen door een nieuwe verbinding")
            except Exception:  # noqa: BLE001
                pass
        print("Telefoon verbonden", file=sys.stderr)
        try:
            for raw in ws:
                if not isinstance(raw, bytes):
                    continue
                with self.lock:
                    if self._ws is not ws:
                        break
                    try:
                        blocks = self.stream.accept(raw)
                    except FrameError as e:
                        blocks, reason = [], e.reason
                    else:
                        reason = None
                    for b in blocks:
                        self._q.put(b)
                if reason is not None:
                    self._send(ws, type="audio_reject", reason=reason)
        except Exception:  # noqa: BLE001 - verbinding weggevallen
            pass
        finally:
            with self.lock:
                if self._ws is ws:
                    self._ws = None
            print("Telefoon verbinding gesloten", file=sys.stderr)

    def _acker(self):
        while not self._stopped.wait(1.0):
            self._send_ack()

    def start(self, q: queue.Queue):
        from websockets.sync.server import serve
        self._q = q
        self._server = serve(self._handler, "127.0.0.1", self.port)
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        threading.Thread(target=self._acker, daemon=True).start()

    def wait_acked(self, offset: int, timeout: float) -> bool:
        self._send_ack()
        end = time.monotonic() + timeout
        while True:
            with self.lock:
                done = self.stream.acked >= offset
            if done:
                self._send_ack()
                return True
            if time.monotonic() >= end:
                return False
            time.sleep(0.01)

    def stop(self):
        with self.lock:
            self._stopped.set()
            ws, self._ws = self._ws, None
        if ws is not None:
            try:
                ws.close()
            except Exception:  # noqa: BLE001
                pass
        if self._server is not None:
            self._server.shutdown()
