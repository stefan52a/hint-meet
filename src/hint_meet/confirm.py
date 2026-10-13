"""De linkerkolom: wat het dossier zegt over wat er gezegd wordt, als korte regel met bron.

Twee soorten regels:
- KLOPT: een concrete bewering uit het gesprek wordt door het dossier onderbouwd (streng: niets wijkt af);
- DOSSIER: het gesprek gaat over een onderwerp of vraag waar het dossier iets concreets over zegt.
Draait naast de hints: alleen voor uitspraken waarbij de gate dicht bleef (geen correctie of antwoord nodig)
maar het dossier wel relevante passages heeft. Een regel zonder geldige bron wordt niet getoond.
"""
from __future__ import annotations

import re

from .advise import Advice, language_rule, parse_reply
from .gate import format_passages, format_window

CONFIRM_SYSTEM = """Je helpt Stefan tijdens een meeting. Naast zijn scherm staat een kolom die laat zien wat zijn dossier zegt over wat er in het gesprek gezegd wordt. Correcties staan elders; daar gaat deze kolom niet over.

Het gaat om de onderste beurt. Lees hem samen met de beurten erboven: een korte of onaffe beurt ("en het gaat over aanvullende dekking", "niet uit de polis maar uit het reglement") hoort bij het onderwerp dat daar al loopt.

Kies één van drie antwoorden:

1. KLOPT — de onderste beurt bevat concrete beweringen (bedragen, datums, afspraken, namen, feiten), de passages onderbouwen ze, en geen enkele bewering wijkt af van het dossier. Stefan leest dit als: gecontroleerd en juist. Wees streng: neem getallen, bedragen en datums zoals ze verstaan zijn en verbeter ze niet; past een waarde niet precies, dan is het geen KLOPT.

2. DOSSIER — de onderste beurt (met zijn context) gaat over een onderwerp, document, artikel of vraag waar de passages iets concreets over zeggen. Geef dan het belangrijkste wat het dossier erover zegt, ook als het maar deels past. Dit is het gewone antwoord: Stefan wil zien wat zijn documenten zeggen over waar het gesprek over gaat.

3. GEEN — smalltalk, de passages zeggen er niets concreets over, of de beurt bevat een bewering die afwijkt van het dossier (dat is een correctie, geen onderbouwing).

Beslis in deze volgorde:
a. Wijkt een concreet gegeven in de beurt af van het dossier? Dan GEEN (dat is een correctie, die staat elders).
b. Zijn alle concrete gegevens in de beurt door de passages onderbouwd? Dan KLOPT.
c. Zeggen de passages iets concreets over het onderwerp (ook als een gegeven in de beurt niet te controleren is)? Dan DOSSIER.
d. Anders GEEN.

Regels:
- Eén korte regel, hooguit 15 woorden, met het precieze gegeven uit het dossier. Geen inleiding.
- Gebruik alleen feiten uit de passages. Noem bedragen, datums en artikelen precies zoals ze daar staan.
- Een passage die als vervallen gemarkeerd is, onderbouwt niets.
- {language_rule} Alleen de woorden KLOPT, DOSSIER en GEEN en de regel BRONNEN: blijven zoals hieronder.

Antwoordvorm, precies zo:
KLOPT: <de regel>   of   DOSSIER: <de regel>
BRONNEN: <nummers van de passages waarop de regel steunt, gescheiden door komma's>

Of alleen: GEEN"""

KINDS = {"KLOPT": "confirms", "DOSSIER": "about"}
LABEL = re.compile(r"^\s*(?:-\s*)?(KLOPT|DOSSIER)\s*[:—-]\s*", re.I)


class ClaudeConfirmer:
    def __init__(self, config: dict, client=None):
        from .gate import claude_client
        c = config.get("confirm", {})
        self.client = client or claude_client(c.get("timeout_s", 8))
        self.model = c.get("model", "claude-haiku-5-5")
        self.effort = c.get("effort", "low")
        self.set_language(config["advise"].get("language"))

    def set_language(self, language: str | None):
        """Taal van de regels in de linkerkolom (None = die van het gesprek); ook tijdens de meeting."""
        self.system = CONFIRM_SYSTEM.format(language_rule=language_rule(language))

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
        line = next((line.strip() for line in advice.text.splitlines() if line.strip()), "")
        m = LABEL.match(line)
        if not m:   # zonder soort weten we niet of het een bevestiging is: niet tonen
            return Advice("")
        advice.kind = KINDS[m.group(1).upper()]
        advice.text = line[m.end():].strip()
        return advice


def make_confirmer(config: dict):
    """ClaudeConfirmer als confirm.enabled (standaard aan); anders None (geen linkerkolom)."""
    if not config.get("confirm", {}).get("enabled", True):
        return None
    return ClaudeConfirmer(config)
