"""Per transcriptblok: zoeken in de KB → gate → (alleen als de gate open is) advies."""
from __future__ import annotations

import time
from dataclasses import dataclass, field

from .advise import Advice
from .gate import GateResult


@dataclass
class Step:
    index: int
    gate: GateResult
    refs: list[str]                  # documenten van de passages die de gate zag
    advice: Advice | None = None
    suppressed: str = ""             # reden als een advies niet getoond wordt
    ms: dict = field(default_factory=dict)

    @property
    def shown(self) -> bool:
        return self.advice is not None and self.advice.shown and not self.suppressed


class Pipeline:
    def __init__(self, kb, gate, advisor, config: dict):
        self.kb, self.gate, self.advisor, self.config = kb, gate, advisor, config
        self.last_sources: set[str] = set()
        self.last_index = -10
        self.last_hint = ""

    def step(self, history: list, index: int, on_text=None) -> Step:
        cfg = self.config
        window = history[max(0, index + 1 - cfg["window_turns"]):index + 1]
        query_turns = history[max(0, index + 1 - cfg["kb"]["query_turns"]):index + 1]
        ms = {}

        t = time.perf_counter()
        hits = self.kb.search(" ".join(u.text for u in query_turns), k=cfg["kb"]["advise_passages"])
        ms["zoeken"] = (time.perf_counter() - t) * 1000

        t = time.perf_counter()
        gate_hits = hits[:cfg["kb"]["gate_passages"]]
        # zolang de vorige hint nog binnen het venster valt, weet de gate dat die er al was
        previous = self.last_hint if index - self.last_index < cfg["window_turns"] else None
        result = self.gate.evaluate(window, gate_hits, previous)
        ms["gate"] = (time.perf_counter() - t) * 1000
        step = Step(index, result, [h.chunk.ref for h in gate_hits], ms=ms)
        if not result.open(cfg):
            return step

        t = time.perf_counter()
        step.advice = self.advisor.advise(window, result.moment, hits, on_text=on_text)
        ms["advies"] = (time.perf_counter() - t) * 1000
        if getattr(step.advice, "first_ms", None) is not None:
            ms["advies_eerste"] = step.advice.first_ms
        if not step.advice.shown:
            step.suppressed = "geen bron"
        elif set(step.advice.sources) == self.last_sources and index - self.last_index <= 1:
            # de beurt direct na een hint, met dezelfde bronnen: dezelfde hint nog eens, niet tonen
            step.suppressed = "herhaling"
        if step.shown:
            self.last_sources, self.last_index = set(step.advice.sources), index
            self.last_hint = step.advice.text
        return step
