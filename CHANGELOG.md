# Changelog

Wat er voor de gebruiker verandert, nieuwste bovenaan. De technische details staan in `git log`.

## 2026-10-05

### Overlay

- De hint met wat je kunt zeggen staat altijd bovenaan: groter (19 pt), vet en in een gekleurd vak met een accentbalk.
- Een ingetrokken hint neemt die plek niet meer over. Hij verschijnt ongeveer 6 seconden als klein grijs regeltje met de reden, en daarna krimpt het paneel weer.
- Eerdere hints en de laatste uitspraak staan in een iets grotere letter.
- Het paneel is te vergroten met de greep rechtsonder (drie schuine streepjes). De maat wordt onthouden; **Overlay standaardgrootte** in het 💡-menu zet hem terug. Het paneel blijft binnen het scherm.
- Invoerveld **Met wie?** in het paneel (buiten een meeting). Het verslag heet dan bijvoorbeeld `2026-10-05-104736-Finance-met-Jan Jansen.md`; zonder naam `…-Finance-gesprek.md`.
- HintMeet is een gewone app met icoon in `~/Applications`: te starten via Spotlight, Launchpad of het Dock. `app/build-app.sh` installeert hem daar.
- Meerdere projecten tegelijk als kennisbank: vink ze aan in het paneel, in Instellingen of in het 💡-menu. Ze worden samen doorzocht; bronnen krijgen de projectnaam ervoor (`acme/offerte.pdf`). Het verslag komt bij het eerste project, met alle namen in de bestandsnaam (`…-Finance+acme-met-….md`).
- Knop **KB laden** naast de Kennisbank-keuze: werkt de documenten bij uit de bronmap (kb_prep), indexeert de KB en laadt de spraakherkenning, met voortgangsbalk en Stop. Daarna start een meeting snel. Stoppen bewaart wat klaar is.
- Stappen zonder eigen voortgang tonen een schatting op basis van de vorige keer ("nog ~20 s (schatting)"); alleen de allereerste keer een wieltje.
- De woordindex van de KB wordt bewaard (`.hint-meet-cache/bm25-v1.npz`): bij Finance laadt de KB in ~11 s in plaats van ruim een minuut, en zoeken tijdens een meeting is veel sneller.
- **HintMeet herstarten** in het 💡-menu (⌘R): start de nieuwste build opnieuw; het gekozen project blijft staan, er start geen meeting.
- Afsluiten, herstarten en Meeting stoppen wachten tot het verslag klaar is, zonder tijdslimiet. Het paneel toont intussen een wieltje met de stap (transcript opslaan, verslag maken) en de verstreken tijd, met **Nu afbreken** als het blijft hangen.

### kb_prep

- Bronbestanden met een heel lange naam kunnen weer worden omgezet. De naam van het schaduwbestand wordt dan ingekort, met een hash erachter.
- Wachtwoorden voor beveiligde PDF's in `.kbpasswords` in de bronmap (zie README).
- `node_modules`, verborgen mappen (`.git`, `.venv`) en build-mappen naast een projectbestand worden overgeslagen.
- Robuuster bij lastige bestanden: Word-bestanden met ingesloten fonts of WMF/EMF-plaatjes, heel hoge scans (OCR in stroken) en JSON met commentaar.
- Duidelijke meldingen voor bestanden die alleen nullen bevatten (zoals kapotte Dropbox-conflictkopieën), voor een `.xlsx` die eigenlijk een ander formaat heeft, en voor PDF's waarvan het wachtwoord ontbreekt.
- Een map die niet te lezen is, laat zijn bestaande schaduwbestanden staan in plaats van ze op te ruimen.
