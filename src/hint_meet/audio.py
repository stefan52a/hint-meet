"""Audio → uitspraken: spraakdetectie (Silero VAD) per kanaal en transcriptie (Whisper via MLX).

Elk kanaal is een spreker of groep sprekers: in een online meeting is de microfoon Stefan en de
systeemaudio de anderen; aan tafel is er alleen de microfoon. Een uitspraak is klaar als er
min_silence_ms stilte volgt; dat moment (detected_at) is waar de vertraging van de hint begint."""
from __future__ import annotations

import re
import time
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

RATE = 16000
FRAME = 512                      # Silero v5 bij 16 kHz: 32 ms per blok
CONTEXT = 64                     # zoals de officiële wrapper: laatste 64 samples ervoor
VAD_MODEL = Path("~/.cache/hint-meet/models/silero_vad.onnx").expanduser()
VAD_URL = "https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx"
WHISPER_MODEL = "mlx-community/whisper-large-v3-turbo"

# Whisper verzint op stilte of ruis soms ondertitelaars; die zinnen gooien we weg.
HALLUCINATIONS = re.compile(r"ondertitel|amara\.org|bedankt voor het kijken|tv gelderland", re.I)


class SileroVAD:
    def __init__(self, path: Path = VAD_MODEL):
        import onnxruntime as ort
        if not path.exists():
            import urllib.request
            path.parent.mkdir(parents=True, exist_ok=True)
            urllib.request.urlretrieve(VAD_URL, path)
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = 1
        self.session = ort.InferenceSession(str(path), sess_options=opts, providers=["CPUExecutionProvider"])
        self.reset()

    def reset(self):
        self.state = np.zeros((2, 1, 128), dtype=np.float32)
        self.context = np.zeros((1, CONTEXT), dtype=np.float32)

    def __call__(self, frame: np.ndarray) -> float:
        x = np.concatenate([self.context, frame.reshape(1, -1).astype(np.float32)], axis=1)
        out, self.state = self.session.run(None, {"input": x, "state": self.state,
                                                  "sr": np.array(RATE, dtype=np.int64)})
        self.context = x[:, -CONTEXT:]
        return float(out[0][0])


@dataclass
class Segment:
    channel: str
    start: float          # seconden vanaf het begin van de opname
    end: float
    detected_at: float    # moment waarop de stilte na de uitspraak lang genoeg was
    audio: np.ndarray = field(repr=False)


class Segmenter:
    """Knipt één kanaal in uitspraken. feed() per blok van FRAME samples; geeft klare segmenten terug."""

    def __init__(self, channel: str, threshold=0.5, neg_threshold=0.35, min_silence_ms=500,
                 min_speech_ms=250, pad_ms=150, max_segment_s=20.0, vad=None):
        self.channel = channel
        self.vad = vad or SileroVAD()
        self.threshold, self.neg_threshold = threshold, neg_threshold
        self.min_silence = int(min_silence_ms * RATE / 1000)
        self.min_speech = int(min_speech_ms * RATE / 1000)
        self.pad = int(pad_ms * RATE / 1000)
        self.max_len = int(max_segment_s * RATE)
        self.pos = 0              # samples gezien
        self.buffer: list[np.ndarray] = []
        self.history = np.zeros(0, dtype=np.float32)  # voor de pad vóór het begin
        self.start = None
        self.silence = 0

    def feed(self, frame: np.ndarray) -> list[Segment]:
        p = self.vad(frame)
        out: list[Segment] = []
        if self.start is None:
            if p >= self.threshold:
                pre = self.history[-self.pad:] if self.pad else np.zeros(0, dtype=np.float32)
                self.start = self.pos - len(pre)
                self.buffer = [pre, frame]
                self.silence = 0
            else:
                self.history = np.concatenate([self.history, frame])[-max(self.pad, 1):]
        else:
            self.buffer.append(frame)
            self.silence = self.silence + len(frame) if p < self.neg_threshold else 0
            length = sum(len(b) for b in self.buffer)
            if self.silence >= self.min_silence or length >= self.max_len:
                out.extend(self._close(length))
        self.pos += len(frame)
        return out

    def flush(self) -> list[Segment]:
        if self.start is None:
            return []
        return self._close(sum(len(b) for b in self.buffer))

    def _close(self, length: int) -> list[Segment]:
        audio = np.concatenate(self.buffer)
        keep = len(audio) - max(self.silence - self.pad, 0)  # stilte aan het eind afknippen, pad laten
        audio = audio[:keep]
        seg = Segment(self.channel, self.start / RATE, (self.start + len(audio)) / RATE,
                      (self.pos + FRAME) / RATE, audio)
        self.start, self.buffer, self.silence = None, [], 0
        self.history = np.zeros(0, dtype=np.float32)
        speech = len(audio) - 2 * self.pad
        return [seg] if speech >= self.min_speech else []


def kb_terms(chunks, limit: int = 40) -> list[str]:
    """Woordenlijst voor Whisper uit de KB: namen en termen die vaak voorkomen (Globex, Initech, 37d)."""
    counts: Counter[str] = Counter()
    for c in chunks:
        for w in re.findall(r"\b[A-Z][a-zA-Z]{3,}\b|\b\d+[a-z]\b", c.text):
            counts[w] += 1
    stop = {"Deze", "Indien", "Partijen", "Artikel", "Bijlage", "Datum", "Totaal", "Status", "Bron",
            "Stefan", "Nota", "Voor", "Door", "Over", "Naar", "Niet", "Geen", "Wel", "Alle", "Ook"}
    return [w for w, n in counts.most_common() if n >= 3 and w not in stop][:limit]


class Transcriber:
    def __init__(self, terms: list[str] | None = None, model: str = WHISPER_MODEL, language: str = "nl"):
        import mlx_whisper
        self.mlx_whisper = mlx_whisper
        self.model, self.language = model, language
        self.prompt = ", ".join(terms) + "." if terms else None
        # eerste aanroep laadt het model: nu doen, niet midden in een gesprek
        self.mlx_whisper.transcribe(np.zeros(RATE, dtype=np.float32), path_or_hf_repo=model, language=language)

    def __call__(self, audio: np.ndarray) -> tuple[str, float]:
        t = time.perf_counter()
        r = self.mlx_whisper.transcribe(audio.astype(np.float32), path_or_hf_repo=self.model,
                                        language=self.language, initial_prompt=self.prompt,
                                        condition_on_previous_text=False)
        text = r["text"].strip()
        if HALLUCINATIONS.search(text) or not re.search(r"\w", text):
            text = ""
        return text, (time.perf_counter() - t) * 1000


def read_wav(path: Path) -> np.ndarray:
    """Een opname als float32 (samples, kanalen) bij 16 kHz. WAV van 16 kHz/16-bit direct; al het andere
    (mp3, m4a, wav met een andere samplerate) via ffmpeg, met hooguit twee kanalen."""
    import wave
    path = Path(path)
    if not path.exists():
        raise ValueError(f"{path}: bestand niet gevonden")
    if path.suffix.lower() == ".wav":
        with wave.open(str(path)) as w:
            if w.getframerate() == RATE and w.getsampwidth() == 2:
                data = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).reshape(-1, w.getnchannels())
                return data.astype(np.float32) / 32768.0
    return decode_audio(path)


def decode_audio(path: Path) -> np.ndarray:
    import shutil
    import subprocess
    if not shutil.which("ffmpeg"):
        raise ValueError(f"{path}: voor dit formaat is ffmpeg nodig (brew install ffmpeg)")
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=channels",
                            "-of", "csv=p=0", str(path)], capture_output=True, text=True)
    try:
        channels = min(2, max(1, int(probe.stdout.strip().split(",")[0])))
    except ValueError:
        raise ValueError(f"{path}: geen audiospoor gevonden") from None
    out = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-f", "s16le", "-acodec", "pcm_s16le",
                          "-ac", str(channels), "-ar", str(RATE), "-"], capture_output=True)
    if out.returncode != 0 or not out.stdout:
        raise ValueError(f"{path}: ffmpeg kon dit bestand niet lezen: {out.stderr.decode(errors='replace')[:200]}")
    data = np.frombuffer(out.stdout, dtype=np.int16).reshape(-1, channels)
    return data.astype(np.float32) / 32768.0


def channel_labels(channels: int, labels: list[str]) -> list[str]:
    """Spreker per kanaal. Een mono-opname (Plaud, één microfoon aan tafel) heeft alle sprekers
    door elkaar op één kanaal: dat heet dan 'Gesprek'."""
    if channels == len(labels):
        return labels
    if channels == 1:
        return ["Gesprek"]
    raise ValueError(f"{channels} kanalen, maar {len(labels)} sprekers opgegeven")


def segments_from_wav(path: Path, labels: list[str], vad_factory=SileroVAD) -> list[Segment]:
    """Alle uitspraken uit een WAV, gesorteerd op het moment dat ze klaar zijn (zoals live)."""
    data = read_wav(path)
    labels = channel_labels(data.shape[1], labels)
    segs: list[Segment] = []
    for ch, label in enumerate(labels):
        seg = Segmenter(label, vad=vad_factory())
        x = data[:, ch]
        for i in range(0, len(x) - FRAME + 1, FRAME):
            segs.extend(seg.feed(x[i:i + FRAME]))
        segs.extend(seg.flush())
    return sorted(segs, key=lambda s: s.detected_at)
