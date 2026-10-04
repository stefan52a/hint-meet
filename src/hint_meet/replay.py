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
