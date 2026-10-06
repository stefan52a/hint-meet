# hint-meet

HintMeet is een meeting-copilot voor de Mac. Het luistert mee tijdens een gesprek, herkent het moment waarop je iets uit je eigen dossier nodig hebt, en zet dan in een paar seconden een korte hint op je scherm: 1 tot 4 punten, met de bron erbij. Na afloop schrijft het een verslag met actiepunten.

**Waarvoor.** Gesprekken waarin details uit een groot dossier ertoe doen: met een fiscalist, notaris, bank, koper of aandeelhouder. Iemand noemt een bedrag, datum of afspraak die niet klopt, of stelt een vraag waarvan het antwoord ergens in je stukken staat. HintMeet vindt dat stuk en zegt kort wat er wél geldt, zodat je niet hoeft te zoeken of te gokken.

**Hoe je het gebruikt.**
1. Zet je documenten (pdf, Word, Excel, mail, scans, …) om naar een kennisbank: *Convert Documents* in de app, of `tools/kb_prep.py`.
2. Kies in HintMeet een of meer projecten en klik *Load KB*, zodat de meeting meteen kan starten.
3. Vul eventueel *Meeting info* in (met wie, waar) en start de meeting. Hints verschijnen in een zwevend paneel boven je meeting, zonder je toetsenbord over te nemen; met ◀ ▶ blader je terug.
4. Na afloop staat het verslag met actiepunten in `<KB>/meetings/`; het transcript in `logs/`.

Spraakherkenning (Whisper via MLX), de kennisbank en het zoeken draaien lokaal. Naar de taalmodellen gaan tijdens de meeting de laatste paar beurten van het gesprek plus de gevonden passages (poortwachter en Claude), en na afloop het hele transcript voor het verslag (Claude; uit te zetten in Settings of met `--no-summary`).

> Status: werkend prototype (Python-pijplijn + macOS-app). Wijzigingen per dag staan in [CHANGELOG.md](CHANGELOG.md).

## Hoe het werkt

```
microfoon + systeemaudio (BlackHole)
        │
        ▼
audio.py        Whisper (MLX) per uitspraak, lokaal; live.py houdt de laatste beurten bij
        │
        ▼
gate.py         Jev: ingrijpen? (Noul) · soort moment (Choice) · KB-collectie (Choice) · urgentie (Score)
        │  alleen boven de drempel
        ▼
kb.py           embeddings over de Markdown-KB + Jev-reranker (Noul per passage, ≥ 0,7)
        │
        ▼
advise.py       Claude, 1 tot 4 korte punten met bron  ──►  server.py  ──►  HintMeet.app (overlay)
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

`KB_ROOT` komt uit de omgeving, of uit de eerste `.env` in de werkmap of een map daarboven. kb_prep print bij de start de bron- en doelmap. In een terminal toont het één voortgangsregel (`[ 7/18] bestand · pagina 23/80 · nog ~2 min`; pagina's bij PDF en TIFF, slides bij presentaties) en alleen meldingen als eigen regel; naar een pipe of logbestand blijft elke regel staan.

| Optie         | Wat                                                                                                                                                                       |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--project` | naam van de submap; standaard de naam van de bronmap als je geen doelmap opgeeft                                                                                          |
| `--no-ocr`  | OCR uitzetten. Standaard leest kb_prep gescande PDF-pagina's (zonder tekstlaag) uit met Tesseract                                                                         |
| `--force`   | alles opnieuw omzetten, ook ongewijzigde bronnen, en eigen schaduwbestanden overschrijven die je hebt aangepast. Bestanden die niet van kb_prep zijn blijven altijd staan |

### Bestanden uitsluiten met `.kbignore`

Zet een `.kbignore` in de root van de bronmap, met gitignore-syntax. Uitgesloten bestanden komen niet in de KB, en al bestaande schaduwbestanden ervan worden opgeruimd.

```gitignore
# alleen de tmp-map in de root; tmp/ zonder / raakt elke tmp-map in de boom
/tmp/
*.log
# ! haalt iets terug, ook binnen een uitgesloten map
!tmp/bewaar.pdf
```

Commentaar staat altijd op een eigen regel: een `#` achter een patroon hoort bij het patroon.

Zonder `.kbignore` slaat kb_prep al over: dependency-mappen (`node_modules`, `__pycache__`, `venv`, `site-packages`, `Pods`, …), mappen die met een punt beginnen (`.git`, `.venv`) en build-mappen (`build`, `dist`, `target`, `out`, `bin`, `obj`) als er een projectbestand naast staat (`package.json`, `pyproject.toml`, `Makefile`, …). Een gewone map `dist` in je administratie doet dus gewoon mee.

### Beveiligde PDF's met `.kbpasswords`

Een PDF met een wachtwoord kan kb_prep alleen lezen als het wachtwoord bekend is. Zet de wachtwoorden in `.kbpasswords` in de root van de bronmap, één per regel:

```
# phone contracts
1234AB
# loonstroken
01011970
```

- Bij elke beveiligde PDF probeert kb_prep eerst een leeg wachtwoord en daarna alle regels uit het bestand, van boven naar beneden. Je hoeft dus niet aan te geven welk wachtwoord bij welk bestand hoort.
- Regels die met `#` beginnen zijn commentaar; spaties voor en achter een wachtwoord tellen niet mee. Hoofdletters wel: `1234ab` is een ander wachtwoord dan `1234AB`.
- Past er geen, dan telt de PDF als mislukt met de melding `PDF is beveiligd met een wachtwoord (niet gevonden in .kbpasswords)`. Na het toevoegen van het juiste wachtwoord pakt de volgende run hem vanzelf op.
- Het bestand begint met een punt en komt dus zelf nooit in de KB. De wachtwoorden komen ook niet in de frontmatter of het manifest; de omgezette tekst van de PDF staat wel onbeveiligd in de KB.
- Het bestand is platte tekst. Synchroniseert de bronmap via Dropbox of iCloud, dan gaan de wachtwoorden mee. Zet er geen wachtwoorden in die ook ergens anders toegang toe geven.

### E-mail (`.eml`)

Van, aan, cc, datum en onderwerp staan bovenaan, daarna de tekst (html wordt Markdown). Bijlagen van een ondersteund type worden meegenomen onder `## Bijlage: <naam>`; andere bijlagen staan er met hun naam. Logo's en handtekeningafbeeldingen in de html worden overgeslagen. Een bijlage die niet te lezen is, houdt de mail zelf niet uit de KB.

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

Ondersteund: `.docx .xlsx .xlsm .csv .pptx .pdf .html .htm .txt .md .json .rtf .eml`, oude Office- en OpenOffice-bestanden (`.doc .odt` via textutil, `.xls` via xlrd; een "xls" die eigenlijk html is wordt als html gelezen), webarchieven (`.mht .mhtml`), en met OCR ook afbeeldingen (`.png .jpg .jpeg .tif .tiff .webp .gif .bmp`; van een bewegende GIF alleen het eerste beeld). OCR leest ook gescande PDF-pagina's en slides die alleen uit een afbeelding bestaan. Levert een bestand minder dan 50 tekens tekst op, dan komt het wel in de KB maar meldt kb_prep het met ⚠, zodat je de bron kunt nakijken. Of een bestand opnieuw moet, bepaalt de inhoud (hash), niet de wijzigingsdatum; bij PDF's, presentaties en afbeeldingen ook de OCR-instelling. Verbetert kb_prep zelf (`CONVERTER_VERSION`), dan worden bestaande schaduwbestanden bij de volgende run opnieuw gemaakt. OCR vereist `brew install tesseract tesseract-lang`. Als OCR mislukt, telt het bestand als mislukt en komt het niet in de KB; gebruik dan `--no-ocr`.

## Zoeken in de KB testen

`kb.py` zoekt hybride: een lokaal embeddingmodel (`intfloat/multilingual-e5-large`, op Apple Silicon via MLX op de GPU, anders via onnxruntime; downloadt bij eerste gebruik) plus BM25 voor exacte termen als bedragen en artikelnummers. Embeddings worden per stukje gecachet in `<kb>/.hint-meet-cache/`.

```bash
hint-meet eval-kb data/eval/acme-vragen.yaml
```

Een nieuwe of flink gegroeide KB vooraf indexeren, zodat een meeting direct start: `hint-meet --project <naam> index` (Contoso, 4.000 stukjes: ±8 minuten, eenmalig; daarna alleen nieuwe stukjes).

Een vragenlijst is YAML met per vraag de stukken waar het antwoord staat; zie `data/eval/` (staat niet in git, want bevat dossierinhoud).

## Gebruiken

```bash
hint-meet --project acme live                              # microfoon
hint-meet --project acme live --system "BlackHole 2ch"     # plus systeemaudio van een online meeting
hint-meet --project acme live --audio opname.mp3          # eerdere opname (mp3, m4a, wav) in echte tijd
hint-meet --project acme replay gesprek.txt                # transcript met #!-markeringen, met score
hint-meet --project acme replay gesprek.wav                # opname (stereo: jij links, de ander rechts)
hint-meet --project acme calibrate gesprek.txt --gate jev  # alleen de gate, drempeltabel
hint-meet live --devices                                    # audioapparaten tonen
```

App: bouw met `app/build-app.sh`; dat installeert HintMeet in `~/Applications`, met icoon, zodat je hem start via Spotlight, Launchpad of het Dock (sleep hem erin om hem vast te zetten). Na een nieuwe build pak je de nieuwe versie op met **HintMeet herstarten** in het 💡-menu. De app onthoudt waar deze repo staat; verplaats je de repo, bouw dan opnieuw. Kies in het menu 💡 een project en start de meeting; de app start de pijplijn zelf (uit `.venv` in deze map) en stopt hem ook weer. API-keys zet je in Instellingen (Keychain). Zonder app kan het ook: `hint-meet --project acme live --ui` met alleen de overlay. Het paneel blijft boven je meeting zonder je toetsenbord over te nemen; 💡 in de menubalk toont of verbergt het. 👍/👎 komt in `logs/feedback.jsonl`. Na afloop schrijft hint-meet een verslag met actiepunten in `<KB>/meetings/` (uit te zetten met `--no-summary`).

Live bewaart het transcript in `logs/live-<datum>.txt`, in hetzelfde formaat als de testtranscripten: zet er `#! advies:`-regels onder en speel het af met `replay` om drempels te kalibreren.

Systeemaudio (Teams, Zoom, Meet, bellen via de Mac) vraagt [BlackHole](https://github.com/ExistentialAudio/BlackHole): `brew install --cask blackhole-2ch`, en in Audio MIDI-instellingen een apparaat voor meerdere uitgangen met je speakers én BlackHole, zodat je de meeting zelf ook blijft horen.

In de KB markeert een kopje met `[VERVALLEN]` die sectie als vervallen; hint-meet gebruikt zo'n passage alleen om te zeggen dát iets vervallen is.

## Providers

`PROVIDER` in `.env` kiest de beslissingslaag:

| Waarde      | Wat                                                                          |
| ----------- | ---------------------------------------------------------------------------- |
| `jev`     | TypeSafe Jev via de API (key nodig)                                          |
| `laya`    | Laya lokaal via `laya-serve`, zelfde endpoint, geen cloud-call             |
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
