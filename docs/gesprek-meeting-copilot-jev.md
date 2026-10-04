# Realtime meeting-copilot met kennisbank en Jev als beslissingslaag

Gespreksverslag, 4 oktober 2026. Vragen van Stefan, antwoorden van Claude.

---

## 1. Vraag

> Is er software (voor Mac) die realtime een meeting opneemt en met een KB adviezen geeft met een LLM en/of JEV (of iets vergelijkbaars)?

## Antwoord

Ja, die bestaan. Voor een setup met een eigen kennisbank en een LLM naar keuze springen er een paar uit.

**Open source, met eigen KB (meest passend)**

- **OpenOats**: komt het dichtst bij wat je beschrijft. Transcribeert gesprekken lokaal en haalt tijdens de call relevante informatie uit je persoonlijke kennisbank. Werkt met lokale LLM's via Ollama of cloudmodellen via OpenRouter, en indexeert met embeddings een map met notities die je zelf aanwijst (een Obsidian-vault kan er zo in). Beperking: alleen Apple Silicon met macOS 15+, installatie via Homebrew of DMG.
- **Project Raven**: vangt systeemaudio en microfoon tegelijk op via ScreenCaptureKit/CoreAudio, werkt met Claude of OpenAI, en ondersteunt RAG op lokale documenten. Transcriptie via Deepgram (cloud). MIT-licentie.
- **Natively**: open Cluely-kloon; draait desgewenst volledig offline met Ollama en lokale Whisper, met lokale RAG over eerdere meetings via SQLite-vectorsearch. Licentie: gratis voor persoonlijk, educatief en niet-commercieel gebruik.
- **Meeting Copilot (Devleed)**: minimalistisch, in de terminal. Whisper-transcriptie, suggesties via GPT-4o of Claude, documenten (txt, pdf, docx) als context via RAG. Handige bouwsteen om zelf uit te breiden.

**Commercieel, plug-and-play**

- **Hedy**: gepositioneerd als meeting-coach; spraakherkenning standaard on-device op de Mac, optionele lokale AI-verwerking.
- **Convo**: Mac-only, realtime suggesties bij Zoom, Meet en Teams, maakt van de meetinghistorie een doorzoekbare kennisbank. Cloud.

Aanbeveling: beginnen met **OpenOats** (lokaal, eigen notitiemap als KB, modelkeuze vrij); Raven of de Devleed-repo bekijken voor zelf bouwen.

Bronnen: OpenOats (SourcePulse), Project Raven (SourcePulse), Natively op GitHub, Devleed/meeting-copilot, Hedy (lokale meeting-assistenten voor Mac), Convo (AlternativeTo, G2).

---

## 2. Vraag

> JEV is een decision AI model.

## Antwoord

Helder, TypeSafe's Jev. TypeSafe AI bracht Jev uit op 15 september 2026, samen met 40 miljoen dollar aan funding onder leiding van DCVC. Kant-en-klare meetingsoftware die Jev al integreert bestaat nog niet; daarvoor is het te vers.

De combinatie past architectonisch wel goed. Jev evalueert applicatiestate tegen getypeerde vragen en geeft begrensde keuzes, ordinale scores of ja/nee-kansen met confidence terug in één parallelle pass, zonder vrije tekst te genereren. Antwoorden duren een fractie van een seconde en kosten minder dan een cent. Precies het probleem bij realtime meeting-advies: je wilt niet elke paar seconden een dure LLM-call doen alleen om te bepalen óf er iets te zeggen valt.

**Logische opzet: Jev als poortwachter, LLM als adviseur**

1. Transcriptie lokaal (Whisper/Parakeet), in blokjes van een paar zinnen.
2. Jev beslist per blok: moet ik ingrijpen (ja/nee + kans)? Wat voor moment is dit (bezwaar, vraag aan mij, toezegging, risico, onjuiste bewering)? Welke KB-collectie is relevant?
3. Alleen boven een drempel: RAG op de kennisbank plus een LLM (Claude) die het advies formuleert.
4. Optioneel na afloop: Jev scoort per toezegging of het een actiepunt is.

OpenOats heeft die tussenlaag al: laag 2 is een lokale heuristische gate die op afgeronde uitspraken bepaalt of een suggestie nodig is; laag 3 gebruikt een snel model voor gestreamde synthese. Die heuristische gate vervangen door een Jev-call is een chirurgische ingreep.

**Welke basis forken?**

- **OpenOats**: beste product en al KB-integratie, maar Swift; Jev-API zelf vanuit Swift aanroepen.
- **Devleed/meeting-copilot**: Python, dus de TypeSafe-client direct bruikbaar. Heeft al een vertragingsparameter (FLUSH_WAIT_SECONDS) waar de Jev-check tussen past. Snelste route naar een prototype.

Kanttekeningen: de alias jev-latest kan achter je applicatie veranderen, dus log de geretourneerde versie en pin een getest model. Kalibreer de drempel op een paar opgenomen meetings, anders krijg je óf spam óf stilte.

Bronnen: Eden AI (Jev, a new kind of AI model built for decisions), Runware (TypeSafe Jev), JEVQA (arXiv), Wavect (Jev AI review), OpenOats-documentatie, Devleed/meeting-copilot.

---

## 3. Vraag

> Research of er meer oplossingen zijn op GitHub die JEV als eerste beslissingslaag gebruiken.

## Antwoord

Kort: een kant-en-klare meeting-copilot met Jev als eerste beslissingslaag bestaat nergens, ook niet op GitHub. Wel een flink ecosysteem (meer dan 1.200 geïndexeerde resources in de grootste catalogus) waarin drie categorieën direct bruikbaar zijn.

### 3.1 Spraak/transcript plus Jev als gate (dichtst bij de use case)

- **jev-voice-browser (moritzkremb)**: spraak wordt woord voor woord gestreamd naar een Node-server; bij elke gedeeltelijke transcriptie stelt de server Jev in één request een dozijn getypeerde vragen (intentie, doel, "is het commando compleet?", "is dit aan mij gericht?", "is het destructief?"), krijgt kansen terug in 250 tot 350 ms, en code beslist of er gehandeld, gewacht, gevraagd of genegeerd wordt. Exact het gate-patroon, alleen op browserbediening. MIT, ~110 sterren.
- **voice-gate (beejsbj)**: zelfgehoste Jev-engine die afgeronde spraak of getypte tekst indeelt in gewone spraak, een commando, een bewaarde gedachte, onzekerheid of geen actie. Officiële TypeSafe Python SDK, ook via OpenRouter. Bij providerfouten of ambigue spraak: "onzekerheid".
- **convoai-jev-vad (Agora)**: vervangt ingebouwde start/eind-van-spraak-detectie: een goedkope akoestische gate opent de beurt, Jev leest het live transcript om te beslissen wanneer de gebruiker echt klaar is en of woorden over de agent heen een echte onderbreking zijn of alleen "uh-huh". Eén Jev-call per transcript-update, ~2k input tokens, 200 tot 400 ms.
- **jev-chat-jarvis**: Android reply-copilot die intentie, timing en risico beoordeelt op basis van schermtekst, terwijl aparte modellen OCR en het schrijven doen. ~1k sterren.
- Ook aardig: **An always-on assistant with no wake word** (scheidt commando's van gewone conversatie) en **slidepilot** (spraakgestuurd slides doorklikken).

### 3.2 Jev als poortwachter vóór een LLM of KB (cascade-patroon)

- **Inbox Zero**: zeven afzonderlijke e-mailbeslissingen, elk met eigen drempel, fallback naar de normale LLM bij elke fout. Productiecode, ~10k sterren.
- **Fraud detection met Jev en Kimi K3**: Jev classificeert 100 e-mails in 1,42 seconde en geeft de onzekere door aan Kimi K3.
- **LanceDB TypeSafeReranker**: één Noul per resultaat, de ja-kans als absolute relevantiescore, vergelijkbaar over queries. Direct inzetbaar om KB-passages te filteren vóór de LLM; TypeSafe heeft hier een cookbook voor dat passages met verborgen instructies laat afvallen.
- **triage-bot**: Jev routeert een ticket naar een specialist-agent en beslist of een mens het moet overnemen; Cerebras schrijft daarna het antwoord.

### 3.3 Lokale alternatieven (geen cloud-call per transcriptblok)

- **Laya** (ConvAI, Apache 2.0): non-autoregressief, 421M parameters, ~1 GB geheugen, ~33 ms per beslissing, lokaal, in 100+ talen. laya-serve biedt een Jev-compatibel POST /v1/systemone endpoint, dus wisselen tussen Jev en Laya zonder codewijziging. Let op: Laya is een snelle basis om te specialiseren, geen zero-shot beslissingsengine; wordt over-confident geleverd, al brengt een temperatuur-refit de ECE van 0,466 naar 0,081.
- **Kev** (Jared Palmer), **jeff**, **decider**, **von**: Qwen- of GLiFormer-gebaseerde reproducties; jeff is bruikbaar met de officiële SDK.
- **system-one-adapter-python** van TypeSafe zelf: drop-in vervanging van TypeSafeClient op basis van gewone LLM-API's, zodat je Jev-vormige code kunt draaien zonder Jev-toegang. Handig om gate-logica eerst tegen Claude te testen.

### 3.4 Twee waarschuwingen uit de catalogus

De eerlijkste bron (kydlikebtc/awesome-jev) zet negatieve resultaten vooraan. Hermes Agent portte Jev-compactie, mat het tegen hun eigen samenvatter en besloot het niet over te nemen: recall lag lager, al waren de kosten veel lager. De officiële lijst met bekende beperkingen noemt letterlijk lezen, rekenen en tellen, datumvergelijking, indirectie, grote rommelige states en adversariële inhoud. Een meetingtranscript van tien minuten is zo'n grote, rommelige state; houd het venster dus klein (laatste 2 à 3 beurten) en laat Jev alleen de "moet ik nu iets zeggen en wat voor soort moment is dit"-vraag doen.

### 3.5 Conclusie

Niemand heeft de combinatie Whisper → Jev-gate → KB-RAG → Claude-advies voor meetings al gebouwd. De bouwstenen liggen klaar: de vragenset van jev-voice-browser als sjabloon voor de gate, de Agora-recipe voor beurtdetectie, de LanceDB-reranker voor KB-filtering, en Laya als lokale fallback. Wie dit publiceert is vermoedelijk de eerste in de catalogi.

Bronnen: kydlikebtc/awesome-jev, walidboulanouar/awesome-jev-use-cases, moritzkremb/jev-voice-browser, voice-gate (Glama), Agora convoai-jev-vad recipe, logicrw/awesome-jev-projects, Laya (Hugging Face, LLM Reference, BestHub), GitHub topic jev-model.

---

## 4. Vraag

> Wat kan jij in 1 middag bouwen?

## Antwoord

Een werkend prototype van de pijplijn, geen afgewerkte Mac-app.

**Oplevering in één middag**

1. **Python-project** (`meeting-gate/`) met vier modules:
   - `transcribe.py`: faster-whisper op microfoon plus systeemaudio via BlackHole, blokjes van 5 tot 8 seconden, rolling window van de laatste drie beurten.
   - `gate.py`: de Jev-laag. Eén call per transcriptblok met vragen in de stijl van jev-voice-browser: moet ik ingrijpen (Noul), wat voor moment is dit (Choice: vraag aan mij, bezwaar, toezegging, onjuiste bewering, risico, smalltalk), welke KB-collectie is relevant (Choice), hoe dringend (Score). Drempels in YAML.
   - `kb.py`: embeddings over een map met markdown (Obsidian-vault past direct), met een Jev-reranker naar het LanceDB-patroon: één Noul per passage, alleen boven 0,7 door.
   - `advise.py`: Claude formuleert het advies, hooguit drie zinnen, alleen als de gate open is.
2. **Provider-switch**: `PROVIDER=jev | laya | adapter`. Laya lokaal via laya-serve op hetzelfde endpoint; `adapter` gebruikt TypeSafe's system-one-adapter voor testen zonder key.
3. **Overlay**: een simpel altijd-bovenop-venster (Tkinter of kleine SwiftUI-stub) dat het advies toont.
4. **Replay-modus**: `meeting-gate replay opname.wav` om drempels te kalibreren op eerdere meetings. Logt per blok de Jev-kansen en gekozen actie naar CSV.
5. README met installatie (BlackHole, Ollama optioneel) en uitleg van de drempels.

**Wat niet lukt in een middag**

- Live testen van audio-capture (niet mogelijk vanuit de sandbox); de eerste echte run is voor Stefan, fouten fixen in een tweede ronde.
- Gepolijste native Mac-app of installer.
- Jev-calls zonder API-key; zonder key wordt gebouwd tegen de adapter en een gemockte respons.

**Benodigd van Stefan**

- Wel of geen TypeSafe-key (anders start op `adapter`).
- Een map met circa twintig KB-notities om retrieval op te testen, mag Nederlands.
- Eén opname of transcript van een echte meeting voor replay-kalibratie.
- Taal van de meetings: Nederlands bepaalt Whisper-model en Laya-checkpoint (multilingual).

---

## 5. Vraag

> Maak ook een voorbereidingstool die de KB-map met o.a. docx, xlsx, pptx en pdf etc. bevat eerst omzet in MD. Maak dan een volledig .md van mijn vragen en jouw antwoorden.

## Antwoord

Gebouwd en getest: `kb_prep.py`, met `requirements-kb_prep.txt`.

**Wat het doet**

- Loopt recursief door een bronmap en zet om naar Markdown: `.docx` `.xlsx` `.xlsm` `.csv` `.pptx` `.pdf` `.html` `.htm` `.txt` `.md` `.json` `.rtf` (rtf via `textutil` op macOS).
- Behoudt de mappenstructuur onder de doelmap; elk bestand wordt `<naam>.<ext>.md` met YAML-frontmatter (bron, type, sha1, gewijzigd, geconverteerd, aantal tekens).
- docx: koppen, lijsten en tabellen; xlsx: elk werkblad als Markdown-tabel (max 2.000 rijen); pptx: per slide titel, tekst, tabellen en sprekersnotities; pdf: per pagina tekst, optioneel OCR voor scans (`--ocr`, vereist pytesseract en tesseract).
- Slaat bestanden over waarvan de .md al actueel is (`--force` om te overschrijven).
- Schrijft `_index.json` in de doelmap, bruikbaar als input voor de retriever in `kb.py`.

**Gebruik**

```
pip install -r requirements-kb_prep.txt
python kb_prep.py ~/KB ~/KB_md
python kb_prep.py ~/KB ~/KB_md --ocr --force
```

Getest op gegenereerde docx, xlsx, pptx, pdf, csv en txt: zes van zes omgezet. Dit verslag is het gevraagde .md-bestand.

---

## Bijlage: alle bronnen

- https://www.sourcepulse.org/projects/26415880 (OpenOats)
- https://www.sourcepulse.org/projects/26529598 (Project Raven)
- https://github.com/Natively-AI-assistant/natively-cluely-ai-assistant
- https://github.com/Devleed/meeting-copilot
- https://hedy.ai/pdf/posts/best-local-ai-meeting-assistants-mac.pdf
- https://alternativeto.net/software/convo--ai-meeting-assistant/about
- https://www.g2.com/sellers/convo-ai
- https://www.edenai.co/post/jev-a-new-kind-of-ai-model-built-for-decisions-not-conversation
- https://runware.ai/models/typesafe-jev
- https://arxiv.org/pdf/2609.24395 (JEVQA)
- https://wavect.io/blog/jev-ai-decision-model-review/
- https://docsearch.algolia.com/mcp/docs/repo/yazinsai/openoats
- https://github.com/kydlikebtc/awesome-jev
- https://github.com/walidboulanouar/awesome-jev-use-cases
- https://github.com/moritzkremb/jev-voice-browser/wiki
- https://glama.ai/mcp/servers/w46snebivh (voice-gate)
- https://raw.githubusercontent.com/AgoraIO-Community/convoai-jev-vad/main/recipe/README.md
- https://github.com/logicrw/awesome-jev-projects/wiki
- https://huggingface.co/convaiinnovations/laya
- https://www.llmreference.com/model/laya
- https://www.besthub.dev/articles/laya-open-source-decision-engine-beats-jev-7-8x-faster-3-9-more-accurate-be86888d4cab
- https://github.com/topics/jev-model
