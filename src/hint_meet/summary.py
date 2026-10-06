"""Na afloop: samenvatting, toezeggingen en actiepunten uit het transcript, als meetingnotitie in de KB.

De notitie komt in <kb>/meetings/, zodat ze bij een volgende meeting zelf kennis is. kb_prep laat
die map met rust (alleen eigen schaduwbestanden worden opgeruimd)."""
from __future__ import annotations

import re
import time
from pathlib import Path

SUMMARY_SYSTEM = """Je maakt het verslag van een zakelijk gesprek voor Stefan, op basis van een automatisch transcript. Het transcript komt van spraakherkenning: neem namen en getallen over zoals ze er staan, en zet [onzeker] achter wat duidelijk verkeerd verstaan lijkt. Verbeter niets op eigen gezag.

Schrijf in de taal waarin het gesprek gevoerd is (zijn het meerdere talen: de taal waarin het meest gesproken is), in Markdown, met precies deze drie kopjes, vertaald naar die taal (Engels: Summary / Commitments and action items / Open questions; Duits: Zusammenfassung / Zusagen und Aufgaben / Offene Fragen; Frans: Résumé / Engagements et actions / Questions ouvertes):
## Samenvatting
Drie tot vijf zinnen: waar ging het over en wat is er besloten.
## Toezeggingen en actiepunten
Een lijst: wie doet wat, en wanneer als dat genoemd is. Alleen wat echt toegezegd of afgesproken is.
## Open vragen
Vragen die gesteld zijn en niet beantwoord.

Verzin niets: staat iets niet in het transcript, laat het weg."""


def summarize(utterances, config, client=None, language: str | None = None) -> str:
    """Alleen het transcript: getoonde hints zijn suggesties, geen afspraken, en horen niet in de basis.
    language: de gekozen gesprekstaal (nl, en, de, fr); dan wordt het verslag in die taal geschreven."""
    from .advise import LANGUAGE_NAMES
    import anthropic
    client = client or anthropic.Anthropic()
    transcript = "\n".join(f"[{u.seconds // 60:02d}:{u.seconds % 60:02d}] {u.speaker}: {u.text}" for u in utterances)
    response = client.messages.create(
        model=config["advise"]["model"],
        max_tokens=4000,
        system=SUMMARY_SYSTEM + (f"\n\nHet gesprek is in het {LANGUAGE_NAMES[language]}: schrijf het verslag "
                                 f"in die taal, ook de kopjes." if language in LANGUAGE_NAMES else ""),
        messages=[{"role": "user", "content": f"Transcript:\n{transcript}"}],
    )
    return next((b.text for b in response.content if b.type == "text"), "").strip()


# vaste teksten in het verslagbestand, per taal van het gesprek
NOTE_TEXT = {
    "nl": ("Gesprek", "Automatisch verslag door hint-meet; transcript via spraakherkenning.", "Getoonde hints",
           "Suggesties van hint-meet tijdens het gesprek, geen afspraken of besluiten.", "(geen)", "Transcript"),
    "en": ("Meeting", "Automatic report by hint-meet; transcript from speech recognition.", "Hints shown",
           "Suggestions by hint-meet during the meeting, not agreements or decisions.", "(none)", "Transcript"),
    "de": ("Gespräch", "Automatischer Bericht von hint-meet; Transkript per Spracherkennung.", "Angezeigte Hinweise",
           "Vorschläge von hint-meet während des Gesprächs, keine Vereinbarungen oder Beschlüsse.", "(keine)",
           "Transkript"),
    "fr": ("Réunion", "Compte rendu automatique par hint-meet ; transcription par reconnaissance vocale.",
           "Suggestions affichées", "Suggestions de hint-meet pendant la réunion, ni accords ni décisions.",
           "(aucune)", "Transcription"),
}


def report_language(language: str, summary_md: str) -> str:
    """Taal voor de vaste teksten: de gekozen taal, of bij "multi" afgeleid uit het eerste kopje van het verslag."""
    if language in NOTE_TEXT:
        return language
    first = summary_md.lstrip().splitlines()[0].lower() if summary_md.strip() else ""
    for lang, word in (("en", "summary"), ("de", "zusammenfassung"), ("fr", "résumé")):
        if word in first:
            return lang
    return "nl"


def name_part(text: str, limit: int = 60) -> str:
    """Stukje bestandsnaam uit vrije tekst: geen / : en dergelijke, witruimte samengevoegd, niet te lang."""
    text = re.sub(r'[\x00-\x1f/\\:*?"<>|]+', "-", text)
    return re.sub(r"\s+", " ", text).strip(" .-")[:limit].strip(" .-")


def write_note(kb_root: Path, utterances, hints, summary_md: str, started: float,
               project: str = "", info: str = "", language: str = "nl") -> Path:
    """Verslag als <datum-tijd>-<project>-<meeting-info>.md (of ...-<project>-gesprek.md zonder info).
    info is vrije tekst uit de app, bv. "Jan Jansen, Utrecht"."""
    stamp = time.strftime("%Y-%m-%d-%H%M%S", time.localtime(started))
    project, info = name_part(project), name_part(info)
    base = "-".join(p for p in (stamp, project, info or "gesprek") if p)
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
    word, intro, hints_head, hints_note, none, transcript_head = NOTE_TEXT[report_language(language, summary_md)]
    title = word + (f" · {info}" if info else "") + (f" · {project}" if project else "")
    lines = [f"# {title} · {time.strftime('%d-%m-%Y %H:%M', time.localtime(started))}", "",
             f"> {intro}", "", summary_md, "",
             f"## {hints_head}",
             "", f"> {hints_note}", ""]
    lines += [f"- {h}" for h in hints] or [none]
    lines += ["", f"## {transcript_head}", ""]
    lines += [f"[{u.seconds // 60:02d}:{u.seconds % 60:02d}] **{u.speaker}:** {u.text}  " for u in utterances]
    with handle:
        handle.write("\n".join(lines) + "\n")
    return path
