"""Live: audio van apparaten (of een WAV in echte tijd) → uitspraken → pijplijn, terwijl het gesprek loopt.

Opzet met drie draden:
- de audio-callbacks leggen blokken van 32 ms op een wachtrij (mag nooit blokkeren);
- de spraakdraad knipt per kanaal uitspraken (VAD) en transcribeert ze; elke uitspraak gaat meteen
  naar on_utterance (het transcript in de app loopt dus door terwijl Claude een hint schrijft);
- de pijplijndraad draait per uitspraak zoeken → gate → reranker → advies, op volgorde.
Wachttijden (vóór de spraakherkenning en vóór de pijplijn) worden gemeten en horen bij de echte vertraging.

Het gesprek wordt ook als transcript bewaard (zelfde formaat als de testtranscripten), zodat
het later opnieuw af te spelen is met `hint-meet replay`."""
from __future__ import annotations

import queue
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from .audio import FRAME, RATE, Segmenter, SileroVAD, channel_labels, read_wav
from .transcript import Utterance


@dataclass
class Block:
    channel: str
    samples: np.ndarray
    t: float          # wandklok-tijd waarop het blok binnenkwam


class DeviceSource:
    """Eén audioapparaat (microfoon of BlackHole) via sounddevice, op 16 kHz; stereo wordt gemengd."""

    def __init__(self, device: str | None, label: str):
        import sounddevice as sd
        self.sd, self.device, self.label = sd, device, label
        self.stream = None
        self.overflows = 0       # blokken die het apparaat liet vallen omdat wij te traag lazen

    def start(self, q: queue.Queue):
        info = self.sd.query_devices(self.device, "input")
        channels = max(1, min(2, int(info["max_input_channels"])))

        def callback(indata, frames, time_info, status):
            if status.input_overflow:
                self.overflows += 1
            q.put(Block(self.label, indata.mean(axis=1).astype(np.float32), time.monotonic()))

        self.stream = self.sd.InputStream(device=self.device, channels=channels, samplerate=RATE,
                                          blocksize=FRAME, dtype="float32", callback=callback)
        self.stream.start()

    def stop(self):
        if self.stream:
            self.stream.stop()
            self.stream.close()


class WavSource:
    """Een (meerkanaals) WAV, afgespeeld in echte tijd alsof het apparaten zijn: test voor live."""

    def __init__(self, path: Path, labels: list[str], speed: float = 1.0):
        self.data, self.speed = read_wav(path), speed
        try:
            self.labels = channel_labels(self.data.shape[1], labels)
        except ValueError as e:
            raise ValueError(f"{path}: {e}") from None
        if not (speed > 0 and np.isfinite(speed)):
            raise ValueError(f"afspeelsnelheid moet positief zijn, niet {speed}")
        self.thread = None
        self.done = threading.Event()
        self.overflows = 0

    def start(self, q: queue.Queue):
        def run():
            try:
                t0 = time.monotonic()
                for i in range(0, len(self.data) - FRAME + 1, FRAME):
                    if self.done.is_set():
                        return
                    delay = t0 + (i / RATE) / self.speed - time.monotonic()
                    if delay > 0:
                        time.sleep(delay)
                    now = time.monotonic()
                    for ch, label in enumerate(self.labels):
                        q.put(Block(label, self.data[i:i + FRAME, ch].copy(), now))
            finally:
                self.done.set()  # ook bij een fout: de sessie mag niet eeuwig blijven wachten

        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()

    def stop(self):
        self.done.set()
        if self.thread:
            self.thread.join(timeout=2)

    @property
    def finished(self) -> bool:
        return self.done.is_set()


@dataclass
class LiveEvent:
    utterance: Utterance
    step: object
    wait_ms: float       # tijd dat de klare uitspraak op de spraakherkenning wachtte
    asr_ms: float
    stale: bool = False  # te ver achter: wel getranscribeerd, geen advies meer
    index: int = 0       # plaats in het transcript (ook de id van een hint erop)
    pipe_wait_ms: float = 0.0   # tijd dat de getranscribeerde uitspraak op de pijplijn wachtte
    error: str | None = None    # pijplijn faalde (bv. timeout): geen hint, meeting loopt door


class LiveSession:
    STALE_MS = 8000      # loopt de verwerking verder achter dan dit, dan geen advies meer

    def __init__(self, sources, transcriber, pipeline, on_event=None, on_text=None, on_utterance=None,
                 min_silence_ms: int = 400):
        """on_utterance(index, utterance): meteen na de spraakherkenning. on_text(partial, index): hint in wording.
        on_event(LiveEvent): na de pijplijn. De laatste twee komen uit de pijplijndraad."""
        self.sources, self.transcriber, self.pipeline = sources, transcriber, pipeline
        self.on_event, self.on_text, self.on_utterance = on_event, on_text, on_utterance
        self.work: queue.Queue = queue.Queue()   # (index, klaar-tijd, wait_ms, asr_ms, advise) voor de pijplijn
        self.worker: threading.Thread | None = None
        self.min_silence_ms = min_silence_ms
        self.q: queue.Queue[Block] = queue.Queue()
        self.segmenters: dict[str, Segmenter] = {}
        self.utterances: list[Utterance] = []
        self.events: list[LiveEvent] = []
        self.t0 = None
        self.stop_flag = threading.Event()

    def _segmenter(self, label: str) -> Segmenter:
        if label not in self.segmenters:
            self.segmenters[label] = Segmenter(label, vad=SileroVAD(), min_silence_ms=self.min_silence_ms)
        return self.segmenters[label]

    def run(self, until=None) -> bool:
        """Draait tot until() waar is, stop() wordt aangeroepen of Ctrl-C. Geeft True bij Ctrl-C.
        De laatste lopende uitspraak wordt bij het stoppen nog verwerkt."""
        self.t0 = time.monotonic()
        pending: dict[str, np.ndarray] = {}
        interrupted = False
        self.worker = threading.Thread(target=self._pipeline_loop, daemon=True, name="hint-meet-pipeline")
        self.worker.start()
        try:
            try:
                for s in self.sources:  # binnen try: faalt het tweede apparaat, dan sluit het eerste
                    s.start(self.q)
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
            except KeyboardInterrupt:
                interrupted = True
            finally:
                for s in self.sources:
                    try:
                        s.stop()
                    except Exception:  # noqa: BLE001
                        pass
            for seg in self.segmenters.values():
                for segment in seg.flush():
                    self._handle(segment, ready_at=time.monotonic(), advise=False)
        finally:
            self.work.put(None)   # pijplijn maakt af wat er nog ligt (begrensd door de timeouts) en stopt
            self.worker.join()
            self.worker = None
        return interrupted

    def stop(self):
        self.stop_flag.set()

    @property
    def overflows(self) -> int:
        return sum(getattr(s, "overflows", 0) for s in self.sources)

    def _handle(self, segment, ready_at: float, advise: bool = True):
        """Spraakdraad: transcriberen, meteen melden, en doorgeven aan de pijplijn."""
        wait_ms = (time.monotonic() - ready_at) * 1000
        text, asr_ms = self.transcriber(segment.audio, segment.channel)
        if not text:
            return
        u = Utterance(int(segment.start), segment.channel, text)
        index = len(self.utterances)
        self.utterances.append(u)
        if self.on_utterance:
            self.on_utterance(index, u)
        item = (index, time.monotonic(), wait_ms, asr_ms, advise)
        if self.worker is None:   # buiten run() (tests): meteen afhandelen
            self._advise(*item)
        else:
            self.work.put(item)

    def _pipeline_loop(self):
        while (item := self.work.get()) is not None:
            self._advise(*item)

    def _advise(self, index: int, queued_at: float, wait_ms: float, asr_ms: float, advise: bool):
        """Pijplijndraad: zoeken → gate → reranker → advies voor één uitspraak."""
        pipe_wait_ms = (time.monotonic() - queued_at) * 1000
        stale = wait_ms + asr_ms + pipe_wait_ms > self.STALE_MS
        step, error = None, None
        if advise and not stale:
            on_text = (lambda partial: self.on_text(partial, index)) if self.on_text else None
            try:
                step = self.pipeline.step(self.utterances[:index + 1], index, on_text=on_text)
            except Exception as e:  # noqa: BLE001 - een trage of falende API mag de meeting niet stoppen
                error = f"{type(e).__name__}: {e}"
                print(f"Pijplijn faalde bij uitspraak {index}: {error}", file=sys.stderr)
        event = LiveEvent(self.utterances[index], step, wait_ms, asr_ms, stale, index, pipe_wait_ms, error)
        self.events.append(event)
        if self.on_event:
            self.on_event(event)

    def save_transcript(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        lines = [f"# Live-transcript hint-meet, {time.strftime('%Y-%m-%d %H:%M')}"]
        lines += [f"[{u.seconds // 60:02d}:{u.seconds % 60:02d}] {u.speaker}: {u.text}" for u in self.utterances]
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
