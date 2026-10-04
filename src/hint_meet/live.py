"""Live: audio van apparaten (of een WAV in echte tijd) → uitspraken → pijplijn, terwijl het gesprek loopt.

Opzet met twee draden:
- de audio-callbacks leggen blokken van 32 ms op een wachtrij (mag nooit blokkeren);
- één werker knipt per kanaal uitspraken (VAD), transcribeert en draait de pijplijn.
Loopt de werker achter (advies duurt langer dan de volgende uitspraak), dan wacht de volgende
uitspraak: die wachttijd wordt gemeten en hoort bij de echte vertraging.

Het gesprek wordt ook als transcript bewaard (zelfde formaat als de testtranscripten), zodat
het later opnieuw af te spelen is met `hint-meet replay`."""
from __future__ import annotations

import queue
import threading
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from .audio import FRAME, RATE, Segmenter, SileroVAD, read_wav
from .transcript import Utterance


@dataclass
class Block:
    channel: str
    samples: np.ndarray
    t: float          # wandklok-tijd waarop het blok binnenkwam


class DeviceSource:
    """Eén audioapparaat (microfoon of BlackHole) via sounddevice, kanaal 1, op 16 kHz."""

    def __init__(self, device: str, label: str):
        import sounddevice as sd
        self.sd, self.device, self.label = sd, device, label
        self.stream = None

    def start(self, q: queue.Queue):
        def callback(indata, frames, time_info, status):
            q.put(Block(self.label, indata[:, 0].copy(), time.monotonic()))

        self.stream = self.sd.InputStream(device=self.device, channels=1, samplerate=RATE,
                                          blocksize=FRAME, dtype="float32", callback=callback)
        self.stream.start()

    def stop(self):
        if self.stream:
            self.stream.stop()
            self.stream.close()


class WavSource:
    """Een (meerkanaals) WAV, afgespeeld in echte tijd alsof het apparaten zijn: test voor live."""

    def __init__(self, path: Path, labels: list[str], speed: float = 1.0):
        self.data, self.labels, self.speed = read_wav(path), labels, speed
        self.thread = None
        self.done = threading.Event()

    def start(self, q: queue.Queue):
        def run():
            t0 = time.monotonic()
            for i in range(0, len(self.data) - FRAME + 1, FRAME):
                target = t0 + (i / RATE) / self.speed
                delay = target - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                now = time.monotonic()
                for ch, label in enumerate(self.labels):
                    q.put(Block(label, self.data[i:i + FRAME, ch].copy(), now))
                if self.done.is_set():
                    return
            self.done.set()

        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()

    def stop(self):
        self.done.set()

    @property
    def finished(self) -> bool:
        return self.done.is_set()


@dataclass
class LiveEvent:
    utterance: Utterance
    step: object
    wait_ms: float       # tijd dat de klare uitspraak op de werker wachtte
    asr_ms: float


class LiveSession:
    def __init__(self, sources, transcriber, pipeline, on_event=None, on_text=None):
        self.sources, self.transcriber, self.pipeline = sources, transcriber, pipeline
        self.on_event, self.on_text = on_event, on_text
        self.q: queue.Queue[Block] = queue.Queue()
        self.segmenters: dict[str, Segmenter] = {}
        self.utterances: list[Utterance] = []
        self.events: list[LiveEvent] = []
        self.t0 = None
        self.stop_flag = threading.Event()

    def _segmenter(self, label: str) -> Segmenter:
        if label not in self.segmenters:
            self.segmenters[label] = Segmenter(label, vad=SileroVAD())
        return self.segmenters[label]

    def run(self, until=None):
        """Draait tot until() waar is, stop() wordt aangeroepen of Ctrl-C."""
        self.t0 = time.monotonic()
        for s in self.sources:
            s.start(self.q)
        pending: dict[str, np.ndarray] = {}
        try:
            while not self.stop_flag.is_set():
                try:
                    block = self.q.get(timeout=0.2)
                except queue.Empty:
                    if until and until() and self.q.empty():
                        break
                    continue
                buf = np.concatenate([pending.get(block.channel, np.zeros(0, np.float32)), block.samples])
                seg = self._segmenter(block.channel)
                while len(buf) >= FRAME:
                    for segment in seg.feed(buf[:FRAME]):
                        self._handle(segment, ready_at=block.t)
                    buf = buf[FRAME:]
                pending[block.channel] = buf
            for seg in self.segmenters.values():
                for segment in seg.flush():
                    self._handle(segment, ready_at=time.monotonic())
        finally:
            for s in self.sources:
                s.stop()

    def stop(self):
        self.stop_flag.set()

    def _handle(self, segment, ready_at: float):
        wait_ms = (time.monotonic() - ready_at) * 1000
        text, asr_ms = self.transcriber(segment.audio)
        if not text:
            return
        u = Utterance(int(segment.start), segment.channel, text)
        self.utterances.append(u)
        step = self.pipeline.step(self.utterances, len(self.utterances) - 1, on_text=self.on_text)
        event = LiveEvent(u, step, wait_ms, asr_ms)
        self.events.append(event)
        if self.on_event:
            self.on_event(event)

    def save_transcript(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        lines = [f"# Live-transcript hint-meet, {time.strftime('%Y-%m-%d %H:%M')}"]
        lines += [f"[{u.seconds // 60:02d}:{u.seconds % 60:02d}] {u.speaker}: {u.text}" for u in self.utterances]
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
