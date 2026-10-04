"""Kalibratie van de gate: alleen de gate over een transcript (geen advies), dan per drempel
hoeveel gemarkeerde momenten opengaan en hoe vaak de gate op ruis opengaat.

De gate krijgt hier geen 'net getoonde hint' mee (die hangt af van eerdere adviezen); zo zijn
providers eerlijk te vergelijken. De volledige replay laat daarna het echte gedrag zien."""
from __future__ import annotations

import csv
import time
from dataclasses import dataclass
from pathlib import Path


@dataclass
class GateRow:
    index: int
    p: float
    moment: str
    urgency: int
    ms: float


def run_gate(utterances, kb, gate, config) -> list[GateRow]:
    rows = []
    for i in range(len(utterances)):
        window = utterances[max(0, i + 1 - config["window_turns"]):i + 1]
        query = " ".join(u.text for u in utterances[max(0, i + 1 - config["kb"]["query_turns"]):i + 1])
        hits = kb.search(query, k=config["kb"]["gate_passages"])
        t = time.perf_counter()
        r = gate.evaluate(window, hits, None)
        rows.append(GateRow(i, r.intervene, r.moment, r.urgency, (time.perf_counter() - t) * 1000))
    return rows


def sweep(utterances, rows, thresholds, urgency_min: int = 0):
    marked = [i for i, u in enumerate(utterances) if u.expect]
    allowed = {j for m in marked for j in (m, m + 1)}
    out = []
    for t in thresholds:
        opened = {r.index for r in rows if r.p >= t and r.urgency >= urgency_min}
        hits = sum(1 for m in marked if m in opened or m + 1 in opened)
        out.append((t, hits, len(marked), len(opened - allowed)))
    return out


def write_rows(path: Path, utterances, rows) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["tijd", "spreker", "tekst", "verwacht", "kans", "moment", "urgentie", "ms"])
        for r in rows:
            u = utterances[r.index]
            w.writerow([f"{u.seconds // 60:02d}:{u.seconds % 60:02d}", u.speaker, u.text, u.expect or "",
                        f"{r.p:.3f}", r.moment, r.urgency, f"{r.ms:.0f}"])
