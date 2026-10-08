"""De gate: beslist per transcriptblok óf er nu een hint nodig is, zonder zelf tekst te schrijven.

Zoals Jev: alleen getypeerde antwoorden (een kans, een keuze, een score). De gate ziet de laatste
beurten en de best passende passages uit de KB, zodat ze ook een bewering kan herkennen die
botst met het dossier.

Providers (config/gate.yaml, gate.provider): jev (standaard) en claude (Haiku, als terugvaloptie).
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


VERVALLEN_NOTE = "⚠ VERVALLEN — niet meer geldend; alleen gebruiken om te zeggen dát dit vervallen is.\n"


def format_passages(hits) -> str:
    return "\n\n".join(
        f"[{i}] {h.chunk.ref}" + (f" › {h.chunk.heading}" if h.chunk.heading else "") + "\n"
        + (VERVALLEN_NOTE if h.chunk.superseded else "") + h.chunk.text
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


MOMENT_DESCRIPTIONS = {
    "vraag_aan_mij": "Iemand stelt Stefan een vraag of vraagt hem iets te bevestigen.",
    "onjuiste_bewering": "Iemand noemt een bedrag, datum of afspraak die niet klopt met het dossier of vervallen is.",
    "risico": "Iemand wijst op een risico of probleem dat in het dossier beschreven staat.",
    "toezegging": "Iemand doet een toezegging of spreekt een actie af.",
    "smalltalk": "Persoonlijk gesprek, beleefdheden of iets buiten het dossier.",
    "overig": "Iets anders, zoals procesafspraken of een reactie zonder nieuwe inhoud.",
}

URGENCY_LEVELS = [
    "Geen hint nodig.",
    "Kan later, bijvoorbeeld na het gesprek.",
    "Handig binnen een minuut.",
    "Nu nodig: Stefan moet hierop antwoorden.",
    "Direct nodig: anders gaat het gesprek uit van een verkeerd feit.",
]


class JevGate:
    """Jev (TypeSafe) als poortwachter: één system_one-aanroep met een Noul, een Choice en een Score.

    De state bevat alleen de laatste beurten, de passages en de net getoonde hint: Jev is volgens
    TypeSafe zwak op grote, rommelige states."""

    def __init__(self, config: dict, client=None):
        from typesafe_sdk import Choice, Noul, Score, TypeSafeClient
        self.client = client or TypeSafeClient()
        self.model = config["gate"].get("jev_model", "jev-latest")
        self.moments = config["moments"]
        self.questions = {
            "hint_nodig": Noul(
                instructions="Heeft Stefan op dit moment een hint nodig, gezien de onderste beurt van het gesprek?",
                criteria={
                    "true": ("De onderste beurt stelt Stefan een vraag die de dossierpassages beantwoorden en die "
                             "hij nog niet correct beantwoord heeft, of bevat een bewering die botst met de "
                             "dossierpassages (verkeerd bedrag, vervallen afspraak), of raakt een risico uit het "
                             "dossier waar Stefan op moet reageren."),
                    "false": ("De onderste beurt is smalltalk, een planningsafspraak, een uitspraak die klopt met "
                              "het dossier, een vraag die Stefan al goed beantwoord heeft, iets wat de net getoonde "
                              "hint al dekt, of iets waar de dossierpassages niets over zeggen."),
                },
            ),
            "moment": Choice(instructions="Wat voor moment is de onderste beurt?",
                             criteria={m: MOMENT_DESCRIPTIONS.get(m) for m in self.moments}),
            "urgentie": Score(instructions="Hoe snel heeft Stefan een hint nodig?", criteria=URGENCY_LEVELS),
        }
        self.last_model = None

    def evaluate(self, window, hits, previous_hint: str | None = None) -> GateResult:
        state = {
            "gesprek": [str(u) for u in window],
            "onderste_beurt": str(window[-1]) if window else "",
            "dossierpassages": [{"document": h.chunk.ref, "kop": h.chunk.heading, "tekst": h.chunk.text,
                                 "vervallen": h.chunk.superseded} for h in hits],
            "net_getoonde_hint": previous_hint,
        }
        r = self.client.system_one(state, self.questions, model=self.model)
        self.last_model = r.model  # jev-latest kan ongemerkt veranderen: loggen wat er echt draaide
        return GateResult(float(r.nouls["hint_nodig"].noul), r.choices["moment"].choice,
                          int(round(r.scores["urgentie"].score)))


def make_gate(config: dict):
    provider = config["gate"]["provider"]
    if provider == "claude":
        return ClaudeGate(config)
    if provider == "jev":
        return JevGate(config)
    raise NotImplementedError(f"gate-provider {provider!r}: alleen claude en jev")
