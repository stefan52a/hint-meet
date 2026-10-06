# Changelog

Wat er voor de gebruiker verandert, nieuwste bovenaan. De technische details staan in `git log`.

## 2026-10-06

### App

- **Transcript naast de hint:** links het scrollbare transcript van de meeting, rechts de hint. De uitspraak waarop de getoonde hint reageert staat in vet wit op een lichtrode achtergrond; uitspraken met een hint hebben een 💡 (klik om die hint te tonen). Het transcript volgt live de nieuwste uitspraak en springt bij terugbladeren naar de uitspraak van die hint. Bij een smal paneel staat het transcript onder de hint; de standaardbreedte is 760 punten.
- Scrollen door het transcript laat de hint meebewegen: rechts staat de hint van de uitspraak met 💡 die het dichtst bij het midden staat. Helemaal onderaan ben je weer live. Scroll je omhoog, dan trekken nieuwe uitspraken je niet meer naar beneden.
- De app is Engelstalig: menu's, knoppen, meldingen en de voortgang van Load KB en Convert Documents. Hints en verslagen blijven Nederlands.
- Het veld *Met wie?* heet nu **Meeting info** (bijvoorbeeld met wie en waar). Die tekst komt in de naam van het verslag: `2026-10-06-104736-Finance-Jan Jansen, Utrecht.md`.
- **Geschiedenis van hints:** blader met ◀ ▶ boven de hint (of ⌘[ en ⌘] in het menu Meeting) terug door de hints van deze meeting, met tijdstip en de uitspraak waarop de hint reageerde. *Latest* brengt je terug; nieuwe hints komen binnen zonder dat je je plek verliest.
- De menubalk linksboven komt terug als je buiten een meeting op het paneel klikt (HintMeet wordt dan de actieve app). Tijdens een meeting doet een klik op de kopbalk van het paneel (hint-meet · project) dat ook; klikken op hints, ◀ ▶, 👍 en het transcript laten de focus bij de meeting-app.

### Documentatie

- README begint met wat HintMeet doet, waarvoor je het gebruikt en hoe.

## 2026-10-05

### Overlay

- Hints zijn puntsgewijs: 1 tot 4 korte punten (samen hooguit 40 woorden), met het antwoord of wat je kunt zeggen als eerste punt, in plaats van een alinea proza.
- De hint met wat je kunt zeggen staat altijd bovenaan: groter (19 pt), vet en in een gekleurd vak met een accentbalk.
- Een ingetrokken hint neemt die plek niet meer over. Hij verschijnt ongeveer 6 seconden als klein grijs regeltje met de reden, en daarna krimpt het paneel weer.
- Eerdere hints en de laatste uitspraak staan in een iets grotere letter.
- Het paneel is te vergroten met de greep rechtsonder (drie schuine streepjes). De maat wordt onthouden; **Overlay standaardgrootte** in het 💡-menu zet hem terug. Het paneel blijft binnen het scherm.
- Invoerveld **Met wie?** in het paneel (buiten een meeting). Het verslag heet dan bijvoorbeeld `2026-10-05-104736-Finance-met-Jan Jansen.md`; zonder naam `…-Finance-gesprek.md`.
- HintMeet is een gewone app met icoon in `~/Applications`: te starten via Spotlight, Launchpad of het Dock. `app/build-app.sh` installeert hem daar.
- **Documenten omzetten (kb_prep)…** in het 💡-menu: kies een bronmap en projectnaam, met de opties *Alles opnieuw omzetten* (`--force`) en *Zonder OCR* (`--no-ocr`). Voortgang per bestand en per pagina, Stop, en na afloop de samenvatting en het logboek. Het venster mag dicht; het omzetten loopt door. De projectnaam volgt standaard de laatste mapnaam van de bronmap, tot je hem zelf aanpast.
- De logboeken van KB laden en Documenten omzetten bevatten alleen nog leesbare regels (✓, ⚠, ✗, samenvatting), zonder de voortgangsregels voor de balk.
- HintMeet heeft een gewone menubalk linksboven (HintMeet, Bewerk, Meeting, Kennisbank, Venster, Help) en een Dock-icoon; het 💡-menu rechtsboven blijft. Nieuw daarin: **KB laden** (⌘L). Klik op het Dock-icoon toont het paneel. Knippen en plakken werkt nu ook in het veld *Met wie?*.
- Loopt er al een kb_prep op dezelfde kennisbank, dan zegt de melding welke (sinds wanneer, vanuit de terminal of HintMeet, welke bron, welk proces) in plaats van "mislukt (code 3)". KB laden gaat dan door met de KB zoals hij is en waarschuwt dat de documenten niet zijn bijgewerkt.
- Meerdere projecten tegelijk als kennisbank: vink ze aan in het paneel, in Instellingen of in het 💡-menu. Ze worden samen doorzocht; bronnen krijgen de projectnaam ervoor (`acme/offerte.pdf`). Het verslag komt bij het eerste project, met alle namen in de bestandsnaam (`…-Finance+acme-met-….md`).
- Knop **KB laden** naast de Kennisbank-keuze: werkt de documenten bij uit de bronmap (kb_prep), indexeert de KB en laadt de spraakherkenning, met voortgangsbalk en Stop. Daarna start een meeting snel. Stoppen bewaart wat klaar is.
- Stappen zonder eigen voortgang tonen een schatting op basis van de vorige keer ("nog ~20 s (schatting)"); alleen de allereerste keer een wieltje.
- De woordindex van de KB wordt bewaard (`.hint-meet-cache/bm25-v1.npz`): bij Finance laadt de KB in ~11 s in plaats van ruim een minuut, en zoeken tijdens een meeting is veel sneller.
- **HintMeet herstarten** in het 💡-menu (⌘R): start de nieuwste build opnieuw; het gekozen project blijft staan, er start geen meeting.
- Afsluiten, herstarten en Meeting stoppen wachten tot het verslag klaar is, zonder tijdslimiet. Het paneel toont intussen een wieltje met de stap (transcript opslaan, verslag maken) en de verstreken tijd, met **Nu afbreken** als het blijft hangen.

### kb_prep

- Nieuwe bestandstypen: `.doc` en `.odt` (via textutil), `.xls` (ook "xls"-exports die eigenlijk html zijn), `.mht`/`.mhtml` webarchieven, en `.gif`/`.bmp` via OCR. Bij Finance zijn dat ruim 1.400 extra bestanden.
- HTML wordt zonder de inhoud van scripts en stijlen omgezet; bestaande `.html`-schaduwbestanden worden daarom één keer opnieuw gemaakt.
- Bronbestanden met een heel lange naam kunnen weer worden omgezet. De naam van het schaduwbestand wordt dan ingekort, met een hash erachter.
- Wachtwoorden voor beveiligde PDF's in `.kbpasswords` in de bronmap (zie README).
- `node_modules`, verborgen mappen (`.git`, `.venv`) en build-mappen naast een projectbestand worden overgeslagen.
- Robuuster bij lastige bestanden: Word-bestanden met ingesloten fonts of WMF/EMF-plaatjes, heel hoge scans (OCR in stroken) en JSON met commentaar.
- Duidelijke meldingen voor bestanden die alleen nullen bevatten (zoals kapotte Dropbox-conflictkopieën), voor een `.xlsx` die eigenlijk een ander formaat heeft, en voor PDF's waarvan het wachtwoord ontbreekt.
- Een map die niet te lezen is, laat zijn bestaande schaduwbestanden staan in plaats van ze op te ruimen.
