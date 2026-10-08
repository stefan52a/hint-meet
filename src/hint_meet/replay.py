"""Replay: een transcript blok voor blok door de pijplijn, met een CSV-log per blok en een score
tegen de #!-markeringen. (Replay van audio volgt in M4.)"""
from __future__ import annotations

import csv
import re
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Score:
    moments: int
    hits: list[int]            # indexen van gemarkeerde momenten met een hint
    missed: list[int]
    false_pos: list[int]       # hints buiten een gemarkeerd moment (of de beurt erna)
    keyword_rate: float        # aandeel kernfeiten dat in de hints terugkomt


def _norm(s: str) -> str:
    s = s.lower()
    s = re.sub(r"(?<=\d)[.](?=\d{3}\b)", "", s)
    return re.sub(r"\s+", " ", s)


def keyword_hits(expect: str, text: str) -> tuple[int, int]:
    """Hoeveel kernfeiten uit '#! advies:' (komma-gescheiden) in de hint staan; ruwe check:
    een kernfeit telt als al zijn woorden en getallen erin voorkomen."""
    facts = [f.strip() for f in expect.split(",") if f.strip()]
    hay = _norm(text)
    found = sum(1 for f in facts if all(w in hay for w in re.findall(r"[\w%]+", _norm(f))))
    return found, len(facts)


def score(utterances, steps) -> Score:
    marked = [i for i, u in enumerate(utterances) if u.expect]
    shown = [s for s in steps if s.shown]
    hits, false_pos = [], []
    found = total = 0
    for s in shown:
        m = next((m for m in marked if s.index in (m, m + 1)), None)
        if m is None:
            false_pos.append(s.index)
        elif m not in hits:
            hits.append(m)
            f, t = keyword_hits(utterances[m].expect, s.advice.text)
            found, total = found + f, total + t
    missed = [m for m in marked if m not in hits]
    for m in missed:
        total += len([f for f in utterances[m].expect.split(",") if f.strip()])
    return Score(len(marked), hits, missed, false_pos, found / total if total else 0.0)


def replay(utterances, pipeline, out_csv: Path | None = None, on_step=None):
    steps = []
    try:
        for i in range(len(utterances)):
            step = pipeline.step(utterances, i)
            steps.append(step)
            if on_step:
                on_step(utterances[i], step)
    finally:
        if out_csv:  # ook bij een fout halverwege: wat er is, blijft bewaard
            write_csv(Path(out_csv), utterances[:len(steps)], steps)
    return steps


def write_csv(path: Path, utterances, steps) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["tijd", "spreker", "tekst", "verwacht", "kans", "moment", "urgentie",
                    "getoond", "onderdrukt", "hint", "bronnen", "ms_zoeken", "ms_gate", "ms_advies"])
        for u, s in zip(utterances, steps):
            a = s.advice
            w.writerow([f"{u.seconds // 60:02d}:{u.seconds % 60:02d}", u.speaker, u.text, u.expect or "",
                        f"{s.gate.intervene:.2f}", s.gate.moment, s.gate.urgency,
                        int(s.shown), s.suppressed, a.text if a else "", "; ".join(a.sources) if a else "",
                        f"{s.ms.get('zoeken', 0):.0f}", f"{s.ms.get('gate', 0):.0f}", f"{s.ms.get('advies', 0):.0f}"])


# ---------- audio ----------

def _words(text: str) -> list[str]:
    return re.findall(r"[\w%€]+", _norm(text))


def wer(reference: str, hypothesis: str) -> tuple[int, int]:
    """Woordfouten (vervanging, weglating, invoeging) en het aantal referentiewoorden."""
    r, h = _words(reference), _words(hypothesis)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev, d[j] = d[j], cur
    return d[len(h)], len(r)


@dataclass
class AudioTiming:
    script_index: int | None   # welke scriptuitspraak dit segment het meest overlapt
    detect_ms: float           # van het echte einde van de uitspraak tot de VAD het einde ziet
    asr_ms: float


def match_script(segment, timeline) -> int | None:
    best, best_overlap = None, 0.0
    for u in timeline:
        overlap = min(segment.end, u["end"]) - max(segment.start, u["start"])
        if overlap > best_overlap:
            best, best_overlap = u["index"], overlap
    return best


def audio_replay(segments, transcriber, pipeline, script, timeline, out_csv: Path | None = None, on_step=None):
    """Segmenten in de volgorde waarin ze klaar zijn → Whisper → pijplijn. Geeft (uitspraken, stappen,
    timings) terug; de uitspraken krijgen de #!-markering van de scriptuitspraak die ze overlappen."""
    from .transcript import Utterance

    utterances, steps, timings = [], [], []
    try:
        for seg in segments:
            text, asr_ms = transcriber(seg.audio, seg.channel)
            if not text:
                continue
            idx = match_script(seg, timeline) if timeline else None
            expect = script[idx].expect if idx is not None else None
            true_end = timeline[idx]["end"] if idx is not None else seg.end
            u = Utterance(int(seg.start), seg.channel, text, expect)
            utterances.append(u)
            timings.append(AudioTiming(idx, (seg.detected_at - true_end) * 1000, asr_ms))
            step = pipeline.step(utterances, len(utterances) - 1)
            steps.append(step)
            if on_step:
                on_step(u, step, timings[-1])
    finally:
        if out_csv:
            write_csv(Path(out_csv), utterances, steps)
    return utterances, steps, timings


def latency_ms(step, timing) -> tuple[float, float | None]:
    """Vertraging tot de gate beslist en (als er een hint is) tot de eerste zichtbare woorden."""
    base = timing.detect_ms + timing.asr_ms + step.ms.get("zoeken", 0) + step.ms.get("gate", 0)
    first = step.ms.get("advies_eerste")
    return base, (base + first) if first is not None else None
