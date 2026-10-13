"""Sprekerherkenning op stem: wie zegt wat, als alle stemmen op één kanaal binnenkomen (alleen een microfoon, of
een mono-opname).

Per uitspraak een stemafdruk (WeSpeaker ResNet34 via sherpa-onnx, lokaal, ±80 ms op de eerste 3 seconden),
vergeleken met:
- de opgenomen stem van Stefan (`hint-meet voice`): dan heet de uitspraak "Stefan";
- de stemmen die eerder in deze meeting klonken: dezelfde stem houdt hetzelfde nummer ("Speaker 2");
- anders een nieuwe stem: "Speaker 3".

Te korte uitspraken ("ja", "precies") geven een onbetrouwbare afdruk: die houden de naam van het kanaal.
"""
from __future__ import annotations

import json
import threading
import urllib.request
from pathlib import Path

import numpy as np

RATE = 16000
MODEL = Path("~/.cache/hint-meet/models/wespeaker_en_voxceleb_resnet34_LM.onnx").expanduser()
MODEL_URL = ("https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/"
             "wespeaker_en_voxceleb_resnet34_LM.onnx")
VOICES = Path("~/Library/Application Support/hint-meet/voices.json").expanduser()
MAX_SECONDS = 3.0   # langer maakt de afdruk niet beter, wel trager


def normalize(v: np.ndarray) -> np.ndarray:
    n = float(np.linalg.norm(v))
    return v / n if n > 0 else v


class Embedder:
    """Stemafdruk van een stuk audio (16 kHz mono float32), genormaliseerd: cosinus = inproduct."""

    def __init__(self, model: Path = MODEL):
        import sherpa_onnx
        if not model.exists():
            model.parent.mkdir(parents=True, exist_ok=True)
            urllib.request.urlretrieve(MODEL_URL, model)
        cfg = sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(model), num_threads=2)
        self.extractor = sherpa_onnx.SpeakerEmbeddingExtractor(cfg)
        self.lock = threading.Lock()   # één afdruk tegelijk

    def __call__(self, audio: np.ndarray) -> np.ndarray:
        with self.lock:
            stream = self.extractor.create_stream()
            stream.accept_waveform(RATE, np.ascontiguousarray(audio[:int(MAX_SECONDS * RATE)], dtype=np.float32))
            stream.input_finished()
            return normalize(np.array(self.extractor.compute(stream), dtype=np.float32))


def load_voices(path: Path = VOICES) -> dict[str, np.ndarray]:
    if not path.exists():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    return {name: normalize(np.array(v, dtype=np.float32)) for name, v in data.items()}


def save_voice(name: str, embedding: np.ndarray, path: Path = VOICES) -> None:
    data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    data[name] = [round(float(x), 6) for x in normalize(embedding)]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")


def enroll(audio: np.ndarray, embed) -> np.ndarray:
    """Afdruk van een langere opname (bv. 10 s): het gemiddelde over stukken van 3 seconden met stem erin."""
    step = int(MAX_SECONDS * RATE)
    parts = [audio[i:i + step] for i in range(0, len(audio), step)]
    parts = [p for p in parts if len(p) >= RATE and float(np.sqrt(np.mean(p ** 2))) > 0.005] or [audio]
    return normalize(np.mean([embed(p) for p in parts], axis=0))


class SpeakerID:
    """Naam per uitspraak op stem. Draadveilig: de spraakdraad roept identify aan, één tegelijk."""

    def __init__(self, embed, voices: dict[str, np.ndarray] | None = None, threshold: float = 0.65,
                 min_seconds: float = 1.0, unknown_label: str = "Speaker"):
        self.embed, self.threshold, self.min_seconds = embed, threshold, min_seconds
        self.voices = dict(voices or {})
        self.unknown_label = unknown_label
        self.clusters: list[list] = []   # [zwaartepunt, aantal, naam] per stem die in deze meeting klonk
        self.lock = threading.Lock()

    def identify(self, audio: np.ndarray) -> str | None:
        """Naam voor deze uitspraak, of None als hij te kort is om op te herkennen."""
        if len(audio) < self.min_seconds * RATE:
            return None
        e = self.embed(audio)
        with self.lock:
            if self.voices:   # opgenomen stemmen eerst: wie zich heeft laten opnemen, heet bij naam
                name, score = max(((n, float(e @ v)) for n, v in self.voices.items()), key=lambda x: x[1])
                if score >= self.threshold:
                    return name
            best = max(self.clusters, key=lambda c: float(e @ c[0]), default=None)
            if best is not None and float(e @ best[0]) >= self.threshold:
                best[0] = normalize(best[0] * best[1] + e)   # het zwaartepunt schuift mee met de stem
                best[1] += 1
                return best[2]
            label = f"{self.unknown_label} {len(self.clusters) + 1}"
            self.clusters.append([e, 1, label])
            return label


def make_speaker_id(config: dict) -> SpeakerID | None:
    """SpeakerID als speakers.enabled (standaard aan) en sherpa-onnx er is; anders None (kanaalnamen)."""
    s = config.get("speakers", {})
    if not s.get("enabled", True):
        return None
    try:
        embed = Embedder()
    except Exception as e:  # noqa: BLE001 - zonder stemherkenning gewoon de naam van het kanaal
        import sys
        print(f"Sprekerherkenning uit: {e}", file=sys.stderr)
        return None
    return SpeakerID(embed, load_voices(), threshold=s.get("threshold", 0.65), min_seconds=s.get("min_seconds", 1.0))
