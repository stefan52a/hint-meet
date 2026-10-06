# Plan: from prototype to Mac app

Draft, 5 October 2026. Test case: the Acme transaction dossier (`Finance/01-entities/AcmeBV/20260316oprichting/Acme van Globex naar Initech naar Acme BV`). (Translated from Dutch.)

## Goal

During a meeting about a dossier (for example with the accountant about the Acme structure), hint-meet shows a short piece of advice with a source reference at the right moment. Examples:

- the accountant says "that software is worth € 650,000, isn't it" → *"Current price is € 400,000 (decision 4-10). € 650,000 comes from the superseded round. Source: 00-INDEX §4."*
- someone asks about the VAT on link 2 → *"Doubtful under 37d, relies on Schriever. Prior consultation needed. Source: 11-fiscaal-memo."*

And above all: stay silent when there's nothing useful to say.

## Decisions (5-10-2026)

1. **Local where possible.** Audio and transcription stay on the Mac. Only the advice goes to Claude, with a few sentences of transcript and the relevant passages. *Agreed by Stefan.*
2. **Every piece of advice has a source.** No source, no advice. That way the copilot can't make up amounts.
3. **Text first, then audio, then app.** Each step can be tested without the next.
4. **Test material:** a written test conversation about Acme, with moments where advice does and doesn't belong, later turned into audio with two macOS voices. *Agreed by Stefan.*
5. **Jev as gate**, the key goes in `.env`. I check the API documentation at the start of M3; until then the gate works through the same interface on Claude Haiku, so M2 doesn't have to wait.
6. **Three kinds of meetings:** online (Teams, Zoom, Meet), in person at the table, and calls via the Mac. Online and calls go through system audio plus microphone. At the table there is only the microphone, with several speakers through it; there the gate can't rely on "who says what", so the questions to Jev must also work without speaker labels.

## Milestones

Each milestone ends with a checkpoint: I show the result, you decide whether we continue.

### M1. Acme knowledge base and search (1 session)

**Status 5-10-2026: passed.** 41 documents (38 superseded or historical excluded via `.kbignore`), 219 chunks. Top 5: 20/20, MRR 0.81 (embeddings only 0.78, BM25 only 0.64). One expectation in the test set was too narrow and was extended (question "shares or a loan"). Search ±20 ms per question, loading 0.8 s. Test set in `data/eval/acme-vragen.yaml`, still to be reviewed by Stefan.

- `kb_prep` on the dossier, with a `.kbignore` for superseded documents and backups.
- `kb.py`: hybrid search. Embeddings (multilingual, local) plus keywords, because amounts, article numbers (37d) and names in particular must match exactly.
- **Test set:** 20 questions with the right document, drafted by me from the dossier, reviewed by you.
- **Passes if:** the right document is in the top 5 for ≥ 18 of the 20 questions, and superseded documents never come out on top.

### M2. Pipeline on text (1 session)

**Status 5-10-2026: measurably passed, Stefan's judgment open.** Test conversation of 50 turns (4.5 min). Run 3: 10/10 moments hit, 3 hints on noise, hints ≤ 40 words. Latency: gate ±1.1 s (Haiku) + advice ±3.8 s (Opus 5.5, effort low) = ±4.9 s, above the M4 target of 4 s; Jev as gate (M3) and streaming the advice should solve that. The three "noise" hints are confirmation questions to Stefan (sale price, pledge) and a question about the balance sheet; whether that is noise is for Stefan to decide. The key-facts check (53%) is too coarse to steer by.

- Test conversation of ~15 minutes as a transcript, with ~10 marked moments "advice belongs here" and noise in between.
- `hint-meet replay transcript.txt`: chunk by chunk through gate → search → advice, with a CSV log per chunk.
- **Passes if:** ≥ 8 of the 10 moments get advice, ≤ 3 pieces of advice on noise, and every piece of advice matches its source (judged by you).

### M3. Jev as gatekeeper (1 session)

**Status 5-10-2026: passed.** typesafe-sdk 0.7.2, model jev-1.13.0 (alias jev-latest; the actual model is logged). One system_one call with a Noul (hint needed), Choice (kind of moment) and Score (urgency); state = last 3 turns, 3 passages and the hint just shown. Calibration (`hint-meet calibrate`, without advice, three runs): Jev at threshold 0.55 10/10 (one run 9/10) with 1 noise turn; Haiku at its best threshold had 7 noise turns. Full replay with Jev: 10/10 hit, 1 hint on noise, gate ±250 ms. The margin is narrow (weakest moment 0.53–0.67, highest real noise 0.51–0.54) and the threshold was chosen on the same transcript it was measured on: a second test conversation is needed to check that. The bottleneck is now the advice: ±3.8 s.

- Go through the Jev documentation and SDK; build provider `jev` next to `adapter` (Claude Haiku). Laya only if Jev disappoints or offline is needed.
- Calibrate thresholds on the test conversation; compare with the Haiku gate on hits, noise, speed and cost.
- **Passes if:** Jev scores at least as well as Haiku, under 0.5 s per chunk.

### M4. Audio (1 to 2 sessions)

**Status 5-10-2026: passed on the test conversation.** Test conversation spoken with macOS voices (stereo: Stefan left, the other right). Silero VAD per channel (end detected after ±540 ms), Whisper large-v3-turbo via MLX (±380 ms per utterance, WER 3.0% with a vocabulary from the KB). Advice on Sonnet 5.5 without thinking (Stefan's decision; Opus 5.5 gave first words only after ±4.3 s). Replay: 10/10 hit, 2 hints on noise. Live in real time (WAV as source, with queue): end detected → first words median 1.9 s, max 2.4 s; including the VAD wait ±2.5 s, max ±3.0 s. Bug found and fixed: an unmarked superseded section gave superseded amounts; headings with `[VERVALLEN]` are now presented as superseded (review postscript adjusted with Stefan's agreement). Microphone works; system audio needs BlackHole. Still open for M5: hints that appear word by word and are then retracted as a repeat (flickering), and hints over 40 words.

- Local transcription with Whisper (large-v3-turbo, Dutch; via mlx on Apple Silicon).
- Microphone plus system audio. For the prototype phase via BlackHole; in the app via ScreenCaptureKit, so BlackHole is no longer needed.
- Replay on WAV: the test conversation spoken by two macOS voices.
- **Passes if:** advice appears within 4 s after the end of the utterance, with the same scores as M2.

### M5. Overlay (1 session)

**Status 5-10-2026: built, visual review by Stefan open.** Architecture ahead of M6: the Python pipeline is a local WebSocket server (`hint-meet live --ui`, 127.0.0.1:8765), the overlay a SwiftUI app (`app/HintMeet`, `app/build-app.sh`). Floating panel that doesn't steal focus (non-activating NSPanel, all desktops and full screen), grows with its content, remembers its position; hint word by word, then with source buttons (open the original dossier document) and 👍/👎 (to `logs/feedback.jsonl`), retracted hints struck through with a reason. Menu bar icon 💡. Afterwards a report (summary, commitments and action items, open questions) in `<KB>/meetings/`, for test runs in `logs/`. Not seen on screen: screen recording isn't allowed for this session; behavior checked via the window list (panel visible, grows 66 → 408 pt) and the protocol (tests).

- Small window always on top: advice, source (clickable), and buttons 👍/👎 that go to the log for later calibration.
- Afterwards: a list of commitments and action items.
- **Passes if:** you use it in a real conversation and it doesn't distract.

### M6. Mac app (2 to 3 sessions)

**Status 5-10-2026, part 1 done: menu bar app that manages the pipeline.** Menu: status, start/stop meeting, choose project (folders in KB_ROOT), show overlay, settings, log. Settings: project, KB folder, microphone, system audio (BlackHole), report on/off, API keys in the Keychain (take precedence over `.env`), path of the project folder. The app starts `hint-meet live --ui` as a child process with the `.venv` of this folder, stops cleanly via the overlay connection (report still comes) and also stops the pipeline when the app quits (tested: within 9 s, no process left behind). Ad-hoc signed with NSMicrophoneUsageDescription. Log in `~/Library/Logs/HintMeet/backend.log`.

**Part 2, still to do (needs an Apple Developer account):** package Python, MLX, models and pipeline into the `.app` (then works without this project folder), sign with Developer ID, notarize, `.dmg`. System audio via ScreenCaptureKit instead of BlackHole.

- Menu bar app in SwiftUI; the Python pipeline runs behind it as a local process.
- Project choice (which KB), start/stop, permissions for microphone and screen recording, settings (thresholds, provider, keys in the Keychain).
- Signed and notarized `.app`/`.dmg`, so it installs without warnings.
- **Passes if:** installing with a double click, starting from the menu bar, a one-hour meeting without a crash.

## Risks

| Risk | Consequence | Approach |
|---|---|---|
| Jev API different from described or no access | M3 slips | gate already works on Haiku; Laya as a local option |
| Whisper misses domain terms ("agio", "37d", "Initech") | wrong search queries | vocabulary from the KB as a prompt for Whisper |
| Advice based on a superseded document | wrong advice in a sensitive conversation | `.kbignore` + weigh status from the index; test questions on this |
| Confidential documents to the cloud | privacy | only fragments to Claude; fully local option (Laya + local model) later |
| Too much advice | distraction, gets turned off | thresholds on the test conversation, 👍/👎 for adjusting |
| Mac app signing | installation difficult | Apple Developer account needed before M6 |

## What I need from you

- TypeSafe key and Anthropic API key in `.env`.
- At M2: review the test conversation and the test questions (you know the dossier's content).
- At M6: an Apple Developer account.
