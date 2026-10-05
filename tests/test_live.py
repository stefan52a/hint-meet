import queue
import time
import wave

import numpy as np
import pytest

from hint_meet.advise import Advice
from hint_meet.gate import GateResult
from hint_meet.live import LiveSession, WavSource
from hint_meet.pipeline import Step


def write_wav(path, channels=2, seconds=0.5):
    data = np.zeros((int(16000 * seconds), channels), dtype=np.int16)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(data.tobytes())


def test_wav_source_rejects_wrong_channel_count(tmp_path):
    write_wav(tmp_path / "stereo.wav", channels=2)
    with pytest.raises(ValueError, match="2 kanalen, maar 3"):
        WavSource(tmp_path / "stereo.wav", ["a", "b", "c"])


def test_mono_recording_becomes_one_conversation_channel(tmp_path):
    write_wav(tmp_path / "mono.wav", channels=1)
    assert WavSource(tmp_path / "mono.wav", ["Stefan", "Ander"]).labels == ["Gesprek"]


def test_mp3_is_decoded_to_16k(tmp_path):
    import shutil
    import subprocess
    if not shutil.which("ffmpeg"):
        pytest.skip("ffmpeg ontbreekt")
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1:sample_rate=44100",
                    str(tmp_path / "t.mp3")], check=True)
    from hint_meet.audio import read_wav
    data = read_wav(tmp_path / "t.mp3")
    assert data.shape[1] == 1 and 15000 < len(data) < 17500 and data.dtype == np.float32
    assert WavSource(tmp_path / "t.mp3", ["Stefan", "Ander"]).labels == ["Gesprek"]


def test_missing_or_unreadable_file_gives_clear_error(tmp_path):
    from hint_meet.audio import read_wav
    with pytest.raises(ValueError, match="niet gevonden"):
        read_wav(tmp_path / "weg.mp3")
    (tmp_path / "kapot.mp3").write_bytes(b"geen audio")
    with pytest.raises(ValueError):
        read_wav(tmp_path / "kapot.mp3")


@pytest.mark.parametrize("speed", [0, -1, float("inf"), float("nan")])
def test_wav_source_rejects_bad_speed(tmp_path, speed):
    write_wav(tmp_path / "s.wav")
    with pytest.raises(ValueError, match="positief"):
        WavSource(tmp_path / "s.wav", ["a", "b"], speed)


def test_wav_source_finishes_and_feeds_both_channels(tmp_path):
    write_wav(tmp_path / "s.wav", seconds=0.2)
    src = WavSource(tmp_path / "s.wav", ["a", "b"], speed=50)
    q = queue.Queue()
    src.start(q)
    src.thread.join(timeout=5)
    assert src.finished
    labels = {q.get().channel for _ in range(q.qsize())}
    assert labels == {"a", "b"}


class Boom:
    label = "x"

    def __init__(self):
        self.stopped = False

    def start(self, q):
        raise RuntimeError("apparaat weg")

    def stop(self):
        self.stopped = True


class Ok(Boom):
    def start(self, q):
        pass


def test_first_source_is_closed_when_second_fails():
    first, second = Ok(), Boom()
    session = LiveSession([first, second], transcriber=None, pipeline=None)
    with pytest.raises(RuntimeError):
        session.run(until=lambda: True)
    assert first.stopped and second.stopped


class FakeSegment:
    def __init__(self, start=0.0):
        self.start, self.channel, self.audio = start, "Stefan", np.zeros(10)


class FakePipeline:
    def __init__(self):
        self.calls = 0

    def step(self, history, index, on_text=None):
        self.calls += 1
        return Step(index, GateResult(0.1, "overig", 0), [], advice=None)


def test_stale_utterance_is_transcribed_but_not_advised():
    pipe = FakePipeline()
    session = LiveSession([], transcriber=lambda audio: ("tekst", 5.0), pipeline=pipe)
    session._handle(FakeSegment(), ready_at=time.monotonic() - 10)   # 10 s achter
    session._handle(FakeSegment(1), ready_at=time.monotonic())
    assert [e.stale for e in session.events] == [True, False]
    assert pipe.calls == 1 and len(session.utterances) == 2


def test_transcript_is_saved_in_replayable_format(tmp_path):
    from hint_meet.transcript import load
    session = LiveSession([], transcriber=lambda audio: ("Wat is de rente?", 5.0), pipeline=FakePipeline())
    session._handle(FakeSegment(65), ready_at=time.monotonic())
    session.save_transcript(tmp_path / "t.txt")
    u = load(tmp_path / "t.txt")
    assert len(u) == 1 and u[0].seconds == 65 and u[0].text == "Wat is de rente?"


def test_float_wav_falls_back_to_ffmpeg(tmp_path):
    import shutil
    import subprocess
    if not shutil.which("ffmpeg"):
        pytest.skip("ffmpeg ontbreekt")
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1:sample_rate=48000",
                    "-c:a", "pcm_f32le", str(tmp_path / "f.wav")], check=True)
    from hint_meet.audio import read_wav
    data = read_wav(tmp_path / "f.wav")
    assert data.shape[1] == 1 and 15000 < len(data) < 17000


def test_m4a_is_decoded(tmp_path):
    import shutil
    import subprocess
    if not shutil.which("ffmpeg"):
        pytest.skip("ffmpeg ontbreekt")
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
                    "-ac", "2", "-c:a", "aac", str(tmp_path / "t.m4a")], check=True)
    from hint_meet.audio import read_wav
    assert read_wav(tmp_path / "t.m4a").shape[1] == 2


def test_missing_ffmpeg_gives_clear_error(tmp_path, monkeypatch):
    import shutil
    from hint_meet.audio import read_wav
    (tmp_path / "x.mp3").write_bytes(b"x")
    monkeypatch.setattr(shutil, "which", lambda name: None)
    with pytest.raises(ValueError, match="ffmpeg en ffprobe nodig"):
        read_wav(tmp_path / "x.mp3")
