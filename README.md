# hint-meet

Realtime meeting-copilot voor de Mac. Luistert mee, beslist met Jev óf er iets te zeggen valt, zoekt dan in je eigen kennisbank en laat Claude een kort advies formuleren.

> Status: prototype in opbouw. `tools/kb_prep.py` werkt; de modules in `src/hint_meet/` zijn nog stubs.

## Hoe het werkt

```
microfoon + systeemaudio (BlackHole)
        │
        ▼
transcribe.py   faster-whisper, blokjes van 5-8 s, laatste 3 beurten
        │
        ▼
gate.py         Jev: ingrijpen? (Noul) · soort moment (Choice) · KB-collectie (Choice) · urgentie (Score)
        │  alleen boven de drempel
        ▼
kb.py           embeddings over de Markdown-KB + Jev-reranker (Noul per passage, ≥ 0,7)
        │
        ▼
advise.py       Claude, hooguit drie zinnen  ──►  overlay.py
```

Waarom een gate: een LLM-call om de paar seconden is duur en traag. Jev geeft in een fractie van een seconde een kans terug, dus de LLM draait alleen als er echt iets te melden is. Achtergrond en bronnen staan in [docs/gesprek-meeting-copilot-jev.md](docs/gesprek-meeting-copilot-jev.md).

## Projectstructuur

```
hint-meet/
├── README.md
├── pyproject.toml
├── .env.example            PROVIDER, API-keys, KB_ROOT + KB_PROJECT
├── config/
│   └── gate.yaml           drempels voor gate, reranker en advies
├── src/hint_meet/
│   ├── cli.py              hint-meet live | replay
│   ├── transcribe.py       audio-capture en Whisper
│   ├── gate.py             Jev-beslissingslaag
│   ├── kb.py               retrieval + reranking
│   ├── advise.py           advies via Claude
│   ├── overlay.py          altijd-bovenop-venster
│   └── replay.py           kalibratie op opnames, logt naar CSV
├── tools/
│   ├── kb_prep.py          KB-map (docx, xlsx, pptx, pdf, …) → Markdown
│   └── requirements-kb_prep.txt
├── docs/
│   └── gesprek-meeting-copilot-jev.md
└── tests/
    ├── test_kb_prep.py
    └── test_kb_dir.py
```

## Tests

```bash
pip install -e ".[kb-prep,dev]"
pytest
```

## Installatie

Vereist macOS, Python 3.11+ en [BlackHole](https://github.com/ExistentialAudio/BlackHole) om systeemaudio op te vangen.

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -e ".[kb-prep]"
brew install tesseract tesseract-lang   # voor OCR van gescande PDF's
cp .env.example .env        # vul keys en paden in
```

## Kennisbank voorbereiden

`kb_prep.py` zet een map met documenten om naar Markdown, met dezelfde mappenstructuur, YAML-frontmatter per bestand. hint-meet doorzoekt alle `.md`-bestanden in de projectmap, ook die het zelf schrijft.

Elk schaduwbestand heet `<naam>.<ext>.kb-hint-meet.md` (bijvoorbeeld `offerte.pdf.kb-hint-meet.md`). Aan die suffix herkent het script zijn eigen output. Daardoor:

- mag de doelmap ook binnen de bronmap liggen, of dezelfde map zijn: schaduwbestanden worden nooit opnieuw ingelezen;
- verdwijnt de schaduw automatisch als je het bronbestand verwijdert.

Wat van kb_prep is, staat in `_manifest.json` in de doelmap: per schaduwbestand de bron, de hash van de bron, de hash van wat kb_prep schreef en of OCR aan stond. kb_prep overschrijft of verwijdert alleen bestanden die daarin staan en sindsdien niet zijn aangepast. Wat hint-meet of jij zelf in de map zet, blijft staan, ook met dezelfde suffix. Een aangepaste schaduw overschrijf je met `--force`; een bestand dat niet van kb_prep is nooit. Zulke gevallen meldt het script als conflict.

Nog een paar regels:

- Er kan maar één kb_prep tegelijk op dezelfde doelmap draaien (lock in `.kb_prep.lock`).
- Het manifest wordt na elke conversie opgeslagen. Wordt een run precies tussen het schrijven van een schaduw en het opslaan van het manifest afgebroken, dan meldt de volgende run die schaduw als conflict; gooi hem dan weg.
- Schaduwbestanden van vóór het manifest gelden als vreemd. Gooi ze één keer weg en draai opnieuw.
- Exitcodes: `0` alles goed, `1` mislukte conversies of conflicten, `2` bronmap niet gevonden, `3` er draait al een kb_prep op deze map.

Elk project krijgt een eigen KB in `KB_ROOT/<project>/` (standaard `~/KB_md`). Zonder doelmap is het project de naam van de bronmap:

```bash
python tools/kb_prep.py ~/Documents/Fabrikam                     # → ~/KB_md/Fabrikam/
python tools/kb_prep.py ~/Documents/Fabrikam --project fabrikam    # → ~/KB_md/fabrikam/
python tools/kb_prep.py ~/Documents/Fabrikam /ergens/anders      # → /ergens/anders/ (geen submap)
```

`KB_ROOT` komt uit de omgeving, of uit de eerste `.env` in de werkmap of een map daarboven. kb_prep print bij de start de bron- en doelmap.

| Optie       | Wat                                                                                       |
|-------------|-------------------------------------------------------------------------------------------|
| `--project` | naam van de submap; standaard de naam van de bronmap als je geen doelmap opgeeft         |
| `--no-ocr`  | OCR uitzetten. Standaard leest kb_prep gescande PDF-pagina's (zonder tekstlaag) uit met Tesseract |
| `--force`   | alles opnieuw omzetten, ook ongewijzigde bronnen, en eigen schaduwbestanden overschrijven die je hebt aangepast. Bestanden die niet van kb_prep zijn blijven altijd staan |

```
~/KB_md/
├── fabrikam/
│   ├── _manifest.json
│   └── offerte.pdf.kb-hint-meet.md
└── acme/
    └── …
```

hint-meet kiest de map via `KB_ROOT` en `KB_PROJECT` in `.env`, of met `hint-meet --project fabrikam live`. Projectnamen mogen letters, cijfers, spaties en `. _ -` bevatten, maar moeten met een letter of cijfer beginnen.

Een KB hoort bij één bronmap; dat staat in het manifest. Hebben twee bronmappen dezelfde naam (`klantA/docs` en `klantB/docs`), dan weigert de tweede run en vraagt om een eigen `--project`. Met `--force` koppel je een KB bewust aan een andere bronmap.

Ondersteund: `.docx .xlsx .xlsm .csv .pptx .pdf .html .htm .txt .md .json .rtf`, en met OCR ook afbeeldingen (`.png .jpg .jpeg .tif .tiff .webp`). OCR leest ook gescande PDF-pagina's en slides die alleen uit een afbeelding bestaan. Levert een bestand minder dan 50 tekens tekst op, dan komt het wel in de KB maar meldt kb_prep het met ⚠, zodat je de bron kunt nakijken. Of een bestand opnieuw moet, bepaalt de inhoud (hash), niet de wijzigingsdatum; bij PDF's, presentaties en afbeeldingen ook de OCR-instelling. Verbetert kb_prep zelf (`CONVERTER_VERSION`), dan worden bestaande schaduwbestanden bij de volgende run opnieuw gemaakt. OCR vereist `brew install tesseract tesseract-lang`. Als OCR mislukt, telt het bestand als mislukt en komt het niet in de KB; gebruik dan `--no-ocr`.

## Providers

`PROVIDER` in `.env` kiest de beslissingslaag:

| Waarde    | Wat                                                                 |
|-----------|---------------------------------------------------------------------|
| `jev`     | TypeSafe Jev via de API (key nodig)                                 |
| `laya`    | Laya lokaal via `laya-serve`, zelfde endpoint, geen cloud-call      |
| `adapter` | TypeSafe's system-one-adapter op een gewone LLM, om zonder Jev-key te testen |

## Drempels kalibreren

Te lage drempels geven spam, te hoge geven stilte. Draai een paar opgenomen meetings door de replay-modus en stel `config/gate.yaml` bij op basis van de CSV:

```bash
hint-meet replay opname.wav --out logs/replay.csv
```

## Kanttekeningen

- `jev-latest` kan zonder aankondiging veranderen. Log de geretourneerde modelversie en pin een geteste versie.
- Jev is zwak op lange, rommelige input. Stuur alleen de laatste twee à drie beurten mee.
- Meetings zijn Nederlandstalig, dus kies een multilingual Whisper-model en Laya-checkpoint.
