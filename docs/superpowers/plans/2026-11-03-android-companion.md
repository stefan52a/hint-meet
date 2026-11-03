# Android Companion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stefan's Android phone records a meeting and shows HintMeet's hints, while the Mac at home (reached over Tailscale) runs the whole pipeline.

**Architecture:** The Python pipeline gets a phone audio source (`src/hint_meet/phone.py`) that listens on localhost next to the existing overlay `Hub`. HintMeet.app gets an always-on companion gateway that listens only on the Mac's Tailscale address, starts/stops meetings for the phone, and proxies the phone's socket to the `Hub` (text) and the phone source (binary audio). A new Kotlin app in `android/` pairs via QR, records in a foreground service with a resend buffer, and shows the hints.

**Tech Stack:** Python 3.11 + `websockets` (sync) + pytest; Swift 6 toolchain (language mode 5), SwiftUI, Network.framework, IOKit, CoreImage, checks via `swift run GatewayChecks` (no Xcode, so no XCTest); Kotlin 2.1, Jetpack Compose, OkHttp 4.12, kotlinx.serialization, JUnit 4.

**Spec:** `docs/superpowers/specs/2026-11-03-android-companion-design.md`

## Global Constraints

- Single user (Stefan); APK sideloaded, debug signing; no Play Store, no iOS.
- Audio on the wire: PCM16 mono 16 kHz, frames 50–200 ms (use 100 ms = 1600 samples).
- Phone ring buffer: at least 10 minutes (9 600 000 samples ≈ 19 MB).
- Watchdog: 30 minutes without audio frames → meeting stops as if Stop was pressed, report still written.
- Stop drains: wait for the final ack at most 60 s.
- Frame limits: more than 1 s of audio (16 000 samples) → reject; offset more than 10 min ahead of the Mac's clock → reject.
- Transcription more than 60 s behind live audio **and not shrinking** (no gain over the last 15 s of `progress`) → alarm on the phone. A catch-up after a long gap is behind but shrinking, so it shows as a calm "catching up" line, not an alarm.
- Phone alarms: connection lost > 30 s, buffer more than half full, Mac reports meeting stopped unexpectedly, battery < 15 % and not charging.
- Gateway off by default; when on, it listens only on the Mac's Tailscale IPv4 (100.64.0.0/10) and accepts peers only from 100.64.0.0/10. With the switch off nothing listens.
- Phone token: 32+ random bytes, in the Keychain, separate from the overlay `ws-token`; "New pairing" revokes it and closes all phone connections.
- Android: minSdk 29, foreground service type `microphone`, `FLAG_KEEP_SCREEN_ON`, dark theme by default.
- Resent (late) audio goes to transcript and report only, never to gate/rerank/Claude (timestamps from the stream).
- Project rules: update `CHANGELOG.md` in the same commit as every user-visible change; commit messages in English; stage only your own files (never `git add -A`); never kill a running HintMeet meeting (check `ps` first).
- Ports: gateway 8790 (only app instance 1 runs it); phone source = hub port + 100 (8865 for instance 1).

**Deviation from the spec (decided while planning):** the spec asks that live audio is transcribed before resent backlog. This plan keeps one in-order speech thread instead: resent audio is already kept out of the gate/Claude path by its stale timestamp, Whisper turbo clears a 10-minute backlog in well under a minute, and the "> 60 s behind" alarm makes any lag visible. Task 3 measures it; if catch-up after a 10-minute gap takes more than 60 s, add a priority queue then. **Measured in Task 3: 86 s for a 10-minute backlog of dense speech (148 utterances). Stefan chose (2026-11-03) to keep the in-order queue: 10-minute outages are rare, gaps under a minute catch up in seconds. The test limit is 120 s, and the phone's lag alarm only fires when the lag stops shrinking (see Global Constraints).**

## Review Focus

1. **The Mac's Tailscale address changes or Tailscale restarts while the gateway is on.** Expected: the gateway rebinds to the new address within 10 s, and the phone reconnects on its own. Test in Task 5 (`test_tailnet_monitor_rebinds_on_change`).
2. **The phone's wall clock is minutes off from the Mac.** Expected: a rejoin computes its offset from the Mac's `now_ms`, so frames are accepted and not rejected as "too far ahead". Test in Task 10 (`rejoinOffsetUsesMacClock`).
3. **The meeting is stopped from the Mac's own overlay or menu.** Expected: the phone stops recording and shows "stopped on the Mac". It does not raise the "stopped unexpectedly" alarm and does not reconnect forever. Test in Task 7 (`stoppedFromMacEndsMeetingWithoutAlarm`).
4. **An old phone socket is still half-open when the reconnected one starts sending.** Expected: only the newest audio connection feeds the meeting, acks go to it, and the old one is closed. Test in Task 2 (`test_new_audio_connection_replaces_old`).
5. **The pipeline crashes or the Mac sleeps mid-meeting.** Expected: the gateway reports `idle` with no result for the running meeting ID, and the phone raises "Mac stopped unexpectedly" within 30 s. Test in Task 11 (`macGoneWhileRecordingRaisesAlarm`).

---

## Wire protocol (shared by Tasks 1–11)

**Binary audio frame** (phone → gateway → phone source), little-endian, 16-byte header + samples:

| bytes | field |
|---|---|
| 0–7 | `meeting` uint64 |
| 8–11 | `seq` uint32 (per connection, from 0; for logging only) |
| 12–15 | `offset` uint32: sample index of the first sample since the meeting's audio start |
| 16– | PCM16 samples, 1…16 000 of them |

**Text messages.** Meeting IDs are 16 lowercase hex characters (the uint64).

| direction | message |
|---|---|
| source → phone | `{"type":"audio_ready","meeting":id,"started_at_ms":int}`: sent when the phone source accepts audio. `started_at_ms` is the Mac's wall clock at offset 0. |
| source → phone | `{"type":"audio_ack","meeting":id,"offset":int}`: cumulative, every ~1 s and after a drain |
| source → phone | `{"type":"audio_reject","meeting":id,"reason":str}` |
| hub → phone | existing overlay events, plus `{"type":"progress","heard_s":float,"processed_s":float}` every 5 s |
| phone → gateway | `{"type":"projects"}` → `{"type":"projects","items":[str],"selected":[str]}` |
| phone → gateway | `{"type":"start","request_id":str,"projects":[str],"language":str,"info":str}` |
| phone → gateway | `{"type":"state"}` |
| gateway → phone | `{"type":"state","phase":"idle"\|"starting"\|"running"\|"stopping","meeting":id\|null,"started_at_ms":int\|null,"now_ms":int,"busy_elsewhere":bool,"last":{"meeting":id,"stopped_by":"user"\|"watchdog","report_md":str\|null}\|null}` sent on request and on every change |
| phone → hub (via gateway) | `{"type":"stop","final_offset":int}` and the existing `feedback`, `language` |

The phone connects to `ws://<host>:8790/` with the header `Authorization: Bearer <phone token>` (changed in Task 5: Network.framework's WebSocket server doesn't pass the request path to the handshake handler, so `?token=` can't be checked there; headers can, and a wrong token is refused before anything is sent). `<host>` is the MagicDNS name from the QR, or the 100.x address. Pairing QR content: `hintmeet://pair?host=<ip>&port=8790&token=<token>`.

---

## Step 1: pipeline accepts phone audio

### Task 1: `PhoneStream`: frame handling without sockets

**Files:**
- Create: `src/hint_meet/phone.py`
- Test: `tests/test_phone.py`

**Interfaces:**
- Produces:
  - `RATE_HZ = 16000`, `HEADER = struct.Struct("<QII")`, `MAX_FRAME = 16000`, `MAX_AHEAD_S = 600`, `WATCHDOG_S = 1800`
  - `encode_frame(meeting: int, seq: int, offset: int, pcm16: np.ndarray) -> bytes` (used by tests and `tools/phone_client.py`)
  - `class FrameError(ValueError)` with `reason: str`
  - `class PhoneStream(meeting: int, channel: str = "Unknown", clock=time.monotonic, wall=time.time)`:
    - `started_at_ms: int` (wall clock at offset 0, fixed at construction)
    - `accept(data: bytes) -> list[Block]`: validated, deduplicated, gap-filled `live.Block`s; `Block.t = mono_base + offset / RATE_HZ`; raises `FrameError`
    - `acked: int` (cumulative sample offset received)
    - `lost_s: float` (total silence inserted)
    - `last_frame_at: float | None`, `timed_out(now: float | None = None) -> bool`

- [ ] **Step 1: Write the failing tests**

```python
def test_frames_become_blocks_with_stream_timestamps():
    clock = FakeClock(100.0)
    s = PhoneStream(meeting=7, clock=clock)
    blocks = s.accept(encode_frame(7, 0, 0, tone(1600)))
    assert [b.channel for b in blocks] == ["Unknown"]
    assert blocks[0].samples.dtype == np.float32 and len(blocks[0].samples) == 1600
    clock.t = 400.0                                   # arrives 5 minutes later (resent)
    late = s.accept(encode_frame(7, 1, 1600, tone(1600)))
    assert late[0].t == pytest.approx(100.1)          # stamped by offset, not by arrival
    assert s.acked == 3200

def test_duplicate_and_overlapping_frames_are_trimmed():
    s = PhoneStream(meeting=7)
    s.accept(encode_frame(7, 0, 0, tone(1600)))
    assert s.accept(encode_frame(7, 1, 0, tone(1600))) == []          # full duplicate
    part = s.accept(encode_frame(7, 2, 800, tone(1600)))              # half overlaps
    assert sum(len(b.samples) for b in part) == 800 and s.acked == 2400

def test_gap_is_filled_with_silence_and_counted():
    s = PhoneStream(meeting=7)
    s.accept(encode_frame(7, 0, 0, tone(1600)))
    blocks = s.accept(encode_frame(7, 0, 1600 + 32000, tone(1600)))   # 2 s missing (phone restarted)
    assert sum(len(b.samples) for b in blocks) == 32000 + 1600
    assert not blocks[0].samples.any()
    assert s.lost_s == pytest.approx(2.0)

@pytest.mark.parametrize("frame,reason", [
    (lambda: encode_frame(8, 0, 0, tone(1600)), "meeting"),
    (lambda: encode_frame(7, 0, 0, tone(16001)), "too long"),
    (lambda: encode_frame(7, 0, 0, tone(0)), "empty"),
    (lambda: b"\x00" * 10, "header"),
    (lambda: encode_frame(7, 0, 16000 * 601, tone(1600)), "ahead"),
])
def test_bad_frames_are_rejected(frame, reason):
    with pytest.raises(FrameError, match=reason):
        PhoneStream(meeting=7).accept(frame())

def test_watchdog_after_30_minutes_without_frames():
    clock = FakeClock(0.0)
    s = PhoneStream(meeting=7, clock=clock)
    assert not s.timed_out()
    s.accept(encode_frame(7, 0, 0, tone(1600)))
    clock.t = 1799.0; assert not s.timed_out()
    clock.t = 1801.0; assert s.timed_out()
```

`FakeClock` is a callable with a mutable `t`; `tone(n)` returns `n` int16 samples of a 440 Hz sine. Put both in the test file.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `.venv/bin/pytest tests/test_phone.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'hint_meet.phone'`

- [ ] **Step 3: Implement `phone.py` with `encode_frame`, `FrameError`, `PhoneStream` per the Interfaces block**

`mono_base` = `clock()` at construction. "Ahead" means `offset / RATE_HZ > (clock() - mono_base) + MAX_AHEAD_S`. The watchdog counts from construction when no frame has arrived yet. Convert samples with `pcm / 32768.0`. Comments in Dutch, like the rest of `src/` (follow `live.py`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `.venv/bin/pytest tests/test_phone.py -v`
Expected: PASS (all)

- [ ] **Step 5: Commit**

```bash
git add src/hint_meet/phone.py tests/test_phone.py
git commit -m "Phone audio: frame format, dedupe, gap filling and stream timestamps"
```

### Task 2: `PhoneSource` socket, CLI flags, and a test client

**Files:**
- Modify: `src/hint_meet/phone.py` (add `PhoneSource`)
- Modify: `src/hint_meet/cli.py:53-70` (flags), `src/hint_meet/cli.py:676-686` (source choice)
- Create: `tools/phone_client.py`
- Test: `tests/test_phone.py`

**Interfaces:**
- Consumes: `PhoneStream`, `encode_frame`, `FrameError` (Task 1); `server.load_or_create_token()`; the `live.DeviceSource` shape (`start(q)`, `stop()`, `label`, `overflows`).
- Produces:
  - `class PhoneSource(meeting: int, port: int, token: str, label: str = "Unknown")` with `start(q: queue.Queue)`, `stop()`, `label`, `overflows = 0`, `stream: PhoneStream`, `wait_acked(offset: int, timeout: float) -> bool`, `finished: bool` (true once `stream.timed_out()`; used as `until`)
  - Binds `127.0.0.1:port`, requires `?token=` (same check as `Hub.authorized`, Origin refused). On connect it sends `audio_ready`; binary messages go to `stream.accept`; it sends `audio_ack` every 1 s and after every `wait_acked` call; on `FrameError` it sends `audio_reject` and keeps the connection. A new connection closes the previous one (one producer).
  - CLI: `hint-meet live --phone-port PORT --phone-meeting HEX`. With these, `sources = [PhoneSource(...)]` and `until = lambda: phone.finished`; `--mic/--system` are ignored.
  - `tools/phone_client.py WAV --port P --meeting HEX [--token T] [--speed 1.0] [--drop-at S --drop-for S]`: streams a WAV as 100 ms frames in real time. During a drop it buffers and then resends from the last ack, like the phone will. At the end it sends `{"type":"stop","final_offset":n}` to the hub port when `--hub-port` is given.

- [ ] **Step 1: Write the failing tests**

```python
def test_phone_source_accepts_audio_and_acks(tmp_path):
    q = queue.Queue()
    src = PhoneSource(meeting=7, port=free_port(), token="t" * 40)
    src.start(q)
    try:
        with connect(f"ws://127.0.0.1:{src.port}/?token={'t' * 40}") as ws:
            assert json.loads(ws.recv(timeout=2))["type"] == "audio_ready"
            ws.send(encode_frame(7, 0, 0, tone(1600)))
            assert q.get(timeout=2).channel == "Unknown"
            assert src.wait_acked(1600, timeout=2)
            assert next_of_type(ws, "audio_ack")["offset"] == 1600
    finally:
        src.stop()

def test_phone_source_refuses_wrong_token_and_browsers():
    # wrong token → close code 1008; Origin header → close code 1008

def test_new_audio_connection_replaces_old():
    # connect A, connect B; A is closed by the server; frames on B arrive; acks arrive on B only

def test_rejected_frame_keeps_connection_open():
    # send a frame for meeting 8 → audio_reject with "meeting"; then a good frame still arrives in q
```

The last three are written as code following the pattern of the first (`free_port`, `next_of_type` helpers in the test file).

- [ ] **Step 2: Run to verify they fail**

Run: `.venv/bin/pytest tests/test_phone.py -k phone_source -v`
Expected: FAIL with `ImportError: cannot import name 'PhoneSource'`

- [ ] **Step 3: Implement `PhoneSource` and the CLI flags**

Use `websockets.sync.server.serve` in a daemon thread, as `Hub` does. Put a lock around `stream`.

- [ ] **Step 4: Run the tests**

Run: `.venv/bin/pytest tests/test_phone.py tests/test_live.py tests/test_server.py -v`
Expected: PASS

- [ ] **Step 5: Smoke-test with the client, without the app**

Run (two terminals):
`.venv/bin/python -m hint_meet.cli --project <demo> live --ui --port 8775 --phone-port 8875 --phone-meeting 00000000000000aa --no-summary`
`.venv/bin/python tools/phone_client.py examples/<test-conversation>.wav --port 8875 --meeting 00000000000000aa --drop-at 60 --drop-for 120`
Expected: the transcript fills; after the drop the 120 s come in as transcript lines without hints; no "verloren" (lost) seconds reported.

- [ ] **Step 6: Commit**

```bash
git add src/hint_meet/phone.py src/hint_meet/cli.py tools/phone_client.py tests/test_phone.py
git commit -m "Pipeline: phone audio source on localhost, live --phone-port/--phone-meeting, test client"
```

### Task 3: Stop drains, watchdog stop, progress, stop reason in meta

**Files:**
- Modify: `src/hint_meet/cli.py:573-577` (`stop` handler), `src/hint_meet/cli.py:756-835` (meta), progress sender next to the hub setup
- Modify: `src/hint_meet/live.py` (`LiveSession.heard_s` / `processed_s`)
- Modify: `src/hint_meet/server.py:140` (`progress` replaces its previous version in the backlog, like `status`)
- Modify: `CHANGELOG.md`
- Test: `tests/test_phone.py`, `tests/test_live.py`, `tests/test_server.py`

**Interfaces:**
- Consumes: `PhoneSource.wait_acked`, `PhoneSource.finished`, `PhoneStream.lost_s` (Tasks 1–2).
- Produces:
  - `LiveSession.heard_s: float` (seconds of audio taken from the queue) and `LiveSession.processed_s: float` (seconds through segmenter + `_handle`; the speech thread is synchronous, so this equals "transcribed up to")
  - Hub message `progress` every 5 s while running (see the wire protocol)
  - `stop` with `final_offset`: a thread calls `phone.wait_acked(final_offset, 60)`, then waits (within the same 60 s budget) until `session.heard_s * 16000 >= final_offset`, and only then `session.stop()`. The run loop exits on `stop_flag` without draining its queue, so stopping right after the ack would drop the last blocks. `stop` without `final_offset` stops immediately (Mac overlay, unchanged)
  - meta JSON gets `"phone_meeting": HEX` and `"stopped_by": "user" | "watchdog"`
  - when `lost_s` grows, a hub `status` message: `"Audio from the phone lost: N s"`. The silence that fills the gap before the phone's *first* frame (offset 0 is fixed when `PhoneSource` is built, the phone starts a moment later via `OffsetClock`) is not lost audio: keep it out of `lost_s` (found in the Task 2 smoke test)

- [ ] **Step 1: Write the failing tests**

```python
def test_progress_tracks_heard_and_processed_audio():
    # LiveSession with a WavSource of 3 s and a stub transcriber → after run(): heard_s ≈ 3.0, processed_s ≈ 3.0

def test_stop_waits_for_final_offset_then_stops(monkeypatch):
    # fake phone with wait_acked recording its args → on_message({"type":"stop","final_offset":32000})
    # → wait_acked called with (32000, 60) before session.stop()

def test_stop_keeps_the_last_seconds():
    # real LiveSession + PhoneSource, stub transcriber that records segment lengths; send 3 s of speech
    # then stop with final_offset=48000 immediately → the transcriber saw audio up to 3 s (nothing dropped)

def test_watchdog_stop_is_recorded_in_meta(tmp_path):
    # run live_cmd's stop path with phone.finished True → meta["stopped_by"] == "watchdog"

def test_hub_keeps_only_latest_progress():
    hub.send(type="progress", heard_s=1, processed_s=1); hub.send(type="progress", heard_s=2, processed_s=2)
    assert [json.loads(m)["heard_s"] for m in hub.backlog if '"progress"' in m] == [2]

def test_ten_minute_backlog_catches_up_quickly():
    # mark slow; real Transcriber; feed 600 s of examples audio as one resent burst through PhoneStream
    # → processed_s reaches heard_s within 60 s of wall time; no pipeline.step calls (all stale)
```

To make the stop handler testable, pull it out of `live_cmd` as `handle_stop(msg: dict, session: LiveSession, phone: PhoneSource | None) -> None` in `cli.py`.

- [ ] **Step 2: Run to verify they fail**

Run: `.venv/bin/pytest tests/test_phone.py tests/test_live.py tests/test_server.py -v`
Expected: the new tests FAIL (`AttributeError: heard_s`, `handle_stop` missing, …)

- [ ] **Step 3: Implement per the Interfaces block**

- [ ] **Step 4: Run all tests**

Run: `.venv/bin/pytest -q` and `.venv/bin/pytest -q -m slow tests/test_live.py::test_ten_minute_backlog_catches_up_quickly`
Expected: PASS. If the backlog test needs more than 60 s, stop and report: the spec's live-first queue is then needed (see "Deviation").

- [ ] **Step 5: CHANGELOG entry**, e.g. "Pipeline accepts audio from the phone companion (for the coming Android app); stop waits for the phone's last audio; meeting stops by itself after 30 minutes without phone audio."

- [ ] **Step 6: Commit**

```bash
git add src/hint_meet/cli.py src/hint_meet/live.py src/hint_meet/server.py CHANGELOG.md tests/test_phone.py tests/test_live.py tests/test_server.py
git commit -m "Phone meetings: stop drains the phone's audio, watchdog after 30 min, progress messages"
```

## Step 2: gateway in HintMeet.app

### Task 4: Swift test target and the gateway's pure logic

**Files:**
- Modify: `app/HintMeet/Package.swift` (add `.testTarget(name: "HintMeetTests", dependencies: ["HintMeet"], path: "Tests/HintMeetTests")`)
- Create: `app/HintMeet/Sources/HintMeet/GatewayProtocol.swift`
- Test: `app/HintMeet/Tests/HintMeetTests/GatewayProtocolTests.swift`

**Interfaces:**
- Produces (all `nonisolated`, no I/O except `LastResult.read`):
  - `enum Tailnet { static func isTailnet(_ ipv4: String) -> Bool; static func address(from interfaces: [(name: String, ipv4: String)]) -> String? }` (picks the first 100.64.0.0/10 address; `currentAddress()` wraps `getifaddrs`)
  - `struct Pairing { static func url(host: String, port: Int, token: String) -> String }` → `hintmeet://pair?host=…&port=…&token=…` (token percent-encoded). `host` is the Mac's MagicDNS name (`Self.DNSName` from `tailscale status --json`, trailing dot removed, e.g. `macbook.tail1234.ts.net`) when available, otherwise the 100.x address. The name survives a changed Tailscale IP, so the phone needs no re-pairing.
  - `enum PhoneRequest: Equatable { case projects, state, start(requestID: String, projects: [String], language: String, info: String), toHub(String), invalid }` and `static func parse(_ text: String) -> PhoneRequest`. `stop`, `feedback` and `language` go to `.toHub`; unknown types are `.invalid`.
  - `struct GatewayState: Codable, Equatable` matching the wire protocol's `state` message, with `func json() -> String`
  - `struct LastResult { static func read(logs: URL, meeting: String) -> GatewayState.Last? }`: the newest `live-*.meta.json` with `phone_meeting == meeting`; `report_md` = contents of `meta["report"]` if that file exists
  - `static func meetingID() -> String` (16 hex chars from `SecRandomCopyBytes`)

- [ ] **Step 1: Write the failing tests**

```swift
func testTailnetRange() {
    XCTAssertTrue(Tailnet.isTailnet("100.64.0.1")); XCTAssertTrue(Tailnet.isTailnet("100.127.255.254"))
    XCTAssertFalse(Tailnet.isTailnet("100.128.0.1")); XCTAssertFalse(Tailnet.isTailnet("192.168.1.5"))
    XCTAssertEqual(Tailnet.address(from: [("en0", "192.168.1.5"), ("utun4", "100.101.102.103")]), "100.101.102.103")
}
func testPairingURLEncodesToken() {
    XCTAssertEqual(Pairing.url(host: "100.1.2.3", port: 8790, token: "a+b/c"),
                   "hintmeet://pair?host=100.1.2.3&port=8790&token=a%2Bb%2Fc")
}
func testRouting() {
    XCTAssertEqual(PhoneRequest.parse(#"{"type":"projects"}"#), .projects)
    XCTAssertEqual(PhoneRequest.parse(#"{"type":"stop","final_offset":5}"#), .toHub(#"{"type":"stop","final_offset":5}"#))
    XCTAssertEqual(PhoneRequest.parse(#"{"type":"start","request_id":"r1","projects":["acme"],"language":"nl","info":""}"#),
                   .start(requestID: "r1", projects: ["acme"], language: "nl", info: ""))
    XCTAssertEqual(PhoneRequest.parse("not json"), .invalid)
    XCTAssertEqual(PhoneRequest.parse(#"{"type":"shutdown"}"#), .invalid)
}
func testLastResultFindsReportForMeeting() throws {
    // temp logs dir with two meta files (other meeting / this meeting with stopped_by "watchdog" and a report file)
    // → stoppedBy == "watchdog", reportMD == file contents; unknown meeting → nil
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd app/HintMeet && swift test`
Expected: FAIL to compile (`cannot find 'Tailnet' in scope`). If SwiftPM refuses `@testable import` of the executable target, move `GatewayProtocol.swift` into a new library target `HintMeetCore` that `HintMeet` depends on, and note it in the commit.

- [ ] **Step 3: Implement `GatewayProtocol.swift`**

- [ ] **Step 4: Run the tests**

Run: `cd app/HintMeet && swift test`
Expected: PASS. Then `app/build-app.sh` still builds.

- [ ] **Step 5: Commit**

```bash
git add app/HintMeet/Package.swift app/HintMeet/Sources/HintMeet/GatewayProtocol.swift app/HintMeet/Tests
git commit -m "HintMeet.app: test target and the phone gateway's protocol helpers"
```

### Task 5: The gateway: listener, start/stop, proxy, keep-awake

**Files:**
- Create: `app/HintMeet/Sources/HintMeet/Gateway.swift`, `app/HintMeet/Sources/HintMeet/KeepAwake.swift`
- Modify: `app/HintMeet/Sources/HintMeet/Backend.swift:141-175` (`start(recording:phone:)`)
- Modify: `app/HintMeet/Sources/HintMeet/Settings.swift` (`phoneEnabled: Bool` in UserDefaults, default false; `phoneToken` in the Keychain)
- Modify: `app/HintMeet/Sources/HintMeet/App.swift` (create and own the `Gateway` for instance 1 only)
- Test: `app/HintMeet/Tests/HintMeetTests/GatewayProtocolTests.swift` (monitor decision), manual check with `tools/phone_client.py`

**Interfaces:**
- Consumes: everything from Task 4; `Backend.isRunning`, `Backend.state`; `Settings.project` (the `"Finance,acme"` format), `language`, `meetingInfo`; overlay token from `~/Library/Application Support/hint-meet/ws-token`; the pipeline flags from Task 2.
- Produces:
  - `Backend.start(recording: String? = nil, phone: (port: Int, meeting: String)? = nil)`: with `phone`, args get `--phone-port <hubPort+100> --phone-meeting <id>` instead of `--mic/--system`
  - `@MainActor final class Gateway: ObservableObject` with `@Published var listening: String?` (bound address or nil), `@Published var problem: String?` (e.g. "Tailscale isn't running"), `func setEnabled(_ on: Bool)`, `func newPairing() -> String` (returns the pairing URL, closes all phone connections)
  - `struct TailnetMonitor { mutating func decide(current: String?, bound: String?) -> Action }` with `enum Action { case none, bind(String), unbind }`: pure, polled every 5 s
  - `final class KeepAwake { func update(enabled: Bool) }`: holds `kIOPMAssertionTypePreventUserIdleSystemSleep` while enabled and on AC power (`IOPSGetProvidingPowerSourceType == kIOPMACPowerKey`)

Behaviour that must hold:
- `NWListener` with `NWProtocolWebSocket`, `requiredLocalEndpoint` = Tailscale address:8790. Refuse a connection if the peer isn't in 100.64.0.0/10 or the `Authorization: Bearer` token doesn't match (constant-time compare, in `setClientRequestHandler`). Nothing is sent before the check.
- `.start` while `Backend.isRunning` and not this gateway's meeting → `state` with `busy_elsewhere: true`. A repeated `request_id` returns the current state and never starts a second meeting.
- Once the pipeline runs: one upstream `URLSessionWebSocketTask` to the hub (`ws://127.0.0.1:<port>/?token=`) and one to the phone source (`<port+100>`), each retried every 1 s until connected. Text from the hub and the source goes to the phone; `.toHub` text goes to the hub; binary goes to the source. A new phone connection replaces the previous phone's upstream audio.
- `state` is pushed to all phone connections on every `Backend.state` change; `started_at_ms` is taken from the source's `audio_ready` (null until then); `last` comes from `LastResult.read` once the pipeline has exited.

- [ ] **Step 1: Write the failing test** `test_tailnet_monitor_rebinds_on_change` (Swift name `testTailnetMonitorRebindsOnChange`):

```swift
var m = TailnetMonitor()
XCTAssertEqual(m.decide(current: "100.1.1.1", bound: nil), .bind("100.1.1.1"))
XCTAssertEqual(m.decide(current: "100.1.1.1", bound: "100.1.1.1"), .none)
XCTAssertEqual(m.decide(current: "100.2.2.2", bound: "100.1.1.1"), .bind("100.2.2.2"))
XCTAssertEqual(m.decide(current: nil, bound: "100.2.2.2"), .unbind)
```

- [ ] **Step 2: Run to verify it fails**: `cd app/HintMeet && swift test` → compile error, `TailnetMonitor` missing.

- [ ] **Step 3: Implement `TailnetMonitor`, `KeepAwake`, `Gateway`, the `Backend` and `Settings` changes**

- [ ] **Step 4: Run the tests and build**: `swift test` PASS; `app/build-app.sh` builds. Check `ps aux | grep "hint_meet.cli.*live"` before installing: no running meeting, otherwise don't restart the app; only build and report.

- [ ] **Step 5: Manual end-to-end over Tailscale.** Turn on `phoneEnabled` (`defaults write` until Task 6 adds the UI). Then:
`tools/phone_client.py` gets a `--gateway ws://<tailscale-ip>:8790 --token <phone token> --start <project>` mode: it sends `start`, waits for `audio_ready`, streams, then sends `stop`.
Expected: the meeting starts on the Mac, hints arrive at the client as text, the report gets written, and a second `state` shows `last.report_md`. With `phoneEnabled` off: `nc -z <tailscale-ip> 8790` fails.

- [ ] **Step 6: Commit**

```bash
git add app/HintMeet/Sources/HintMeet/{Gateway,KeepAwake,Backend,Settings,App}.swift app/HintMeet/Tests tools/phone_client.py
git commit -m "HintMeet.app: phone gateway on the Tailscale address (start/stop, proxy, keep-awake)"
```

### Task 6: Settings → Phone section with pairing QR

**Files:**
- Create: `app/HintMeet/Sources/HintMeet/PhoneSettingsView.swift`
- Modify: `app/HintMeet/Sources/HintMeet/SettingsView.swift` (add the section)
- Modify: `CHANGELOG.md`, `README.md` (short "Phone companion" subsection: Tailscale on both devices, Mac on power with the lid open, switch, pairing)

**Interfaces:**
- Consumes: `Gateway.setEnabled`, `Gateway.newPairing`, `Gateway.listening`, `Gateway.problem`, `Pairing.url` (Tasks 4–5).
- Produces: the UI only. Switch "Allow phone companion" (off by default); when on: the QR image (`CIFilter.qrCodeGenerator`, scaled with `.interpolation(.none)`), the address it listens on or `problem`, a "New pairing" button (with a confirmation that the old phone stops working), and one line: "Keep this Mac on power with the lid open during phone meetings."

- [ ] **Step 1: Implement the view**
- [ ] **Step 2: Build and check by eye**: `app/build-app.sh`, open Settings. The QR scans with any phone QR app to `hintmeet://pair?...`. With Tailscale quit, the section shows the problem line and `nc -z` on 8790 fails.
- [ ] **Step 3: CHANGELOG and README**
- [ ] **Step 4: Commit**

```bash
git add app/HintMeet/Sources/HintMeet/PhoneSettingsView.swift app/HintMeet/Sources/HintMeet/SettingsView.swift CHANGELOG.md README.md
git commit -m "Settings: Phone section with pairing QR for the companion app"
```

## Step 3: Android viewer

### Task 7: Android project, protocol and meeting state

**Files:**
- Create: `android/` Gradle project (`settings.gradle.kts`, `build.gradle.kts`, `gradle/libs.versions.toml`, wrapper, `app/build.gradle.kts`, `app/src/main/AndroidManifest.xml`), package `nl.zoofit.hintmeet`
- Create: `android/app/src/main/java/nl/zoofit/hintmeet/protocol/Frame.kt`, `protocol/Messages.kt`, `protocol/MeetingReducer.kt`
- Test: `android/app/src/test/java/nl/zoofit/hintmeet/protocol/FrameTest.kt`, `MeetingReducerTest.kt`
- Modify: `.gitignore` (`android/.gradle/`, `android/build/`, `android/app/build/`, `android/local.properties`)

**Interfaces:**
- Produces:
  - `object Frame { fun encode(meeting: ULong, seq: UInt, offset: UInt, pcm: ShortArray): ByteArray }`: matches `phone.encode_frame` byte for byte
  - `sealed interface ServerMessage` parsed by `fun parseServer(text: String): ServerMessage?`: `Hello`, `Utterance(id, time, speaker, text)`, `Hint(id, state: HintState, text, sources: List<String>, reason: String?)`, `Confirm`, `Status(text)`, `Progress(heardS, processedS)`, `Summary(markdown)`, `ApiError(text)`, `Stopped`, `AudioReady(meeting, startedAtMs)`, `AudioAck(meeting, offset: Long)`, `AudioReject(meeting, reason)`, `State(phase, meeting, startedAtMs, nowMs, busyElsewhere, last: Last?)`, `Projects(items, selected)`. Unknown types → `null`.
  - `data class MeetingUi(phase, hints: List<HintUi>, transcript: List<Line>, status: String?, report: String?, stoppedBy: StoppedBy?, progress: Progress?)` and `fun reduce(ui: MeetingUi, msg: ServerMessage): MeetingUi`. Streaming and final hints with the same id replace each other; `retracted` keeps the text with `struck = true`; `Stopped` with no phone `stop` sent → `stoppedBy = MAC`.
- Versions (bump to current stable if these don't resolve): AGP 8.7.3, Kotlin 2.1.0, compileSdk/targetSdk 35, minSdk 29, Compose BOM 2024.12.01, OkHttp 4.12.0, kotlinx-serialization-json 1.7.3, JUnit 4.13.2.

- [ ] **Step 1: Write the failing tests**

```kotlin
@Test fun frameMatchesPython() {
    // golden bytes produced once with: python -c "from hint_meet.phone import encode_frame; import numpy as np;
    //   print(encode_frame(0xaa, 3, 1600, np.array([1,-1,32767,-32768], np.int16)).hex())"
    assertEquals(GOLDEN_HEX, Frame.encode(0xaaUL, 3u, 1600u, shortArrayOf(1, -1, 32767, -32768)).toHex())
}
@Test fun streamingHintIsReplacedByFinal() { /* Hint(5, STREAMING, "Ren") then Hint(5, FINAL, "Rente 3%.", ["Lening §2"]) → one hint, final text, one source */ }
@Test fun retractedHintIsStruckThrough() { /* … → hints[0].struck == true, text kept */ }
@Test fun stoppedFromMacEndsMeetingWithoutAlarm() { /* running, Stopped without local stop → phase ENDED, stoppedBy MAC */ }
@Test fun unknownMessageIsIgnored() { assertNull(parseServer("""{"type":"future_thing"}""")) }
```

- [ ] **Step 2: Run to verify they fail**: `cd android && ./gradlew :app:testDebugUnitTest` → compile errors for the missing classes.
- [ ] **Step 3: Implement the scaffolding and the protocol files**
- [ ] **Step 4: Run**: `./gradlew :app:testDebugUnitTest` PASS; `./gradlew :app:assembleDebug` builds.
- [ ] **Step 5: Commit**

```bash
git add .gitignore android
git commit -m "Android companion: project setup, wire protocol and meeting state"
```

### Task 8: Pairing, gateway connection, start screen

**Files:**
- Create: `android/app/src/main/java/nl/zoofit/hintmeet/pairing/Pairing.kt`, `net/GatewayClient.kt`, `net/Backoff.kt`, `ui/PairingScreen.kt`, `ui/StartScreen.kt`, `MainActivity.kt`
- Test: `android/app/src/test/java/nl/zoofit/hintmeet/pairing/PairingTest.kt`, `net/BackoffTest.kt`

**Interfaces:**
- Consumes: `parseServer`, `ServerMessage`, `reduce` (Task 7).
- Produces:
  - `data class Pairing(host: String, port: Int, token: String)` with `companion fun parse(uri: String): Pairing?` (only `hintmeet://pair`, host must be in 100.64.0.0/10 or end in `.ts.net`, port 1–65535, token ≥ 32 chars) and `fun wsUrl(): String`; stored with `EncryptedSharedPreferences` (`androidx.security:security-crypto:1.1.0-alpha06`)
  - `class Backoff { fun next(): Long; fun reset() }` → 1 s, 2 s, 4 s, 8 s, then 10 s capped
  - `class GatewayClient(pairing: Pairing, scope: CoroutineScope)` with `val messages: SharedFlow<ServerMessage>`, `val connected: StateFlow<Boolean>`, `fun sendText(json: String)`, `fun sendBinary(bytes: ByteArray): Boolean` (false when not connected), `fun close()`; it connects with the header `Authorization: Bearer <token>` (not `?token=`, see the wire protocol), reconnects with `Backoff` until closed and sends `{"type":"state"}` after every connect
  - Pairing screen scans QR with `com.journeyapps:zxing-android-embedded:4.3.0`. Start screen: Mac reachable, project multi-select from `projects`, language (same codes as the Mac's menu: `nl`, `en`, …, `multi`), "With whom, where", Start (sends `start` with a fresh UUID `request_id`); while `starting`, it shows the hub `status` text (KB loading); `busy_elsewhere` → "A meeting is already running on the Mac".

- [ ] **Step 1: Write the failing tests**

```kotlin
@Test fun parsesValidPairing() { assertEquals(Pairing("100.101.102.103", 8790, "x".repeat(40)), Pairing.parse("hintmeet://pair?host=100.101.102.103&port=8790&token=" + "x".repeat(40))) }
@Test fun refusesNonTailnetHostAndShortToken() { assertNull(Pairing.parse("hintmeet://pair?host=192.168.1.2&port=8790&token=" + "x".repeat(40))); assertNull(Pairing.parse("hintmeet://pair?host=100.101.102.103&port=8790&token=short")) }
@Test fun backoffSequence() { val b = Backoff(); assertEquals(listOf(1000L, 2000, 4000, 8000, 10000, 10000), List(6) { b.next() }); b.reset(); assertEquals(1000L, b.next()) }
```

- [ ] **Step 2: Run to verify they fail**: `./gradlew :app:testDebugUnitTest` → missing classes.
- [ ] **Step 3: Implement**
- [ ] **Step 4: Run tests, install, check by hand**: `./gradlew :app:testDebugUnitTest :app:installDebug`. On the phone: scan the QR, the project list appears, Start starts a meeting on the Mac (fed by `tools/phone_client.py --gateway … --meeting <id from state>` as the audio).
- [ ] **Step 5: Commit**

```bash
git add android
git commit -m "Android companion: pairing via QR, gateway connection with reconnect, start screen"
```

### Task 9: Meeting screen and report

**Files:**
- Create: `android/app/src/main/java/nl/zoofit/hintmeet/ui/MeetingScreen.kt`, `ui/HintCard.kt`, `ui/StatusBar.kt`, `ui/ReportScreen.kt`, `ui/Theme.kt`

**Interfaces:**
- Consumes: `MeetingUi`, `GatewayClient` (Tasks 7–8). `StatusBar` takes `Health` from Task 11 later; until then it shows connection and elapsed time.
- Produces: screens per the spec. The latest hint fills most of the screen, at least 28 sp, words appear as they stream in. Sources are small text under the hint. 👍/👎 send `feedback`. Swipe or ◀ ▶ goes to earlier hints, and a new hint jumps back to the newest only when you're already on the newest. A Transcript tab is read-only. Stop has a confirmation. `FLAG_KEEP_SCREEN_ON` while in the meeting. Dark theme by default. The report screen renders `report_md` with `io.noties.markwon:core:4.6.2` and offers a Share intent.

- [ ] **Step 1: Implement**
- [ ] **Step 2: Check by hand** with a meeting driven by `tools/phone_client.py` playing the demo test conversation. The hint is readable from 60 cm with the phone flat on a table. A retracted hint is struck through. Stopping from the Mac overlay shows "stopped on the Mac" (Review Focus 3). After a stop the report appears; kill the app before the report is ready, reopen it, and the report still appears via `state.last`.
- [ ] **Step 3: Commit**

```bash
git add android
git commit -m "Android companion: meeting screen with large hints, transcript tab, report"
```

## Step 4: Android recording

### Task 10: Audio ring buffer and offsets

**Files:**
- Create: `android/app/src/main/java/nl/zoofit/hintmeet/audio/AudioBuffer.kt`, `audio/OffsetClock.kt`
- Test: `android/app/src/test/java/nl/zoofit/hintmeet/audio/AudioBufferTest.kt`, `OffsetClockTest.kt`

**Interfaces:**
- Produces:
  - `class AudioBuffer(capacitySamples: Int = 9_600_000)` with `fun append(offset: Long, pcm: ShortArray)`, `fun ack(offset: Long)` (drops everything below; cumulative, ignores lower acks), `fun unacked(maxSamples: Int = 1600): Sequence<Pair<Long, ShortArray>>` (frames from the lowest unacked offset), `val bufferedSeconds: Double`, `val fill: Double` (0–1), `val dropped: List<LongRange>` (sample ranges lost to overflow)
  - `class OffsetClock(startedAtMs: Long, macNowMs: Long, phoneNowAtJoinMs: Long)` with `fun offsetAt(phoneNowMs: Long): Long` = `((phoneNowMs + (macNowMs - phoneNowAtJoinMs)) - startedAtMs) * 16`

- [ ] **Step 1: Write the failing tests**

```kotlin
@Test fun ackTrimsAndResendStartsAtFirstUnacked() { /* append 0..4800 in 3 frames, ack(1600) → unacked().first().first == 1600; ack(800) is ignored */ }
@Test fun overflowDropsOldestAndRecordsRange() { /* capacity 3200, append 4800 → dropped == [0..1599], fill == 1.0 */ }
@Test fun rejoinOffsetUsesMacClock() {
    val c = OffsetClock(startedAtMs = 1_000_000, macNowMs = 1_060_000, phoneNowAtJoinMs = 5_000_000) // phone clock far off
    assertEquals(60_000L * 16, c.offsetAt(5_000_000))
    assertEquals(61_000L * 16, c.offsetAt(5_001_000))
}
```

- [ ] **Step 2: Run to verify they fail**, **Step 3: Implement**, **Step 4: Run**: `./gradlew :app:testDebugUnitTest` PASS
- [ ] **Step 5: Commit**

```bash
git add android
git commit -m "Android companion: resend buffer with cumulative acks and Mac-based offsets"
```

### Task 11: Recording service, streaming, stop drain, alarms

**Files:**
- Create: `android/app/src/main/java/nl/zoofit/hintmeet/audio/RecordingService.kt`, `audio/Streamer.kt`, `health/Health.kt`, `health/Alarms.kt`
- Modify: `AndroidManifest.xml` (`RECORD_AUDIO`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE`, `WAKE_LOCK`, `POST_NOTIFICATIONS`; service with `foregroundServiceType="microphone"`), `ui/StatusBar.kt`, `ui/MeetingScreen.kt`
- Test: `android/app/src/test/java/nl/zoofit/hintmeet/health/AlarmsTest.kt`, `audio/StreamerTest.kt`

**Interfaces:**
- Consumes: `AudioBuffer`, `OffsetClock` (Task 10), `GatewayClient`, `Frame`, `ServerMessage` (Tasks 7–8).
- Produces:
  - `RecordingService`: starts on `AudioReady`. It reads `AudioRecord` (`VOICE_RECOGNITION`, falling back to `MIC`, 16 kHz mono PCM16) in 1600-sample frames, holds a partial wake lock, and shows an ongoing notification with the elapsed time. It stores `meeting` + `startedAtMs` in prefs, so after a restart it rejoins via `state` and an `OffsetClock`.
  - `class Streamer(buffer: AudioBuffer, send: (ByteArray) -> Boolean, meeting: ULong)` with `fun onFrame(offset: Long, pcm: ShortArray)`, `fun onAck(offset: Long)`, `fun onReconnected()` (resend everything unacked, oldest first; built as `onAudioReady()`: the resend starts on every `audio_ready`, not on the gateway connect, because only then is the gateway's link to the phone source open again; frames sent before that would make the Mac fill a gap with silence). **Frames go out strictly in offset order.** While a resend is running, new live frames only go into the buffer and are sent after it. Otherwise the Mac sees a live frame first, fills the gap with silence, and then drops the resent audio as a duplicate. `fun stop(): Long` (returns `final_offset`; the caller sends `{"type":"stop","final_offset":…}` once the buffer is empty or after 60 s; if offline, on reconnect)
  - `data class Health(capturing: Boolean, lastLevelAtMs: Long, connectedSinceMs: Long?, lastDisconnectMs: Long?, ackedS: Double, heardS: Double, processedS: Double, lagShrinking: Boolean, bufferFill: Double, droppedS: Double, batteryPct: Int, charging: Boolean, macPhase: String?, localStopSent: Boolean)` and `fun alarms(h: Health, nowMs: Long): Set<Alarm>` with `enum Alarm { CONNECTION_LOST, BUFFER_HALF_FULL, MAC_STOPPED, TRANSCRIPTION_BEHIND, BATTERY_LOW, AUDIO_LOST, MIC_SILENT }`
  - Status bar shows three dots: capturing / Mac received (acked) / Mac processed, each with "n s ago". An alarm shows a red banner and vibrates once per new alarm.

- [ ] **Step 1: Write the failing tests**

```kotlin
@Test fun connectionLostAfter30s() { /* lastDisconnectMs = now - 31_000, connectedSinceMs null → CONNECTION_LOST; at 29 s → not */ }
@Test fun bufferHalfFull() { /* bufferFill 0.51 → BUFFER_HALF_FULL */ }
@Test fun transcriptionBehind60s() { /* heardS 200, processedS 139 → TRANSCRIPTION_BEHIND; 141 → not */ }
@Test fun catchingUpIsNotAnAlarm() { /* heardS 200, processedS 139, lagShrinking true → no TRANSCRIPTION_BEHIND. `lagShrinking` = heardS − processedS is smaller than in the `progress` message from 15 s earlier (the service keeps the last few) */ }
@Test fun batteryLowOnlyWhenNotCharging() { /* 14 %, charging false → BATTERY_LOW; charging true → not */ }
@Test fun macGoneWhileRecordingRaisesAlarm() { /* macPhase "idle", localStopSent false, capturing true → MAC_STOPPED */ }
@Test fun resendAfterReconnectStartsAtFirstUnacked() { /* Streamer with fake send (false while offline): frames 0..4, ack 2, reconnect → sent offsets [3200, 4800, 6400] in order */ }
@Test fun liveFramesWaitBehindResend() { /* offline for frames 0..2, reconnect, frame 3 arrives mid-resend → sent offsets strictly increasing [0, 1600, 3200, 4800] */ }
@Test fun stopReturnsFinalOffset() { /* after 5 frames of 1600 → stop() == 8000 */ }
```

- [ ] **Step 2: Run to verify they fail**, **Step 3: Implement**, **Step 4: Run**: `./gradlew :app:testDebugUnitTest` PASS, then `:app:installDebug`
- [ ] **Step 5: Manual checks on the phone**, with the Mac reached over Tailscale on 4G (Wi-Fi off):
  1. Start, talk for 2 minutes: transcript and hints appear.
  2. Airplane mode for 2 minutes while talking: the connection alarm appears after 30 s; after reconnecting, the 2 minutes appear as transcript lines without hints, and there is no "audio lost" status.
  3. Screen off for 5 minutes: recording continues (the transcript has those 5 minutes).
  4. Force-stop the app mid-meeting and reopen: it rejoins and shows "audio lost from hh:mm to hh:mm"; the Mac's status says how many seconds.
  5. Stop: the last seconds before Stop are in the transcript; the report appears on the phone.
- [ ] **Step 6: CHANGELOG** ("Android companion app: record a meeting with your phone while the Mac at home does the work"), **commit**

```bash
git add android CHANGELOG.md
git commit -m "Android companion: recording service, resend on reconnect, stop drain, alarms"
```

## Step 5: field test

### Task 12: Latency measurement and a real meeting

**Files:**
- Modify: `tools/phone_client.py` (`--measure`: logs, per utterance, end-of-utterance → first `hint` streaming message, in ms)
- Create: `docs/field-test-android-companion.md` (results)

- [ ] **Step 1: Latency.** Run the demo test conversation through `tools/phone_client.py --measure` once via localhost (Mac only) and once via the gateway over Tailscale from another network (phone hotspot). Pass: the median over Tailscale is at most 1000 ms above localhost.
- [ ] **Step 2: Acceptance run.** A real meeting of 1–2 hours over 4G with the Mac at home. Write down in the results file: crashes (must be none), alarms that fired and why, seconds lost, whether the report was written, battery use, data used (expect ~230 MB for two hours).
- [ ] **Step 3: Check the off switch:** with the switch off, `nc -z <tailscale-ip> 8790` fails.
- [ ] **Step 4: Commit**

```bash
git add tools/phone_client.py docs/field-test-android-companion.md
git commit -m "Field test of the Android companion: latency and a two-hour meeting"
```
