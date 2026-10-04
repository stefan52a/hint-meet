"""Het advies: Claude formuleert een korte hint met bronnen, alleen als de gate open is.

Een advies zonder geldige bron (een document uit de aangeleverde passages) wordt niet getoond.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field

from .gate import format_passages, format_window

ADVISE_SYSTEM = """Je bent de meeting-copilot van Stefan. Tijdens een gesprek verschijnt jouw hint op zijn scherm; hij leest hem in een paar seconden en gebruikt hem in zijn antwoord.

Regels:
- Hooguit {max_sentences} korte zinnen en hooguit {max_words} woorden, Nederlands, zakelijk. Begin direct met de inhoud: het antwoord of de correctie eerst, de onderbouwing daarna.
- Gebruik alleen feiten uit de passages. Noem bedragen, datums en artikelen precies zoals ze daar staan.
- Stukken of passages die als vervallen gemarkeerd zijn, gebruik je alleen om te zeggen dát iets vervallen is; presenteer hun bedragen nooit als geldend.
- Zegt iemand iets dat botst met het dossier, zeg dan kort wat wél geldt.
- Geef bij sources de documentpaden (zoals na [n] vermeld) waarop de hint steunt.
- Beantwoorden de passages het moment niet, geef dan een lege hint en geen bronnen."""


@dataclass
class Advice:
    text: str
    sources: list[str] = field(default_factory=list)

    @property
    def shown(self) -> bool:
        return bool(self.text.strip()) and bool(self.sources)


class ClaudeAdvisor:
    def __init__(self, config: dict, client=None):
        import anthropic
        self.client = client or anthropic.Anthropic()
        self.model = config["advise"]["model"]
        self.effort = config["advise"].get("effort", "low")
        self.system = ADVISE_SYSTEM.format(max_sentences=config["advise"]["max_sentences"],
                                           max_words=config["advise"].get("max_words", 40))
        self.schema = {
            "type": "object",
            "properties": {
                "hint": {"type": "string"},
                "sources": {"type": "array", "items": {"type": "string"}},
            },
            "required": ["hint", "sources"],
            "additionalProperties": False,
        }

    def advise(self, window, moment: str, hits) -> Advice:
        prompt = (f"Passages uit het dossier:\n\n{format_passages(hits)}\n\n"
                  f"Gesprek tot nu toe (de onderste beurt is net gezegd):\n{format_window(window)}\n\n"
                  f"Soort moment volgens de poortwachter: {moment}.")
        response = self.client.beta.messages.create(
            model=self.model,
            max_tokens=4000,
            system=self.system,
            messages=[{"role": "user", "content": prompt}],
            output_config={"effort": self.effort,
                           "format": {"type": "json_schema", "schema": self.schema}},
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
        )
        if response.stop_reason == "refusal":
            return Advice("")
        text = next((b.text for b in response.content if b.type == "text"), "")
        data = json.loads(text) if text else {"hint": "", "sources": []}
        allowed = {h.chunk.ref for h in hits}
        sources = [s for s in data["sources"] if s in allowed]  # verzonnen bronnen tellen niet
        return Advice(data["hint"].strip(), sources)
