"""De bevestiging: wat er gezegd is en klopt met het dossier, als korte regel met bron (linkerkolom in de app).

Draait naast de hints: alleen voor uitspraken waarbij de gate dicht bleef (geen correctie of antwoord nodig)
maar het dossier wel relevante passages heeft. Een bevestiging zonder geldige bron wordt niet getoond.
"""
from __future__ import annotations

from .advise import Advice, language_rule, parse_reply
from .gate import format_passages, format_window

CONFIRM_SYSTEM = """Je helpt Stefan tijdens een meeting. Naast zijn scherm staat een kolom met wat er in het gesprek gezegd is en door zijn dossier onderbouwd wordt.

Beoordeel alleen de onderste beurt; de beurten erboven zijn context.

Onderbouwen de passages een concrete bewering uit de onderste beurt (een bedrag, datum, afspraak, naam of feit), schrijf dan één korte regel (hooguit 15 woorden): wat er klopt, met het precieze gegeven uit het dossier. Geen inleiding, geen "klopt:" ervoor.
- Gebruik alleen feiten uit de passages. Noem bedragen, datums en artikelen precies zoals ze daar staan.
- Een passage die als vervallen gemarkeerd is, onderbouwt niets.
- Het transcript komt van spraakherkenning: verkeerd verstane namen of getallen lees je zoals ze bedoeld moeten zijn.
- {language_rule} Alleen het woord GEEN en de regel BRONNEN: blijven zoals hieronder.

Antwoordvorm, precies zo:
<de regel>
BRONNEN: <nummers van de passages die de bewering onderbouwen, gescheiden door komma's>

Bevat de onderste beurt geen concrete bewering, wijkt hij af van het dossier, of zeggen de passages er niets over, antwoord dan alleen: GEEN"""


class ClaudeConfirmer:
    def __init__(self, config: dict, client=None):
        from .gate import claude_client
        c = config.get("confirm", {})
        self.client = client or claude_client(c.get("timeout_s", 8))
        self.model = c.get("model", "claude-haiku-5-5")
        self.effort = c.get("effort", "low")
        self.system = CONFIRM_SYSTEM.format(language_rule=language_rule(config["advise"].get("language")))

    def confirm(self, window, hits) -> Advice:
        prompt = (f"Passages uit het dossier:\n\n{format_passages(hits)}\n\n"
                  f"Gesprek tot nu toe (de onderste beurt is net gezegd):\n{format_window(window)}")
        response = self.client.messages.create(
            model=self.model,
            max_tokens=2000,
            system=self.system,
            messages=[{"role": "user", "content": prompt}],
            output_config={"effort": self.effort},
        )
        if response.stop_reason == "refusal":
            return Advice("")
        reply = "".join(b.text for b in response.content if b.type == "text")
        advice = parse_reply(reply, hits)
        # één regel: wat het model daarna nog toelicht valt weg
        advice.text = next((line.strip().removeprefix("- ") for line in advice.text.splitlines() if line.strip()), "")
        return advice


def make_confirmer(config: dict):
    """ClaudeConfirmer als confirm.enabled (standaard aan); anders None (geen linkerkolom)."""
    if not config.get("confirm", {}).get("enabled", True):
        return None
    return ClaudeConfirmer(config)
