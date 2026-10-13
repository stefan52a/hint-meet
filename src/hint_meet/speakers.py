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


MAX_SAMPLES = 10   # afdrukken per naam (headset, laptop, vergaderruimte, …); de oudste valt eraf


def _samples(value) -> list[list[float]]:
    """Eén afdruk ([0.1, …], oud formaat) of een lijst afdrukken ([[0.1, …], …])."""
    return [value] if value and not isinstance(value[0], list) else list(value)


def _read(path: Path) -> dict[str, list[list[float]]]:
    if not path.exists():
        return {}
    return {name: _samples(v) for name, v in json.loads(path.read_text(encoding="utf-8")).items()}


def load_voices(path: Path = VOICES) -> dict[str, np.ndarray]:
    """Naam → afdrukken (aantal × dim), elk genormaliseerd."""
    out = {}
    for name, samples in _read(path).items():
        m = np.array(samples, dtype=np.float32)
        out[name] = m / np.maximum(np.linalg.norm(m, axis=1, keepdims=True), 1e-9)
    return out


def save_voice(name: str, embedding: np.ndarray, path: Path = VOICES, replace: bool = False) -> int:
    """Een afdruk toevoegen aan `name` (of met replace alle eerdere vervangen). Geeft het aantal afdrukken terug."""
    data = _read(path)
    samples = ([] if replace else data.get(name, [])) + [[round(float(x), 6) for x in normalize(embedding)]]
    data[name] = samples[-MAX_SAMPLES:]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")
    return len(data[name])


def forget_voice(name: str, path: Path = VOICES) -> None:
    data = _read(path)
    data.pop(name, None)
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
                 min_seconds: float = 1.0, unknown_label: str = "Speaker", enroll_threshold: float = 0.75):
        """threshold: zelfde stem binnen deze meeting. enroll_threshold: strenger, voor een opgenomen stem (een
        verkeerde naam is erger dan "Speaker 1"; een ander kan best 0,7 op jouw stem lijken)."""
        self.embed, self.threshold, self.min_seconds = embed, threshold, min_seconds
        self.enroll_threshold = enroll_threshold
        # naam → afdrukken (aantal × dim); één losse afdruk mag ook
        self.voices = {n: (v if v.ndim == 2 else v[None, :]) for n, v in (voices or {}).items()}
        self.unknown_label = unknown_label
        self.voices_path = VOICES   # waar remember() een stem bewaart
        self.clusters: list[list] = []   # [zwaartepunt, aantal, naam] per stem die in deze meeting klonk
        self.lock = threading.Lock()

    def identify(self, audio: np.ndarray) -> str | None:
        """Naam voor deze uitspraak, of None als hij te kort is om op te herkennen."""
        if len(audio) < self.min_seconds * RATE:
            return None
        e = self.embed(audio)
        with self.lock:
            # per naam de best passende afdruk: jouw headset-opname voor een uitspraak via je headset
            name, named = max(((n, float(np.max(v @ e))) for n, v in self.voices.items()), key=lambda x: x[1],
                              default=(None, -1.0))
            best = max(self.clusters, key=lambda c: float(e @ c[0]), default=None)
            clustered = float(e @ best[0]) if best is not None else -1.0
            # de beste match wint: lijkt een stem uit deze meeting meer, dan is het die (en niet de opgenomen stem)
            if name is not None and named >= self.enroll_threshold and named >= clustered:
                return name
            if best is not None and clustered >= self.threshold:
                best[0] = normalize(best[0] * best[1] + e)   # het zwaartepunt schuift mee met de stem
                best[1] += 1
                return best[2]
            label = f"{self.unknown_label} {len(self.clusters) + 1}"
            self.clusters.append([e, 1, label])
            return label


    def remember(self, label: str, name: str) -> bool:
        """De stem achter `label` (bv. "Speaker 1") onthouden als `name`, ook voor volgende meetings."""
        with self.lock:
            cluster = next((c for c in self.clusters if c[2] == label), None)
            if cluster is None:
                return False
            voice = cluster[0].copy()
        save_voice(name, voice, self.voices_path)   # eerst bewaren: lukt dat niet, dan ook niet in het geheugen
        with self.lock:
            known = self.voices.get(name)
            self.voices[name] = voice[None, :] if known is None else np.vstack([known, voice])[-MAX_SAMPLES:]
        return True


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
    return SpeakerID(embed, load_voices(), threshold=s.get("threshold", 0.65), min_seconds=s.get("min_seconds", 1.0),
                     enroll_threshold=s.get("enroll_threshold", 0.75))
