"""Telefoonaudio: frames van de telefoon → gededupliceerde, gaten-gevulde `live.Block`s.

Een frame is een kop van 16 bytes (meeting u64, seq u32, offset u32, little-endian) plus 16-bit PCM
op 16 kHz. `offset` is de positie van het eerste sample in de stroom (in samples). De tijd van een blok
volgt uit die offset en niet uit het moment van binnenkomen, zodat opnieuw verstuurde frames op de
juiste plek in het gesprek landen. Hier zit geen socket in; dat doet een latere laag."""
from __future__ import annotations

import struct
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
