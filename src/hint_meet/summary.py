"""Na afloop: samenvatting, toezeggingen en actiepunten uit het transcript, als meetingnotitie.

De notitie komt in <kb>/meetings/, naast de documenten van het project, maar hoort niet bij de kennis: kb.py
slaat die map over (een verslag herhaalt het gesprek en zou de echte documenten wegdrukken). kb_prep laat
die map met rust (alleen eigen schaduwbestanden worden opgeruimd).

Naast elk live-transcript staat <transcript>.meta.json: project, meeting-info, taal, begin, de getoonde hints en
of er een verslag is. Eindigde een meeting zonder verslag (crash, geforceerd gestopt, Claude niet bereikbaar), dan
schrijft write_report() het alsnog, net als na een gewone meeting (Write Report in de app, of `hint-meet report`)."""
from __future__ import annotations

import json
import os
import re
import threading
import time
from pathlib import Path

from . import usage

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
        system=SUMMARY_SYSTEM + (f"\n\nHet gesprek is in deze taal: {LANGUAGE_NAMES[language]}. Schrijf het "
                                 f"verslag in die taal, ook de kopjes." if language in LANGUAGE_NAMES else ""),
        messages=[{"role": "user", "content": f"Transcript:\n{transcript}"}],
    )
    usage.record_claude(response, config["advise"]["model"])
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
    if language and language != "multi":
        return "en"   # vaste teksten zijn er in nl/en/de/fr; voor andere talen Engels
    first = summary_md.lstrip().splitlines()[0].lower() if summary_md.strip() else ""
    for lang, word in (("en", "summary"), ("de", "zusammenfassung"), ("fr", "résumé")):
        if word in first:
            return lang
    return "nl"


def hint_lines(number: int, hint: str) -> list[str]:
    """Een hint als genummerd punt; zijn eigen punten ("- …") ingesprongen eronder."""
    points = [re.sub(r"^\s*[-*•]\s+", "", line).strip() for line in hint.splitlines() if line.strip()]
    if not points:
        return []
    head = f"{number}. "
    return [head + points[0]] + [" " * len(head) + f"- {p}" for p in points[1:]]   # ook bij "10. " goed genest


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
    lines += [line for i, h in enumerate(hints, 1) for line in hint_lines(i, h)] or [none]
    lines += ["", f"## {transcript_head}", ""]
    lines += [f"[{u.seconds // 60:02d}:{u.seconds % 60:02d}] **{u.speaker}:** {u.text}  " for u in utterances]
    with handle:
        handle.write("\n".join(lines) + "\n")
    return path


def meta_path(transcript: Path) -> Path:
    """logs/live-20261017-215747.txt → logs/live-20261017-215747.meta.json"""
    return transcript.with_name(transcript.stem + ".meta.json")


def save_meta(transcript: Path, meta: dict):
    """In één keer vervangen: een crash midden in het schrijven laat de vorige stand staan. Eigen tijdelijk bestand
    per schrijver (proces en draad), zodat twee tegelijk elkaars bestand niet wegzetten."""
    path = meta_path(transcript)
    tmp = path.with_name(f"{path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
    tmp.write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, path)


def load_meta(transcript: Path) -> dict:
    try:
        return json.loads(meta_path(transcript).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


MIN_UTTERANCES = 3   # korter: geen verslag (ook niet na een gewone meeting)


def write_report(transcript: Path, config, client=None) -> Path:
    """Het verslag van een meeting die zonder eindigde, uit het bewaarde transcript en zijn meta: zelfde map,
    naam, hints en taal als na een gewone meeting. Werkt de meta bij, zodat de app hem niet meer aanbiedt."""
    from .transcript import load
    utterances = load(transcript)
    if len(utterances) < MIN_UTTERANCES:
        raise ValueError(f"too short for a report ({len(utterances)} utterances)")
    meta = load_meta(transcript)
    language = meta.get("language", "multi")
    md = summarize(utterances, config, client, language=None if language == "multi" else language)
    note = write_note(Path(meta.get("report_dir", "logs")), utterances, meta.get("hints", []), md,
                      meta.get("started", transcript.stat().st_mtime), project=meta.get("project", ""),
                      info=meta.get("info", ""), language=language)
    if meta:
        save_meta(transcript, {**meta, "report": str(note)})
    return note
