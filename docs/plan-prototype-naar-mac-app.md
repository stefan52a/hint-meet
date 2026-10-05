# Plan: van prototype naar Mac-app

Concept, 5 oktober 2026. Testcase: het Acme-transactiedossier (`Finance/01-entities/AcmeBV/20260316oprichting/Acme van Globex naar Initech naar Acme BV`).

## Doel

Tijdens een meeting over een dossier (bijvoorbeeld met de accountant over de Acme-structuur) toont hint-meet op het juiste moment een kort advies met bronverwijzing. Voorbeelden:

- de accountant zegt "die software is toch € 650.000 waard" → *"Geldende prijs is € 400.000 (besluit 4-10). € 650.000 komt uit de vervallen ronde. Bron: 00-INDEX §4."*
- iemand vraagt naar de BTW op schakel 2 → *"Twijfelachtig onder 37d, steunt op Schriever. Vooroverleg nodig. Bron: 11-fiscaal-memo."*

En verder vooral: zwijgen als er niets nuttigs te zeggen is.

## Beslissingen (5-10-2026)

1. **Lokaal waar het kan.** Audio en transcriptie blijven op de Mac. Alleen het advies gaat naar Claude, met een paar zinnen transcript en de relevante passages. *Akkoord Stefan.*
2. **Elk advies heeft een bron.** Geen bron, dan geen advies. Zo kan de copilot geen bedragen verzinnen.
3. **Eerst tekst, dan audio, dan app.** Elke stap is te testen zonder de volgende.
4. **Testmateriaal:** een geschreven proefgesprek over Acme, met momenten waarop advies wel en niet hoort, later omgezet naar audio met twee macOS-stemmen. *Akkoord Stefan.*
5. **Jev als gate**, key komt in `.env`. De API-documentatie loop ik na aan het begin van M3; tot die tijd werkt de gate via dezelfde interface op Claude Haiku, zodat M2 niet hoeft te wachten.
6. **Drie soorten meetings:** online (Teams, Zoom, Meet), fysiek aan tafel, en bellen via de Mac. Online en bellen lopen via systeemaudio plus microfoon. Aan tafel is er alleen de microfoon, met meerdere sprekers erdoor; daar kan de gate niet op "wie zegt wat" leunen, dus de vragen aan Jev moeten ook zonder sprekerslabels werken.

## Mijlpalen

Elke mijlpaal eindigt met een checkpoint: ik laat het resultaat zien, jij beslist of we doorgaan.

### M1. Kennisbank Acme en zoeken (1 sessie)

**Stand 5-10-2026: geslaagd.** 41 stukken (38 vervallen of historische uitgesloten via `.kbignore`), 219 stukjes. Top 5: 20/20, MRR 0,81 (alleen embeddings 0,78, alleen BM25 0,64). Eén verwachting in de testset was te smal en is aangevuld (vraag "aandelen of een lening"). Zoeken ±20 ms per vraag, laden 0,8 s. Testset in `data/eval/acme-vragen.yaml`, nog na te kijken door Stefan.

- `kb_prep` op het dossier, met een `.kbignore` voor vervallen stukken en backups.
- `kb.py`: hybride zoeken. Embeddings (meertalig, lokaal) plus trefwoorden, omdat juist bedragen, artikelnummers (37d) en namen exact moeten matchen.
- **Testset:** 20 vragen met het juiste document erbij, door mij opgesteld uit het dossier, door jou nagekeken.
- **Geslaagd als:** het juiste document staat bij ≥ 18 van de 20 vragen in de top 5, en vervallen stukken komen nooit boven.

### M2. Pijplijn op tekst (1 sessie)

**Stand 5-10-2026: meetbaar geslaagd, oordeel Stefan open.** Proefgesprek van 50 beurten (4,5 min). Run 3: 10/10 momenten geraakt, 3 hints op ruis, hints ≤ 40 woorden. Latentie: gate ±1,1 s (Haiku) + advies ±3,8 s (Opus 5.5, effort low) = ±4,9 s, boven het M4-doel van 4 s; Jev als gate (M3) en streaming van het advies moeten dat oplossen. De drie "ruis"-hints zijn bevestigingsvragen aan Stefan (verkoopprijs, pandrecht) en een vraag naar de balans; of dat ruis is, beslist Stefan. Kernfeitencheck (53%) is te grof om op te sturen.

- Proefgesprek van ~15 minuten als transcript, met ~10 gemarkeerde momenten "hier hoort advies" en ruis daartussen.
- `hint-meet replay transcript.txt`: blok voor blok door gate → zoeken → advies, met een CSV-log per blok.
- **Geslaagd als:** ≥ 8 van de 10 momenten een advies krijgen, ≤ 3 adviezen op ruis, en elk advies klopt met de bron (door jou beoordeeld).

### M3. Jev als poortwachter (1 sessie)

**Stand 5-10-2026: geslaagd.** typesafe-sdk 0.7.2, model jev-1.13.0 (alias jev-latest; het werkelijke model wordt gelogd). Eén system_one-aanroep met een Noul (hint nodig), Choice (soort moment) en Score (urgentie); state = laatste 3 beurten, 3 passages en de net getoonde hint. Kalibratie (`hint-meet calibrate`, zonder advies, drie runs): Jev bij drempel 0,55 10/10 (één run 9/10) met 1 ruisbeurt; Haiku had bij zijn beste drempel 7 ruisbeurten. Volledige replay met Jev: 10/10 geraakt, 1 hint op ruis, gate ±250 ms. Marge is smal (zwakste moment 0,53–0,67, hoogste echte ruis 0,51–0,54) en de drempel is op hetzelfde transcript gekozen als waarop gemeten is: een tweede proefgesprek is nodig om dat te toetsen. Knelpunt is nu het advies: ±3,8 s.

- Jev-documentatie en SDK nalopen; provider `jev` bouwen naast `adapter` (Claude Haiku). Laya alleen als Jev tegenvalt of offline nodig is.
- Drempels kalibreren op het proefgesprek; vergelijken met de Haiku-gate op treffers, ruis, snelheid en kosten.
- **Geslaagd als:** Jev minstens zo goed scoort als Haiku, onder 0,5 s per blok.

### M4. Audio (1 tot 2 sessies)

**Stand 5-10-2026: geslaagd op het proefgesprek.** Proefgesprek uitgesproken met macOS-stemmen (stereo: links Stefan, rechts de ander). Silero VAD per kanaal (einde herkend na ±540 ms), Whisper large-v3-turbo via MLX (±380 ms per uitspraak, WER 3,0% met woordenlijst uit de KB). Advies op Sonnet 5.5 zonder thinking (besluit Stefan; Opus 5.5 gaf eerste woorden pas na ±4,3 s). Replay: 10/10 geraakt, 2 hints op ruis. Live in echte tijd (WAV als bron, met wachtrij): einde herkend → eerste woorden mediaan 1,9 s, max 2,4 s; met de VAD-wachttijd erbij ±2,5 s, max ±3,0 s. Fout ontdekt en verholpen: een niet-gemarkeerde vervallen sectie gaf vervallen bedragen; kopjes met `[VERVALLEN]` worden nu als vervallen aangeboden (review-naschrift aangepast met akkoord Stefan). Microfoon werkt; systeemaudio vraagt BlackHole. Nog open voor M5: hints die woord voor woord verschijnen en daarna als herhaling worden ingetrokken (flikkeren), en hints boven de 40 woorden.

- Transcriptie lokaal met Whisper (large-v3-turbo, Nederlands; via mlx op Apple Silicon).
- Microfoon plus systeemaudio. Voor de prototypefase via BlackHole; in de app via ScreenCaptureKit, dan is BlackHole niet meer nodig.
- Replay op WAV: het proefgesprek uitgesproken door twee macOS-stemmen.
- **Geslaagd als:** advies verschijnt binnen 4 s na het einde van de uitspraak, met dezelfde scores als M2.

### M5. Overlay (1 sessie)

**Stand 5-10-2026: gebouwd, visuele beoordeling door Stefan open.** Architectuur vooruitlopend op M6: de Python-pijplijn is een lokale WebSocket-server (`hint-meet live --ui`, 127.0.0.1:8765), de overlay een SwiftUI-app (`app/HintMeet`, `app/build-app.sh`). Zwevend paneel dat geen focus steelt (non-activating NSPanel, alle bureaubladen en fullscreen), groeit mee met de inhoud, onthoudt zijn plek; hint woord voor woord, daarna met bronknoppen (openen het oorspronkelijke dossierstuk) en 👍/👎 (naar `logs/feedback.jsonl`), ingetrokken hints doorgestreept met reden. Menubalk-icoon 💡. Na afloop een verslag (samenvatting, toezeggingen en actiepunten, open vragen) in `<KB>/meetings/`, bij testruns in `logs/`. Niet gezien op scherm: schermopname is voor deze sessie niet toegestaan; werking gecontroleerd via de vensterlijst (paneel zichtbaar, groeit 66 → 408 pt) en het protocol (tests).

- Klein venster altijd bovenop: advies, bron (klikbaar), en knoppen 👍/👎 die naar het log gaan voor latere kalibratie.
- Na afloop: lijst met toezeggingen en actiepunten.
- **Geslaagd als:** jij het in een echt gesprek gebruikt en het niet afleidt.

### M6. Mac-app (2 tot 3 sessies)

**Stand 5-10-2026, deel 1 klaar: menubalk-app die de pijplijn beheert.** Menu: status, meeting starten/stoppen, project kiezen (mappen in KB_ROOT), overlay tonen, instellingen, logboek. Instellingen: project, KB-map, microfoon, systeemaudio (BlackHole), verslag aan/uit, API-keys in de Keychain (gaan voor `.env`), pad van de projectmap. De app start `hint-meet live --ui` als kindproces met de `.venv` van deze map, stopt netjes via de overlay-verbinding (verslag komt nog) en stopt de pijplijn ook bij afsluiten van de app (getest: binnen 9 s, geen proces achtergebleven). Ad-hoc ondertekend met NSMicrophoneUsageDescription. Logboek in `~/Library/Logs/HintMeet/backend.log`.

**Deel 2, nog te doen (vraagt Apple Developer-account):** Python, MLX, modellen en pijplijn in de `.app` verpakken (werkt dan zonder deze projectmap), ondertekenen met Developer ID, notariseren, `.dmg`. Systeemaudio via ScreenCaptureKit in plaats van BlackHole.

- Menubalk-app in SwiftUI; de Python-pijplijn draait daarachter als lokaal proces.
- Projectkeuze (welke KB), start/stop, rechten voor microfoon en schermopname, instellingen (drempels, provider, keys in de Keychain).
- Ondertekend en genotariseerd `.app`/`.dmg`, zodat het zonder waarschuwingen installeert.
- **Geslaagd als:** installeren met dubbelklik, starten vanuit de menubalk, een meeting van een uur zonder crash.

## Risico's

| Risico | Gevolg | Aanpak |
|---|---|---|
| Jev-API anders dan beschreven of geen toegang | M3 schuift | gate werkt al op Haiku; Laya als lokale optie |
| Whisper mist vaktermen ("agio", "37d", "Initech") | verkeerde zoekvragen | woordenlijst uit de KB als prompt voor Whisper |
| Advies op basis van vervallen stuk | fout advies in een gevoelig gesprek | `.kbignore` + status uit de index meewegen; testvragen hierop |
| Vertrouwelijke stukken naar de cloud | privacy | alleen fragmenten naar Claude; optie volledig lokaal (Laya + lokaal model) later |
| Te veel adviezen | afleiding, uitgezet | drempels op het proefgesprek, 👍/👎 voor bijstellen |
| Mac-app-ondertekening | installatie lastig | Apple Developer-account nodig vóór M6 |

## Wat ik van jou nodig heb

- TypeSafe-key en Anthropic API-key in `.env`.
- Bij M2: het proefgesprek en de testvragen nakijken (inhoudelijk ken jij het dossier).
- Bij M6: een Apple Developer-account.
