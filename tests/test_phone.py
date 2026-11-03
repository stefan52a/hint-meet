import json
import queue
import socket
import time

import numpy as np
import pytest
from websockets.sync.client import connect

from hint_meet.phone import FrameError, PhoneSource, PhoneStream, encode_frame


class FakeClock:
    def __init__(self, t=0.0):
        self.t = t

    def __call__(self):
        return self.t


def tone(n):
    return (np.sin(2 * np.pi * 440 * np.arange(n) / 16000) * 10000).astype(np.int16)


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


def test_odd_payload_is_rejected():
    with pytest.raises(FrameError, match="odd"):
        PhoneStream(meeting=7).accept(encode_frame(7, 0, 0, tone(10)) + b"\x00")


def test_rejected_frame_changes_nothing():
    s = PhoneStream(meeting=7)
    with pytest.raises(FrameError):
        s.accept(encode_frame(7, 0, 16000 * 601, tone(1600)))
    assert s.acked == 0 and s.lost_s == 0 and s.last_frame_at is None


def test_watchdog_after_30_minutes_without_frames():
    clock = FakeClock(0.0)
    s = PhoneStream(meeting=7, clock=clock)
    assert not s.timed_out()
    s.accept(encode_frame(7, 0, 0, tone(1600)))
    clock.t = 1799.0; assert not s.timed_out()
    clock.t = 1801.0; assert s.timed_out()


TOKEN = "t" * 40


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def next_of_type(ws, kind, timeout=3):
    end = time.time() + timeout
    while True:
        msg = json.loads(ws.recv(timeout=max(0.05, end - time.time())))
        if msg["type"] == kind:
            return msg


@pytest.fixture
def source():
    src = PhoneSource(meeting=7, port=free_port(), token=TOKEN)
    q = queue.Queue()
    src.start(q)
    yield src, q
    src.stop()


def url(src, token=TOKEN):
    return f"ws://127.0.0.1:{src.port}/?token={token}"


def test_phone_source_accepts_audio_and_acks(source):
    src, q = source
    with connect(url(src)) as ws:
        ready = json.loads(ws.recv(timeout=2))
        assert ready["type"] == "audio_ready" and ready["meeting"] == "0000000000000007"
        ws.send(encode_frame(7, 0, 0, tone(1600)))
        assert q.get(timeout=2).channel == "Unknown"
        assert src.wait_acked(1600, timeout=2)
        assert next_of_type(ws, "audio_ack")["offset"] == 1600
    assert src.wait_acked(99999, timeout=0.1) is False


def test_phone_source_sends_periodic_acks(source):
    src, q = source
    with connect(url(src)) as ws:
        ws.recv(timeout=2)
        ws.send(encode_frame(7, 0, 0, tone(1600)))
        q.get(timeout=2)
        assert next_of_type(ws, "audio_ack", timeout=3)["meeting"] == "0000000000000007"


def test_phone_source_refuses_wrong_token_and_browsers(source):
    src, _ = source
    with connect(url(src, "x" * 40)) as ws:
        with pytest.raises(Exception) as e:
            ws.recv(timeout=2)
        assert e.value.rcvd.code == 1008
    with connect(url(src), origin="http://evil.example") as ws:
        with pytest.raises(Exception) as e:
            ws.recv(timeout=2)
        assert e.value.rcvd.code == 1008


def test_new_audio_connection_replaces_old(source):
    src, q = source
    with connect(url(src)) as a:
        a.recv(timeout=2)
        with connect(url(src)) as b:
            b.recv(timeout=2)
            with pytest.raises(Exception):      # A is closed by the server
                while True:
                    a.recv(timeout=2)
            b.send(encode_frame(7, 0, 0, tone(1600)))
            assert q.get(timeout=2).samples.size == 1600
            assert next_of_type(b, "audio_ack")["offset"] == 1600


def test_rejected_frame_keeps_connection_open(source):
    src, q = source
    with connect(url(src)) as ws:
        ws.recv(timeout=2)
        ws.send(encode_frame(8, 0, 0, tone(1600)))
        rej = next_of_type(ws, "audio_reject")
        assert rej["meeting"] == "0000000000000007" and "meeting" in rej["reason"]
        ws.send(encode_frame(7, 0, 0, tone(1600)))
        assert q.get(timeout=2).samples.size == 1600


def test_finished_follows_watchdog(source):
    src, _ = source
    assert not src.finished
    src.stream.last_frame_at = time.monotonic() - 2000
    assert src.finished


def test_connection_after_stop_is_refused():
    src = PhoneSource(meeting=7, port=free_port(), token=TOKEN)
    src.start(queue.Queue())
    with src.lock:
        src._stopped.set()          # stop() is bezig, de server nog niet dicht
    with connect(url(src)) as ws:
        with pytest.raises(Exception) as e:     # geen audio_ready, meteen dicht
            ws.recv(timeout=2)
        assert e.value.rcvd.code == 1001
    assert src._ws is None
    src.stop()


def test_ready_comes_before_any_ack(source):
    src, q = source
    with connect(url(src)) as a:
        a.recv(timeout=2)
        a.send(encode_frame(7, 0, 0, tone(1600)))
        q.get(timeout=2)
        for _ in range(5):                      # reconnects terwijl de ack-draad elke seconde stuurt
            with connect(url(src)) as b:
                assert json.loads(b.recv(timeout=2))["type"] == "audio_ready"


def test_gap_before_first_frame_is_not_lost():
    s = PhoneStream(meeting=7)
    blocks = s.accept(encode_frame(7, 0, 8000, tone(1600)))    # telefoon begon een halve seconde later
    assert sum(len(b.samples) for b in blocks) == 8000 + 1600   # wel opgevuld: de tijdlijn klopt
    assert s.lost_s == 0


# --- Stop: leeglopen, watchdog, meta (Task 3) ---

from hint_meet.cli import handle_stop, phone_meta  # noqa: E402
from hint_meet.live import LiveSession  # noqa: E402


class FakeSession:
    def __init__(self, log, heard_s=10.0):
        self.log, self.heard_s = log, heard_s

    def stop(self):
        self.log.append("stop")


class FakePhone:
    def __init__(self, log, acked=10 ** 9):
        self.log = log
        self.stream = type("S", (), {"acked": acked})()

    def wait_acked(self, offset, timeout):
        self.log.append(("wait_acked", offset, timeout))
        return True


def test_stop_waits_for_final_offset_then_stops():
    log = []
    handle_stop({"type": "stop", "final_offset": 32000}, FakeSession(log), FakePhone(log))
    assert log == [("wait_acked", 32000, 60.0), "stop"]


@pytest.mark.parametrize("msg", [{"type": "stop"}, {"type": "stop", "final_offset": "x"},
                                 {"type": "stop", "final_offset": True}])
def test_stop_without_usable_final_offset_stops_at_once(msg):
    log = []
    handle_stop(msg, FakeSession(log), FakePhone(log))
    assert log == ["stop"]


def test_stop_drain_is_bounded():
    log = []
    t = time.monotonic()
    handle_stop({"final_offset": 32000}, FakeSession(log, heard_s=0.0), FakePhone(log), budget_s=0.3)
    assert log[-1] == "stop" and time.monotonic() - t < 1.0


def test_phone_meta_records_who_stopped():
    src = PhoneSource(meeting=0xAA, port=0, token=TOKEN)
    assert phone_meta(None) == {}
    assert phone_meta(src) == {"phone_meeting": "00000000000000aa"}
    assert phone_meta(src, watchdog=True)["stopped_by"] == "watchdog"
    assert phone_meta(src, watchdog=False)["stopped_by"] == "user"


def demo_speech(seconds):
    from pathlib import Path
    from hint_meet.audio import read_wav
    wav = Path(__file__).resolve().parent.parent / "examples" / "demo-meeting.wav"
    if not wav.exists():
        pytest.skip("examples/demo-meeting.wav ontbreekt (examples/make_demo_audio.py)")
    pcm = (np.clip(read_wav(wav).mean(axis=1), -1, 1) * 32767).astype(np.int16)
    return pcm[:int(16000 * seconds)]


class EnergyVAD:
    """Zonder onnxruntime in de snelle tests (dat breekt soms af bij het afsluiten van Python)."""
    def reset(self):
        pass

    def __call__(self, frame):
        return 1.0 if float(np.abs(frame).mean()) > 0.01 else 0.0


def test_stop_keeps_the_last_seconds(monkeypatch):
    import hint_meet.live
    monkeypatch.setattr(hint_meet.live, "SileroVAD", EnergyVAD)
    seen = []

    def transcriber(audio, channel=None):
        seen.append(len(audio))
        return ("woorden", 1.0)

    src = PhoneSource(meeting=7, port=free_port(), token=TOKEN)
    session = LiveSession([src], transcriber, pipeline=None)
    session._advise = lambda *a, **k: None          # geen pijplijn nodig
    pcm = demo_speech(3.0)
    import threading
    runner = threading.Thread(target=session.run)
    runner.start()
    try:
        time.sleep(0.5)                              # server luistert
        with connect(url(src)) as ws:
            ws.recv(timeout=2)
            for i in range(0, len(pcm), 1600):       # alles in één keer, sneller dan echte tijd
                ws.send(encode_frame(7, i // 1600, i, pcm[i:i + 1600]))
            handle_stop({"type": "stop", "final_offset": len(pcm)}, session, src)
    finally:
        session.stop()
        runner.join(timeout=30)
    assert session.heard_s * 16000 >= len(pcm)       # niets uit de wachtrij laten liggen
    assert session.processed_s * 16000 >= len(pcm)
    assert seen, "de laatste uitspraak werd niet meer herkend"
