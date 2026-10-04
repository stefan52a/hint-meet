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
    write_wav(tmp_path / "mono.wav", channels=1)
    with pytest.raises(ValueError, match="1 kanalen, maar 2"):
        WavSource(tmp_path / "mono.wav", ["Stefan", "Ander"])


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
