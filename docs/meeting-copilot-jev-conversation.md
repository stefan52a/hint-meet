# Real-time meeting copilot with a knowledge base and Jev as decision layer

Conversation log, 4 October 2026. Questions by Stefan, answers by Claude. (Translated from Dutch.)

---

## 1. Question

> Is there software (for Mac) that records a meeting in real time and gives advice from a KB with an LLM and/or JEV (or something similar)?

## Answer

Yes, it exists. For a setup with your own knowledge base and an LLM of your choice, a few stand out.

**Open source, with your own KB (best fit)**

- **OpenOats**: closest to what you describe. Transcribes conversations locally and pulls relevant information from your personal knowledge base during the call. Works with local LLMs via Ollama or cloud models via OpenRouter, and indexes a folder of notes you choose with embeddings (an Obsidian vault works as is). Limitation: Apple Silicon with macOS 15+ only, installation via Homebrew or DMG.
- **Project Raven**: captures system audio and microphone at the same time via ScreenCaptureKit/CoreAudio, works with Claude or OpenAI, and supports RAG on local documents. Transcription via Deepgram (cloud). MIT license.
- **Natively**: open Cluely clone; can run fully offline with Ollama and local Whisper, with local RAG over earlier meetings via SQLite vector search. License: free for personal, educational and non-commercial use.
- **Meeting Copilot (Devleed)**: minimalist, in the terminal. Whisper transcription, suggestions via GPT-4o or Claude, documents (txt, pdf, docx) as context via RAG. A handy building block to extend yourself.

**Commercial, plug-and-play**

- **Hedy**: positioned as a meeting coach; speech recognition on-device on the Mac by default, optional local AI processing.
- **Convo**: Mac-only, real-time suggestions in Zoom, Meet and Teams, turns the meeting history into a searchable knowledge base. Cloud.

Recommendation: start with **OpenOats** (local, your own notes folder as KB, free choice of model); look at Raven or the Devleed repo to build your own.

Sources: OpenOats (SourcePulse), Project Raven (SourcePulse), Natively on GitHub, Devleed/meeting-copilot, Hedy (local meeting assistants for Mac), Convo (AlternativeTo, G2).

---

## 2. Question

> JEV is a decision AI model.

## Answer

Clear, TypeSafe's Jev. TypeSafe AI released Jev on 15 September 2026, together with 40 million dollars in funding led by DCVC. Ready-made meeting software that already integrates Jev doesn't exist yet; it's too new for that.

The combination fits well architecturally, though. Jev evaluates application state against typed questions and returns bounded choices, ordinal scores or yes/no probabilities with confidence in a single parallel pass, without generating free text. Answers take a fraction of a second and cost less than a cent. That's exactly the problem with real-time meeting advice: you don't want an expensive LLM call every few seconds just to decide *whether* there is anything to say.

**Logical setup: Jev as gatekeeper, LLM as advisor**

1. Local transcription (Whisper/Parakeet), in chunks of a few sentences.
2. Jev decides per chunk: should I intervene (yes/no + probability)? What kind of moment is this (objection, question to me, commitment, risk, incorrect statement)? Which KB collection is relevant?
3. Only above a threshold: RAG on the knowledge base plus an LLM (Claude) that phrases the advice.
4. Optionally afterwards: Jev scores per commitment whether it is an action item.

OpenOats already has that intermediate layer: layer 2 is a local heuristic gate that decides on finished utterances whether a suggestion is needed; layer 3 uses a fast model for streamed synthesis. Replacing that heuristic gate with a Jev call is a surgical change.

**Which base to fork?**

- **OpenOats**: best product and already has KB integration, but Swift; call the Jev API from Swift yourself.
- **Devleed/meeting-copilot**: Python, so the TypeSafe client can be used directly. Already has a delay parameter (FLUSH_WAIT_SECONDS) where the Jev check fits in. Fastest route to a prototype.

Caveats: the alias jev-latest can change behind your application, so log the returned version and pin a tested model. Calibrate the threshold on a few recorded meetings, or you get either spam or silence.

Sources: Eden AI (Jev, a new kind of AI model built for decisions), Runware (TypeSafe Jev), JEVQA (arXiv), Wavect (Jev AI review), OpenOats documentation, Devleed/meeting-copilot.

---

## 3. Question

> Research whether there are more solutions on GitHub that use JEV as the first decision layer.

## Answer

In short: a ready-made meeting copilot with Jev as the first decision layer doesn't exist anywhere, not on GitHub either. There is, however, a sizeable ecosystem (more than 1,200 indexed resources in the largest catalog) in which three categories are directly usable.

### 3.1 Speech/transcript plus Jev as gate (closest to the use case)

- **jev-voice-browser (moritzkremb)**: speech is streamed word by word to a Node server; on every partial transcription the server asks Jev a dozen typed questions in one request (intent, goal, "is the command complete?", "is this addressed to me?", "is it destructive?"), gets probabilities back in 250 to 350 ms, and code decides whether to act, wait, ask or ignore. Exactly the gate pattern, just for browser control. MIT, ~110 stars.
- **voice-gate (beejsbj)**: self-hosted Jev engine that classifies finished speech or typed text into ordinary speech, a command, a saved thought, uncertainty or no action. Official TypeSafe Python SDK, also via OpenRouter. On provider errors or ambiguous speech: "uncertainty".
- **convoai-jev-vad (Agora)**: replaces built-in start/end-of-speech detection: a cheap acoustic gate opens the turn, Jev reads the live transcript to decide when the user is really done and whether words over the agent are a real interruption or just "uh-huh". One Jev call per transcript update, ~2k input tokens, 200 to 400 ms.
- **jev-chat-jarvis**: Android reply copilot that judges intent, timing and risk based on screen text, while separate models do OCR and writing. ~1k stars.
- Also nice: **An always-on assistant with no wake word** (separates commands from ordinary conversation) and **slidepilot** (voice-controlled slide clicking).

### 3.2 Jev as gatekeeper before an LLM or KB (cascade pattern)

- **Inbox Zero**: seven separate e-mail decisions, each with its own threshold, fallback to the normal LLM on any error. Production code, ~10k stars.
- **Fraud detection with Jev and Kimi K3**: Jev classifies 100 e-mails in 1.42 seconds and passes the uncertain ones to Kimi K3.
- **LanceDB TypeSafeReranker**: one Noul per result, the yes-probability as an absolute relevance score, comparable across queries. Directly usable to filter KB passages before the LLM; TypeSafe has a cookbook for this that drops passages with hidden instructions.
- **triage-bot**: Jev routes a ticket to a specialist agent and decides whether a human should take over; Cerebras then writes the answer.

### 3.3 Local alternatives (no cloud call per transcript chunk)

- **Laya** (ConvAI, Apache 2.0): non-autoregressive, 421M parameters, ~1 GB memory, ~33 ms per decision, local, in 100+ languages. laya-serve offers a Jev-compatible POST /v1/systemone endpoint, so you can switch between Jev and Laya without code changes. Note: Laya is a fast base to specialize, not a zero-shot decision engine; it ships over-confident, although a temperature refit brings the ECE from 0.466 to 0.081.
- **Kev** (Jared Palmer), **jeff**, **decider**, **von**: Qwen- or GLiFormer-based reproductions; jeff works with the official SDK.
- **system-one-adapter-python** by TypeSafe itself: drop-in replacement for TypeSafeClient based on ordinary LLM APIs, so you can run Jev-shaped code without Jev access. Handy for testing gate logic against Claude first.

### 3.4 Two warnings from the catalog

The most honest source (kydlikebtc/awesome-jev) puts negative results first. Hermes Agent ported Jev compaction, measured it against their own summarizer and decided not to adopt it: recall was lower, although costs were much lower. The official list of known limitations literally mentions reading, arithmetic and counting, date comparison, indirection, large messy states and adversarial content. A ten-minute meeting transcript is exactly such a large, messy state; so keep the window small (last 2 or 3 turns) and only let Jev answer the "should I say something now, and what kind of moment is this" question.

### 3.5 Conclusion

Nobody has built the combination Whisper → Jev gate → KB RAG → Claude advice for meetings yet. The building blocks are ready: the question set of jev-voice-browser as a template for the gate, the Agora recipe for turn detection, the LanceDB reranker for KB filtering, and Laya as a local fallback. Whoever publishes this is probably the first in the catalogs.

Sources: kydlikebtc/awesome-jev, walidboulanouar/awesome-jev-use-cases, moritzkremb/jev-voice-browser, voice-gate (Glama), Agora convoai-jev-vad recipe, logicrw/awesome-jev-projects, Laya (Hugging Face, LLM Reference, BestHub), GitHub topic jev-model.

---

## 4. Question

> What can you build in one afternoon?

## Answer

A working prototype of the pipeline, not a finished Mac app.

**Delivered in one afternoon**

1. **Python project** (`meeting-gate/`) with four modules:
   - `transcribe.py`: faster-whisper on the microphone plus system audio via BlackHole, chunks of 5 to 8 seconds, rolling window of the last three turns.
   - `gate.py`: the Jev layer. One call per transcript chunk with questions in the style of jev-voice-browser: should I intervene (Noul), what kind of moment is this (Choice: question to me, objection, commitment, incorrect statement, risk, small talk), which KB collection is relevant (Choice), how urgent (Score). Thresholds in YAML.
   - `kb.py`: embeddings over a folder of markdown (an Obsidian vault fits directly), with a Jev reranker after the LanceDB pattern: one Noul per passage, only above 0.7 passes.
   - `advise.py`: Claude phrases the advice, at most three sentences, only when the gate is open.
2. **Provider switch**: `PROVIDER=jev | laya | adapter`. Laya locally via laya-serve on the same endpoint; `adapter` uses TypeSafe's system-one adapter for testing without a key.
3. **Overlay**: a simple always-on-top window (Tkinter or a small SwiftUI stub) that shows the advice.
4. **Replay mode**: `meeting-gate replay recording.wav` to calibrate thresholds on earlier meetings. Logs the Jev probabilities and chosen action per chunk to CSV.
5. README with installation (BlackHole, Ollama optional) and an explanation of the thresholds.

**What doesn't fit in an afternoon**

- Live testing of audio capture (not possible from the sandbox); the first real run is for Stefan, fixing errors in a second round.
- A polished native Mac app or installer.
- Jev calls without an API key; without a key it's built against the adapter and a mocked response.

**Needed from Stefan**

- A TypeSafe key or not (otherwise start on `adapter`).
- A folder with about twenty KB notes to test retrieval on; Dutch is fine.
- One recording or transcript of a real meeting for replay calibration.
- Language of the meetings: Dutch determines the Whisper model and Laya checkpoint (multilingual).

---

## 5. Question

> Also make a preparation tool that first converts the KB folder, containing docx, xlsx, pptx, pdf etc., to MD. Then make a complete .md of my questions and your answers.

## Answer

Built and tested: `kb_prep.py`, with `requirements-kb_prep.txt`.

**What it does**

- Walks a source folder recursively and converts to Markdown: `.docx` `.xlsx` `.xlsm` `.csv` `.pptx` `.pdf` `.html` `.htm` `.txt` `.md` `.json` `.rtf` (rtf via `textutil` on macOS).
- Keeps the folder structure under the destination folder; each file becomes `<name>.<ext>.md` with YAML front matter (source, type, sha1, modified, converted, number of characters).
- docx: headings, lists and tables; xlsx: each worksheet as a Markdown table (max 2,000 rows); pptx: per slide title, text, tables and speaker notes; pdf: text per page, optional OCR for scans (`--ocr`, requires pytesseract and tesseract).
- Skips files whose .md is already up to date (`--force` to overwrite).
- Writes `_index.json` in the destination folder, usable as input for the retriever in `kb.py`.

**Usage**

```
pip install -r requirements-kb_prep.txt
python kb_prep.py ~/KB ~/KB_md
python kb_prep.py ~/KB ~/KB_md --ocr --force
```

Tested on generated docx, xlsx, pptx, pdf, csv and txt: six out of six converted. This log is the requested .md file.

*(Later note: kb_prep has evolved since; see the README for its current behavior, such as the `.kb-hint-meet.md` suffix, the manifest instead of `_index.json`, and OCR on by default.)*

---

## Appendix: all sources

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
