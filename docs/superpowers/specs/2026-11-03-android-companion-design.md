# Android companion: design

Status: draft, 2026-11-03. For Stefan only (single user).

## Intent

Stefan wants HintMeet's hints in meetings where his Mac isn't in the room. The case that started this: a two-hour
VvE (owners' association) meeting, Mac at home on Wi-Fi, Stefan at the meeting with only his Android phone.

The phone lies **open on the table, screen on, on a charger**. It records the room with its microphone and streams
the audio over the internet to the Mac at home. The Mac does what it already does (Whisper, gate, KB search, rerank,
Claude) and sends the hints back to the phone. **Hints are what matters**: fast, large, readable from the table.
Transcript and document search are secondary.

## Goals

- Start a meeting from the phone, away from home: choose project(s), language, optionally "with whom, where".
- Two hours of uninterrupted recording from the phone, also when the screen dims or a notification comes in.
- Hints appear on the phone within the same latency as on the Mac (target: < 1 s extra over the network).
- A network dropout (train, basement, switching Wi-Fi ↔ 4G) loses no audio up to a buffered limit and recovers
  without user action.
- Stop from the phone; the report is written as usual and the phone shows it when ready.

## Non-goals (v1)

- Other users, other people's Macs, Play Store distribution. The APK is sideloaded on Stefan's phone.
- iOS.
- Running anything (Whisper, KB, models) on the phone. The phone is microphone + screen.
- Opening original source documents on the phone. Sources are shown as their reference text only.
- Document search (⌘F) and voice enrollment from the phone.
- Audio compression (Opus). Raw PCM is ~32 KB/s, ~230 MB per two hours; acceptable on 4G
  for now (Opus would bring it to ~15 MB, a later improvement).

## Anti-goals (a failure even if it technically works)

- The recording silently stops halfway (Android kills the app, the Mac falls asleep) and Stefan only finds out
  afterwards. Any loss of the audio path must be visible on the phone immediately.
- The Mac at home becomes reachable from the internet in general. Only Stefan's own devices may reach it.
- A meeting running on the Mac at home with nobody able to stop it (phone lost or out of battery). There must be a
  timeout.
- The hints screen is busy or small: it has to be readable at a glance from a phone lying flat on a table.

## Constraints and facts from the current code

- The pipeline (`hint-meet live --ui`) is started by HintMeet.app as a child process
  (`app/HintMeet/Sources/HintMeet/Backend.swift`, args built around line 151). Its WebSocket server
  (`src/hint_meet/server.py`, `Hub`) binds `127.0.0.1:8765`, requires a token
  (`~/Library/Application Support/hint-meet/ws-token`) and **only exists while a meeting runs**. So remote start needs
  something that is always listening: the menu-bar app.
- `Hub` replays the full meeting (hello + backlog) to a client that (re)connects. The phone reuses this for
  reconnects.
- Audio sources live in `src/hint_meet/live.py` (`DeviceSource`, `WavSource`): each pushes `Block(channel, samples,
  t)` at 16 kHz mono float32, frames of `audio.FRAME`. A single microphone gets label `"Unknown"`
  (`cli.mic_label`), which makes `speakers.py` tell speakers apart by voice print. The phone source behaves the same.
- `AudioRecorder` saves meeting audio and keeps channels aligned; with one channel this is trivial.
- The overlay protocol (top of `server.py`) is the contract for the phone UI: `hello`, `utterance`, `hint`
  (streaming/final/retracted), `confirm`, `status`, `summary`, `audio`, `api_error`, `stopped`; client →
  server `feedback`, `stop`, `language`, `rename`, `say`, `sensitivity`.
- The Mac at home must stay awake and on the network for two hours. A MacBook with the lid closed sleeps unless
  in clamshell mode with an external display. **The Mac must be on power with the lid open, or be a desktop.**
- Per project rules: CHANGELOG.md updated with every user-visible change; commits in English; never `git add -A`;
  never hard-restart HintMeet while a meeting runs.

## Decided

Stefan agreed with these (2026-11-03):

- Native Android app, Kotlin. A web page would be killed by Android while recording in the background.
- Connection via **Tailscale** (on Mac and phone). No port forwarding, traffic encrypted by WireGuard.
- HintMeet.app gets a **remote mode** that accepts the phone.
- The pipeline gets a third audio source next to microphone and BlackHole: **audio from the phone**.
- v1 scope as in Goals / Non-goals above.

## Design

### Overview

```
Android phone                         Mac at home (HintMeet.app always running in the menu bar)
─────────────                         ───────────────────────────────────────────────────────────
mic ─► foreground service             Companion gateway (Swift, in HintMeet.app)
       PCM16 16 kHz, seq-numbered       bound to the Tailscale address only, phone token
       ring buffer for resend           │ control: list projects, start, stop, status
            │                           │ proxies to the pipeline once it runs:
            └── WebSocket over Tailscale ┤   events  ◄── Hub (127.0.0.1:8765), unchanged protocol
                                         │   audio   ──► PhoneSource in the pipeline
hints screen ◄──────────────────────────┘
```

### Mac: pipeline (`src/hint_meet`)

- New `PhoneSource` in `live.py`, next to `DeviceSource`. It receives audio frames and pushes `Block("Unknown",
  …)` like a single microphone. Frame format on the wire: binary WebSocket message = 8-byte header
  (uint32 sequence number, uint32 sample offset, little-endian) + PCM16 mono 16 kHz samples.
- Gap handling: frames arrive in order per connection; after a reconnect the phone resends from the last
  acknowledged sequence number. Duplicates are dropped. A gap the phone could no longer fill (buffer overrun) is
  filled with silence of the right length so timestamps and the recording stay correct, and a `status` message says
  how many seconds were lost.
- The source acknowledges received frames (a small JSON `{"type": "audio_ack", "seq": n}` every ~1 s) so the phone
  can trim its buffer.
- New CLI flag `hint-meet live --phone` (instead of `--mic/--system`). Where the audio frames reach the pipeline is
  the builder's call: either the existing `Hub` accepts binary messages on the same socket, or a second localhost
  port. The gateway hides the difference from the phone.
- **Timestamps from the stream, not from arrival** (Claude's call). `Block.t` is derived from the header's sample
  offset (meeting start + offset / 16000), not `time.monotonic()` at arrival. Audio resent after a dropout is then
  older than `STALE_MS` and goes to the transcript and the report only: no gate, rerank or Claude calls for things
  said minutes ago, no flood of outdated hints after a reconnect. Live audio behaves as today.
- Silence watchdog: if no audio frames arrive for **30 minutes** (longer than the phone's 10-minute buffer, so a
  dropout the buffer can cover never ends the meeting), the pipeline stops the meeting as if Stop was pressed
  (report still written). Covers a lost or dead phone. (Claude's call.)

### Mac: companion gateway (in HintMeet.app)

- Settings → new section **Phone**: switch "Allow phone companion" (off by default), shows a **pairing QR code**
  (Tailscale address, port, phone token), button "New pairing" (revokes the old token).
- When enabled, the gateway listens **only on the Mac's Tailscale address** (100.x.y.z), not on all interfaces. If
  Tailscale isn't running, the section says so and the gateway doesn't start.
- Phone token: separate from the overlay token, 32+ random bytes, stored in the Keychain.
- Control messages (JSON): `projects` (list, same source as the project menu), `start` (projects, language,
  info → Backend starts `live --ui --phone` with the existing settings for report/audio saving), `stop`,
  `state` (idle / starting / running / stopping, plus KB-loading progress if the KB isn't preloaded).
- Once the pipeline runs, the gateway proxies the event stream unchanged (including backlog replay) and forwards
  audio frames and acks.
- Keep-awake: while the switch is on and the Mac is on power, the app holds an IOKit power assertion that prevents
  idle system sleep. The Settings section states the lid/power constraint in one line.
- Starting a meeting from the phone while one is already running on the Mac: refuse with a clear message.
- **Meeting ID** (Claude's call): the gateway gives each phone meeting an ID and reports it in `state`. A phone
  that reconnects (after a dropout or an app restart) rejoins the running meeting by that ID.
- **Last result** (Claude's call): `state` also carries the last meeting's outcome (stopped by user / by watchdog,
  report path and Markdown when ready), read from `logs/live-….meta.json` the way `PendingReports.swift` already
  does. A phone that wasn't connected when `summary` went out still gets the report, also after the pipeline exited.

### Android app

- Kotlin, Jetpack Compose, OkHttp WebSocket. minSdk 29 (Android 10); foreground service type `microphone`
  (required from Android 14). Sideloaded APK, debug signing is fine.
- **Pairing screen**: scan the QR code from the Mac's Settings. Stored in EncryptedSharedPreferences.
- **Start screen**: Mac reachable yes/no, project picker (multi-select), language, "with whom, where", Start.
  If the KB isn't preloaded, show the progress from `state` before recording begins.
- **Meeting screen** (the one that matters):
  - The latest hint large, filling most of the screen; streaming text word by word; sources as small reference text
    below; 👍/👎. Swipe or ◀ ▶ for earlier hints. Retracted hints struck through, as on the Mac.
  - A thin status bar: recording level, connection (green / reconnecting with buffered seconds), elapsed time.
  - A second tab: transcript (read-only in v1, no rename).
  - Stop with a confirmation.
  - Screen stays on (`FLAG_KEEP_SCREEN_ON`); dark theme by default so it doesn't light up the table.
- **Recording** runs in the foreground service, independent of the screen: `AudioRecord` with source
  `VOICE_RECOGNITION` (falls back to `MIC`), 16 kHz mono PCM16, ~100 ms frames, partial wake lock.
- **Buffering**: ring buffer of at least 10 minutes of audio (~19 MB). Reconnect with backoff; resend from the last
  ack. When the buffer overflows, oldest audio is dropped and the user sees it.
- **App killed or restarted** (Claude's call): the buffer lives in memory only; it is not persisted to disk. On
  launch the app asks the gateway for `state`; if its meeting is still running it rejoins it, says "audio lost
  from hh:mm to hh:mm" and resumes recording. The Mac fills the gap with silence. Persisting the buffer is a later
  improvement if this turns out to happen in practice.
- **Alarms** (visible + vibration): connection lost > 30 s, buffer more than half full, the Mac reports the meeting
  stopped unexpectedly, battery < 15 % and not charging.
- **After the meeting**: steps shown as the Mac reports them; when `summary` arrives (or later via `state`'s last
  result), show the report (Markdown rendered) and offer share. Reconnecting to a meeting the watchdog already
  stopped shows that, plus the report when ready.

### Recovery and lifecycle rules (Claude's calls)

These are part of the contract, not implementation details; step 1 and 2 test each of them.

- **Every audio frame and ack carries the meeting ID.** Frames for another or an ended meeting are refused with
  a reason; the phone shows it.
- **The sample offset is owned by the Mac.** On (re)join the gateway tells the phone the meeting's start time and
  the last acknowledged offset. The phone sets its offset from its own elapsed recording time since that start
  (wall clock, corrected once at join), so an app restart continues at the right offset; the Mac fills
  `last ack → first new frame` with silence and reports the lost interval.
- **Acks are cumulative** ("everything up to offset n received"); a lost ack only means a later one covers it.
- **One audio producer per meeting.** A new audio connection with the same meeting ID replaces the old one (the
  old socket is closed). `start` carries a client request ID and is idempotent: a repeated `start` with the same ID
  returns the running meeting instead of starting a second.
- **Stop drains first.** On Stop the phone sends all buffered audio, then `stop`; the gateway waits for the final
  ack (at most 60 s) before stopping the pipeline. If the phone can't reach the Mac, a local Stop keeps the buffer
  and sends it + stop on reconnect; the watchdog still applies.
- **Catch-up stays bounded.** Resent audio is transcribed (for transcript and report) but live audio has
  priority: the pipeline transcribes the newest live segment first and works through backlog segments in between.
  Old segments never go to gate/rerank/Claude (see timestamps above).
- **Health is more than a connected socket.** The status bar shows three things separately: phone is capturing
  (level moving), Mac has acknowledged audio up to n seconds ago, Mac has transcribed up to n seconds ago. If
  transcription falls more than 60 s behind live audio, that is an alarm.
- **Security.** The gateway authenticates the phone token before sending anything (no replay, no project list
  without it). "New pairing" closes all active phone connections immediately. Frames over 1 s of audio, offsets
  more than 10 min ahead of the Mac's clock, and unknown message types are rejected. Tailscale itself is the
  device restriction: Stefan's tailnet contains only his own devices; the gateway additionally checks the peer is
  a Tailscale address (100.64.0.0/10).

## Build order (each step usable on its own)

1. **Pipeline accepts phone audio.** `PhoneSource`, `--phone`, gap/duplicate handling, watchdog. Tested with a small
   Python test client that streams a WAV from `examples/` over localhost, including a simulated dropout.
2. **Gateway in HintMeet.app.** Settings section, QR pairing, Tailscale-only bind, control messages, proxy,
   keep-awake. Tested with the same Python client via the Tailscale address.
3. **Android viewer.** Pairing, start screen, meeting screen, report; audio still from the Python test client. This
   gets the UI right before the hard part.
4. **Android recording.** Foreground service, buffer, reconnect, alarms.
5. **Field test.** A real meeting of 1–2 hours over 4G with the Mac at home.

## Acceptance

- Two hours over 4G with the Mac at home: no crash, recording never silently stopped, report written.
- A forced dropout of 2 minutes (airplane mode) loses no audio and needs no user action.
- From end of utterance to first hint word on the phone: at most 1 s slower than on the Mac (measure on the test
  conversation via step 1–3).
- With the switch off, nothing listens on the Tailscale address.

## Left to the builder

- Package layout of the Android project (proposal: `android/` at the repo root) and the Gradle setup.
- How audio reaches the pipeline from the gateway (same socket vs. second port), as long as the phone sees one
  endpoint.
- Exact reconnect backoff, frame size within 50–200 ms, visual details of the screens within the rules above.
- Test approach per step, following the project's existing tests (`tests/`).
