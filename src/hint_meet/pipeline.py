"""Per transcriptblok: zoeken in de KB → gate (en tegelijk de reranker) → (alleen als de gate open is en er een
relevante passage is) advies."""
from __future__ import annotations

import sys
import time
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
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
    rerank: list | None = None       # PassageScore per gevonden passage (None: geen reranker)

    @property
    def shown(self) -> bool:
        return self.advice is not None and self.advice.shown and not self.suppressed


class Pipeline:
    def __init__(self, kb, gate, advisor, config: dict, reranker=None):
        self.kb, self.gate, self.advisor, self.config = kb, gate, advisor, config
        self.reranker = reranker
        self.pool = ThreadPoolExecutor(2) if reranker else None
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
        if self.reranker:   # tegelijk met de gate: kost geen extra wachttijd
            from .gate import format_window
            from .rerank import hit_passages
            question = ("Gesprek (de onderste beurt is net gezegd):\n" + format_window(window))
            scores_future = self.pool.submit(self.reranker.score, question, hit_passages(hits))
        result = self.gate.evaluate(window, gate_hits, previous)
        ms["gate"] = (time.perf_counter() - t) * 1000
        step = Step(index, result, [h.chunk.ref for h in gate_hits], ms=ms)
        if not result.open(cfg):
            if self.reranker:
                scores_future.cancel()   # gate dicht: niet wachten, en nog niet gestart = niet meer doen
            return step
        if self.reranker:
            r = cfg.get("rerank", {})
            try:   # Jev te traag: niet filteren in plaats van de hint op te houden
                step.rerank = scores_future.result(timeout=r.get("timeout_s", 3))
            except FutureTimeout:
                scores_future.cancel()
                print("Reranker (Jev) te traag: passages niet gefilterd", file=sys.stderr)
            ms["rerank"] = (time.perf_counter() - t) * 1000
            if step.rerank is not None:   # alleen relevante passages zonder verborgen instructies
                hits = [h for h, s in zip(hits, step.rerank)
                        if s.relevance >= r.get("min_relevance", 0.5) and s.injection < r.get("max_injection", 0.5)]
        if not hits:   # niets relevants in het dossier: meteen zwijgen, zonder Claude-aanroep
            step.suppressed = "geen relevante passage"
            return step

        t = time.perf_counter()
        # vlak na een getoonde hint is de kans op een herhaling groot: dan pas tonen als hij af en
        # gecontroleerd is, zodat er niets verschijnt dat daarna weer wordt ingetrokken
        stream_to = on_text if index - self.last_index > 1 else None
        step.advice = self.advisor.advise(window, result.moment, hits, on_text=stream_to)
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
