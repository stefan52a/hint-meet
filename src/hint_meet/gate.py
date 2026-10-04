"""De gate: beslist per transcriptblok óf er nu een hint nodig is, zonder zelf tekst te schrijven.

Zoals Jev: alleen getypeerde antwoorden (een kans, een keuze, een score). De gate ziet de laatste
beurten en de best passende passages uit de KB, zodat ze ook een bewering kan herkennen die
botst met het dossier.

Providers: claude (Haiku, tot M3), jev en laya volgen in M3.
"""
from __future__ import annotations

import json
from dataclasses import dataclass

GATE_SYSTEM = """Je bent de poortwachter van een meeting-copilot voor Stefan. Je beslist alleen óf er op dit moment een korte hint op Stefans scherm moet verschijnen; je schrijft de hint niet zelf.

Beoordeel alleen de onderste beurt; de beurten erboven zijn context. Een vraag of onderwerp van een eerdere beurt is geen reden meer voor een hint.

Een hint is nodig als het laatste wat gezegd is:
- een vraag aan Stefan is die de passages uit zijn dossier beantwoorden, en hij het antwoord nog niet zelf correct gegeven heeft;
- een bewering bevat die botst met het dossier (een verkeerd bedrag, een vervallen afspraak, een onjuist feit);
- een risico raakt dat in het dossier beschreven staat en waar Stefan op moet reageren.

Geen hint bij: smalltalk, afspraken over planning, uitspraken die kloppen met het dossier, vragen die Stefan al goed beantwoord heeft, en onderwerpen waar de passages niets over zeggen.

Is er net een hint getoond (die staat erbij), geef dan alleen een nieuwe hint als de onderste beurt een nieuw onderwerp of een nieuwe vraag aansnijdt die de vorige hint niet dekt.

Wees zuinig: een overbodige hint leidt af. Geef een lage kans als je twijfelt."""


@dataclass
class GateResult:
    intervene: float   # kans dat nu een hint nodig is
    moment: str
    urgency: int       # 0-4

    def open(self, config: dict) -> bool:
        g = config["gate"]
        return self.intervene >= g["intervene_min"] and self.urgency >= g["urgency_min"]


def format_passages(hits) -> str:
    return "\n\n".join(
        f"[{i}] {h.chunk.ref}" + (f" › {h.chunk.heading}" if h.chunk.heading else "") + f"\n{h.chunk.text}"
        for i, h in enumerate(hits, 1)
    )


def format_window(window) -> str:
    return "\n".join(str(u) for u in window)


class ClaudeGate:
    def __init__(self, config: dict, client=None):
        import anthropic
        self.client = client or anthropic.Anthropic()
        self.model = config["gate"]["model"]
        self.moments = config["moments"]
        self.schema = {
            "type": "object",
            "properties": {
                "intervene_probability": {"type": "number"},
                "moment": {"type": "string", "enum": self.moments},
                "urgency": {"type": "integer", "enum": [0, 1, 2, 3, 4]},
            },
            "required": ["intervene_probability", "moment", "urgency"],
            "additionalProperties": False,
        }

    def evaluate(self, window, hits, previous_hint: str | None = None) -> GateResult:
        shown = f"Net getoonde hint: {previous_hint}\n\n" if previous_hint else "Er is net geen hint getoond.\n\n"
        prompt = (f"Passages uit het dossier:\n\n{format_passages(hits)}\n\n"
                  f"Laatste beurten van het gesprek (de onderste is net gezegd):\n{format_window(window)}\n\n"
                  + shown +
                  "Geef de kans (0 tot 1) dat Stefan nu een hint nodig heeft, het soort moment, "
                  "en de urgentie (0 = geen, 4 = direct).")
        response = self.client.messages.create(
            model=self.model,
            max_tokens=256,
            system=GATE_SYSTEM,
            messages=[{"role": "user", "content": prompt}],
            output_config={"format": {"type": "json_schema", "schema": self.schema}},
        )
        text = next(b.text for b in response.content if b.type == "text")
        data = json.loads(text)
        p = min(max(float(data["intervene_probability"]), 0.0), 1.0)
        return GateResult(p, data["moment"], int(data["urgency"]))


def make_gate(config: dict):
    provider = config["gate"]["provider"]
    if provider == "claude":
        return ClaudeGate(config)
    raise NotImplementedError(f"gate-provider {provider!r} komt in M3")
