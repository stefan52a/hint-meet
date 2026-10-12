"""Per transcriptblok: zoeken in de KB → gate (en tegelijk de reranker) → (alleen als de gate open is en er een
relevante passage is) advies. Blijft de gate dicht, dan kijkt een bevestiger op de achtergrond of het dossier
onderbouwt wat er gezegd is (linkerkolom in de app); dat houdt de volgende uitspraak niet op."""
from __future__ import annotations

import sys
import threading
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
    CONFIRM_SLOTS = 2   # bevestigingen die tegelijk mogen lopen; komt er meer, dan valt de nieuwe weg
    def __init__(self, kb, gate, advisor, config: dict, reranker=None, confirmer=None):
        self.kb, self.gate, self.advisor, self.config = kb, gate, advisor, config
        self.reranker = reranker
        self.confirmer = confirmer
        # hooguit CONFIRM_SLOTS bevestigingen tegelijk, elk met hooguit één Jev-aanroep waar ze op wachten; de
        # reranker krijgt daarvoor extra werkers, zodat de Jev-aanroep voor een hint nooit achter hen wacht
        extra = self.CONFIRM_SLOTS if confirmer else 0
        self.pool = ThreadPoolExecutor(2 + extra) if reranker else None
        self.confirm_pool = ThreadPoolExecutor(self.CONFIRM_SLOTS) if confirmer else None
        self.confirm_slots = threading.BoundedSemaphore(self.CONFIRM_SLOTS)
        self.last_sources: set[str] = set()
        self.last_index = -10
        self.last_hint = ""

    def step(self, history: list, index: int, on_text=None, on_confirm=None) -> Step:
        """on_confirm(index, Advice): later, uit een andere draad, als het dossier de uitspraak onderbouwt."""
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
            # vol = de bevestiger loopt achter: deze overslaan in plaats van een rij te laten groeien
            if on_confirm and self._worth_confirming(result, window) and self.confirm_slots.acquire(blocking=False):
                # de bevestiger wacht zelf op de reranker; de pijplijn gaat meteen door
                self.confirm_pool.submit(self._confirm, window, hits, scores_future if self.reranker else None,
                                         index, on_confirm, time.monotonic())
            elif self.reranker:
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

    def _worth_confirming(self, result: GateResult, window) -> bool:
        """Smalltalk en heel korte uitspraken ("ja", "precies") bevatten niets om te onderbouwen."""
        if self.confirmer is None or not window or result.moment == "smalltalk":
            return False
        return len(window[-1].text.split()) >= self.config.get("confirm", {}).get("min_words", 4)

    def _confirm(self, window, hits, scores_future, index: int, on_confirm, queued_at: float):
        c = self.config.get("confirm", {})
        try:
            if scores_future is not None:
                try:
                    scores = scores_future.result(timeout=c.get("rerank_timeout_s", 5))
                except FutureTimeout:
                    scores_future.cancel()
                    scores = None
                if scores is None:
                    # Jev te traag of weg: niet ongefilterd bevestigen, want dan is er ook geen
                    # controle op passages met verborgen instructies (een hint gaat dan wel door)
                    return
                max_injection = self.config.get("rerank", {}).get("max_injection", 0.5)
                hits = [h for h, s in zip(hits, scores)
                        if s.relevance >= c.get("min_relevance", 0.6) and s.injection < max_injection]
            # zonder reranker (niet ingesteld) beslist de bevestiger zelf (antwoord GEEN)
            hits = hits[:c.get("passages", 3)]
            if not hits:   # niets relevants in het dossier: geen Claude-aanroep
                return
            if time.monotonic() - queued_at > c.get("max_age_s", 8):   # het gesprek is al verder: niet meer doen
                return
            confirmation = self.confirmer.confirm(window, hits)
            # ook na een trage Claude-aanroep: wat te laat is, hoort niet meer in de kolom
            if confirmation.shown and time.monotonic() - queued_at <= c.get("max_age_s", 8):
                on_confirm(index, confirmation)
        except Exception as e:  # noqa: BLE001 - een bevestiging is een extraatje; de meeting loopt door
            print(f"Bevestiging faalde bij uitspraak {index}: {type(e).__name__}: {e}", file=sys.stderr)
        finally:
            self.confirm_slots.release()

    def close(self):
        """Na Stop: bevestigingen en Jev-aanroepen die nog wachten niet meer uitvoeren. Wat al loopt, eindigt
        binnen zijn timeout; LiveSession meldt het dan niet meer aan de app."""
        for pool in (self.confirm_pool, self.pool):
            if pool:
                pool.shutdown(wait=False, cancel_futures=True)


def clamp(x: float, lo: float, hi: float) -> float:
    return min(max(x, lo), hi)


class Sensitivity:
    """Schuifjes in de app (0 = minder, 1 = meer; 0,5 = de waarden uit gate.yaml) zetten de drempels van de
    lopende meeting. Hints: kans die de gate moet geven en relevantie van passages voor het advies.
    Bevestigingen: relevantie die als onderbouwing telt en hoe lang een uitspraak minstens is."""

    def __init__(self, config: dict):
        self.config = config
        self.base = {
            "intervene_min": config["gate"]["intervene_min"],
            "rerank_min": config.setdefault("rerank", {}).get("min_relevance", 0.5),
            "confirm_min": config.setdefault("confirm", {}).get("min_relevance", 0.6),
            "min_words": config["confirm"].get("min_words", 4),
        }

    def set_hints(self, s: float):
        s = clamp(float(s), 0.0, 1.0)
        self.config["gate"]["intervene_min"] = round(clamp(self.base["intervene_min"] + (0.5 - s) * 0.5, 0.2, 0.9), 3)
        self.config["rerank"]["min_relevance"] = round(clamp(self.base["rerank_min"] + (0.5 - s) * 0.4, 0.1, 0.9), 3)

    def set_confirm(self, s: float):
        s = clamp(float(s), 0.0, 1.0)
        self.config["confirm"]["min_relevance"] = round(clamp(self.base["confirm_min"] + (0.5 - s) * 0.4, 0.1, 0.9), 3)
        self.config["confirm"]["min_words"] = max(2, round(self.base["min_words"] + (0.5 - s) * 4))
