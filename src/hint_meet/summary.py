"""Na afloop: samenvatting, toezeggingen en actiepunten uit het transcript, als meetingnotitie in de KB.

De notitie komt in <kb>/meetings/, zodat ze bij een volgende meeting zelf kennis is. kb_prep laat
die map met rust (alleen eigen schaduwbestanden worden opgeruimd)."""
from __future__ import annotations

import re
import time
from pathlib import Path

SUMMARY_SYSTEM = """Je maakt het verslag van een zakelijk gesprek voor Stefan, op basis van een automatisch transcript. Het transcript komt van spraakherkenning: neem namen en getallen over zoals ze er staan, en zet [onzeker] achter wat duidelijk verkeerd verstaan lijkt. Verbeter niets op eigen gezag.

Schrijf in het Nederlands, in Markdown, met precies deze kopjes:
## Samenvatting
Drie tot vijf zinnen: waar ging het over en wat is er besloten.
## Toezeggingen en actiepunten
Een lijst: wie doet wat, en wanneer als dat genoemd is. Alleen wat echt toegezegd of afgesproken is.
## Open vragen
Vragen die gesteld zijn en niet beantwoord.

Verzin niets: staat iets niet in het transcript, laat het weg."""


def summarize(utterances, config, client=None) -> str:
    """Alleen het transcript: getoonde hints zijn suggesties, geen afspraken, en horen niet in de basis."""
    import anthropic
    client = client or anthropic.Anthropic()
    transcript = "\n".join(f"[{u.seconds // 60:02d}:{u.seconds % 60:02d}] {u.speaker}: {u.text}" for u in utterances)
    response = client.messages.create(
        model=config["advise"]["model"],
        max_tokens=4000,
        system=SUMMARY_SYSTEM,
        messages=[{"role": "user", "content": f"Transcript:\n{transcript}"}],
    )
    return next((b.text for b in response.content if b.type == "text"), "").strip()


def name_part(text: str, limit: int = 60) -> str:
    """Stukje bestandsnaam uit vrije tekst: geen / : en dergelijke, witruimte samengevoegd, niet te lang."""
    text = re.sub(r'[\x00-\x1f/\\:*?"<>|]+', "-", text)
    return re.sub(r"\s+", " ", text).strip(" .-")[:limit].strip(" .-")


def write_note(kb_root: Path, utterances, hints, summary_md: str, started: float,
               project: str = "", partner: str = "") -> Path:
    """Verslag als <datum-tijd>-<project>-met-<wie>.md (of ...-<project>-gesprek.md zonder naam)."""
    stamp = time.strftime("%Y-%m-%d-%H%M%S", time.localtime(started))
    project, partner = name_part(project), name_part(partner)
    base = "-".join(p for p in (stamp, project, f"met-{partner}" if partner else "gesprek") if p)
    folder = kb_root / "meetings"
    folder.mkdir(parents=True, exist_ok=True)
    n = 1
    while True:   # exclusief aanmaken: nooit een eerder verslag overschrijven, ook niet tegelijk
        path = folder / (f"{base}.md" if n == 1 else f"{base}-{n}.md")
        try:
            handle = path.open("x", encoding="utf-8")
            break
        except FileExistsError:
            n += 1
    title = "Gesprek" + (f" met {partner}" if partner else "") + (f" · {project}" if project else "")
    lines = [f"# {title} · {time.strftime('%d-%m-%Y %H:%M', time.localtime(started))}", "",
             "> Automatisch verslag door hint-meet; transcript via spraakherkenning.", "", summary_md, "",
             "## Getoonde hints",
             "", "> Suggesties van hint-meet tijdens het gesprek, geen afspraken of besluiten.", ""]
    lines += [f"- {h}" for h in hints] or ["(geen)"]
    lines += ["", "## Transcript", ""]
    lines += [f"[{u.seconds // 60:02d}:{u.seconds % 60:02d}] **{u.speaker}:** {u.text}  " for u in utterances]
    with handle:
        handle.write("\n".join(lines) + "\n")
    return path
