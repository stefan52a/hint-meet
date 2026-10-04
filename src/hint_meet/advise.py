"""Het advies: Claude formuleert een korte hint met bronnen, alleen als de gate open is.

Een advies zonder geldige bron (een document uit de aangeleverde passages) wordt niet getoond.
"""
from __future__ import annotations

import re
import time
from dataclasses import dataclass, field

from .gate import format_passages, format_window

ADVISE_SYSTEM = """Je bent de meeting-copilot van Stefan. Tijdens een gesprek verschijnt jouw hint op zijn scherm; hij leest hem in een paar seconden en gebruikt hem in zijn antwoord.

Regels:
- Hooguit {max_sentences} korte zinnen en hooguit {max_words} woorden, Nederlands, zakelijk. Begin direct met de inhoud: het antwoord of de correctie eerst, de onderbouwing daarna.
- Gebruik alleen feiten uit de passages. Noem bedragen, datums en artikelen precies zoals ze daar staan.
- Stukken of passages die als vervallen gemarkeerd zijn, gebruik je alleen om te zeggen dát iets vervallen is; presenteer hun bedragen nooit als geldend.
- Zegt iemand iets dat botst met het dossier, zeg dan kort wat wél geldt.
- Het transcript komt van spraakherkenning: verkeerd verstane namen of getallen lees je zoals ze bedoeld moeten zijn.

Antwoordvorm, precies zo:
<de hint>
BRONNEN: <nummers van de passages waarop de hint steunt, gescheiden door komma's>

Beantwoorden de passages het moment niet, antwoord dan alleen: GEEN"""

def is_none(reply: str) -> bool:
    return re.fullmatch(r"GEEN\.?", reply.strip(), re.I) is not None


def might_be_none(partial: str) -> bool:
    """Kan dit begin nog uitgroeien tot alleen 'GEEN'? Dan nog niet tonen."""
    p = partial.strip().upper()
    return len(p) <= 5 and "GEEN.".startswith(p)


SOURCES_LINE = re.compile(r"\n?\s*BRONNEN:\s*(.*)\s*$", re.S)


@dataclass
class Advice:
    text: str
    sources: list[str] = field(default_factory=list)
    first_ms: float | None = None   # tijd tot de eerste zichtbare tekst

    @property
    def shown(self) -> bool:
        return bool(self.text.strip()) and bool(self.sources)


def parse_reply(reply: str, hits) -> Advice:
    reply = reply.strip()
    if is_none(reply):  # alleen "GEEN"; een hint die met "Geen VPB ..." begint is gewoon een hint
        return Advice("")
    m = SOURCES_LINE.search(reply)
    text = reply[:m.start()].strip() if m else reply
    numbers = [int(n) for n in re.findall(r"\d+", m.group(1))] if m else []
    refs: list[str] = []
    for n in numbers:  # alleen nummers van echte passages; verzonnen nummers tellen niet
        if 1 <= n <= len(hits) and hits[n - 1].chunk.ref not in refs:
            refs.append(hits[n - 1].chunk.ref)
    return Advice(text, refs)


class ClaudeAdvisor:
    """Streamt de hint; on_text krijgt de zichtbare tekst tot nu toe (zonder de BRONNEN-regel)."""

    def __init__(self, config: dict, client=None):
        import anthropic
        self.client = client or anthropic.Anthropic()
        self.model = config["advise"]["model"]
        self.effort = config["advise"].get("effort", "low")
        self.system = ADVISE_SYSTEM.format(max_sentences=config["advise"]["max_sentences"],
                                           max_words=config["advise"].get("max_words", 40))

    def advise(self, window, moment: str, hits, on_text=None) -> Advice:
        prompt = (f"Passages uit het dossier:\n\n{format_passages(hits)}\n\n"
                  f"Gesprek tot nu toe (de onderste beurt is net gezegd):\n{format_window(window)}\n\n"
                  f"Soort moment volgens de poortwachter: {moment}.")
        t0 = time.perf_counter()
        first_ms = None
        reply = ""
        with self.client.beta.messages.stream(
            model=self.model,
            max_tokens=4000,
            system=self.system,
            messages=[{"role": "user", "content": prompt}],
            output_config={"effort": self.effort},
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
        ) as stream:
            for piece in stream.text_stream:
                reply += piece
                visible = reply.split("BRONNEN:")[0].rstrip()
                if visible and not might_be_none(visible):
                    if first_ms is None:
                        first_ms = (time.perf_counter() - t0) * 1000
                    if on_text:
                        on_text(visible)
            final = stream.get_final_message()
        if final.stop_reason == "refusal":
            return Advice("", first_ms=first_ms)
        advice = parse_reply(reply, hits)
        advice.first_ms = first_ms
        return advice
