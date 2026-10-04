"""Testaudio: een transcript uitspreken met macOS-stemmen tot een stereo-WAV.

Links = Stefan (zoals de microfoon), rechts = de anderen (zoals systeemaudio in een online meeting).
Naast de WAV komt een tijdlijn (JSON) met per uitspraak de echte begin- en eindtijd, zodat de
replay de vertraging vanaf het einde van een uitspraak kan meten."""
from __future__ import annotations

import json
import subprocess
import tempfile
import wave
from pathlib import Path

import numpy as np

RATE = 16000
GAP_S = 0.7


def speak(text: str, voice: str) -> np.ndarray:
    with tempfile.TemporaryDirectory() as tmp:
        f = Path(tmp) / "u.wav"
        subprocess.run(["say", "-v", voice, "-o", str(f), f"--data-format=LEI16@{RATE}", text], check=True)
        with wave.open(str(f)) as w:
            return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)


def render(utterances, out_wav: Path, me: str = "Stefan", voices: dict | None = None) -> list[dict]:
    voices = voices or {}
    left, right, timeline = [], [], []
    t = 0.5
    pad = np.zeros(int(RATE * 0.5), dtype=np.int16)
    left.append(pad)
    right.append(pad)
    for i, u in enumerate(utterances):
        mine = u.speaker == me
        audio = speak(u.text, voices.get(u.speaker, "Xander" if mine else "Ellen"))
        silence = np.zeros_like(audio)
        left.append(audio if mine else silence)
        right.append(silence if mine else audio)
        gap = np.zeros(int(RATE * GAP_S), dtype=np.int16)
        left.append(gap)
        right.append(gap)
        timeline.append({"index": i, "speaker": u.speaker, "channel": "links" if mine else "rechts",
                         "start": round(t, 3), "end": round(t + len(audio) / RATE, 3)})
        t += len(audio) / RATE + GAP_S
    stereo = np.stack([np.concatenate(left), np.concatenate(right)], axis=1)
    out_wav.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(out_wav), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(stereo.astype(np.int16).tobytes())
    out_wav.with_suffix(".tijdlijn.json").write_text(json.dumps(timeline, indent=1), encoding="utf-8")
    return timeline
