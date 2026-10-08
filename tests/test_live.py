import queue
import time
import wave

import numpy as np
import pytest

from hint_meet.advise import Advice
from hint_meet.gate import GateResult
from hint_meet.audio import Transcriber
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
    session = LiveSession([], transcriber=lambda audio, speaker=None: ("tekst", 5.0), pipeline=pipe)
    session._handle(FakeSegment(), ready_at=time.monotonic() - 10)   # 10 s achter
    session._handle(FakeSegment(1), ready_at=time.monotonic())
    assert [e.stale for e in session.events] == [True, False]
    assert pipe.calls == 1 and len(session.utterances) == 2


def test_transcript_is_saved_in_replayable_format(tmp_path):
    from hint_meet.transcript import load
    session = LiveSession([], transcriber=lambda audio, speaker=None: ("Wat is de rente?", 5.0), pipeline=FakePipeline())
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


def test_pipeline_error_is_reported_and_the_meeting_continues():
    class Failing(FakePipeline):
        def step(self, history, index, on_text=None):
            self.calls += 1
            if self.calls == 1:
                raise TimeoutError("Jev te traag")
            return super().step(history, index, on_text)
    session = LiveSession([], transcriber=lambda audio, speaker=None: ("tekst", 5.0), pipeline=Failing())
    session._handle(FakeSegment(), ready_at=time.monotonic())
    session._handle(FakeSegment(1), ready_at=time.monotonic())
    assert "Jev te traag" in session.events[0].error and session.events[0].step is None
    assert session.events[1].error is None and session.events[1].step is not None


def test_transcript_keeps_flowing_while_the_pipeline_is_busy():
    import threading

    class Slow(FakePipeline):
        def step(self, history, index, on_text=None):
            time.sleep(0.5)
            if on_text:
                on_text("hint")
            return super().step(history, index, on_text)
    heard, texts = [], []
    session = LiveSession([], transcriber=lambda audio, speaker=None: ("tekst", 5.0), pipeline=Slow(),
                          on_utterance=lambda i, u: heard.append((i, time.monotonic())),
                          on_text=lambda partial, i: texts.append(i))
    session.worker = threading.Thread(target=session._pipeline_loop)
    session.worker.start()
    t = time.monotonic()
    session._handle(FakeSegment(), ready_at=t)
    session._handle(FakeSegment(1), ready_at=t)
    assert [i for i, _ in heard] == [0, 1] and heard[1][1] - t < 0.2   # niet 0,5 s op de pijplijn gewacht
    session.work.put(None)
    session.worker.join()
    assert [e.index for e in session.events] == [0, 1] and texts == [0, 1]
    assert session.events[1].pipe_wait_ms > 300                       # wachtte op de hint van uitspraak 0


class FakeWhisper:
    """Herkent altijd de taal van de spreker; met een vaste taal geeft hij de opgegeven zekerheid."""
    def __init__(self, logprob=-0.1):
        self.calls, self.logprob = [], logprob

    def transcribe(self, audio, path_or_hf_repo=None, language=None, **kw):
        self.calls.append(language)
        return {"text": "hallo daar", "language": "en" if language is None else language,
                "segments": [{"avg_logprob": -0.1 if language is None else self.logprob}]}


def multilingual(whisper):
    t = Transcriber.__new__(Transcriber)
    t.mlx_whisper, t.model, t.language, t.prompt, t.spoken = whisper, "m", None, None, {}
    return t


def test_multilingual_remembers_the_language_per_speaker():
    w = FakeWhisper()
    t = multilingual(w)
    for _ in range(6):
        t(np.zeros(16000 * 2), "Anna")
    t(np.zeros(16000 * 2), "Bob")
    # herkennen, 4 keer de onthouden taal, dan opnieuw herkennen; een nieuwe spreker wordt eerst herkend
    assert w.calls == [None, "en", "en", "en", "en", None, None]


def test_multilingual_detects_again_when_whisper_is_unsure():
    w = FakeWhisper(logprob=-1.2)   # onthouden taal past niet meer (spreker wisselde van taal)
    t = multilingual(w)
    t(np.zeros(16000 * 2), "Anna")
    t(np.zeros(16000 * 2), "Anna")
    t(np.zeros(16000 * 2), "Anna")
    assert w.calls == [None, "en", None, "en", None]   # herkenning was zekerder: die telt


def test_multilingual_keeps_the_surer_result_and_short_detections_count_briefly():
    class Unsure(FakeWhisper):
        def transcribe(self, audio, path_or_hf_repo=None, language=None, **kw):
            r = super().transcribe(audio, path_or_hf_repo, language, **kw)
            if language is None:   # herkenning gokt fout en is nog minder zeker
                r.update(language="fr", segments=[{"avg_logprob": -2.0}])
            return r
    w = Unsure(logprob=-0.8)
    t = multilingual(w)
    t.spoken["Anna"] = ("nl", 0)
    t(np.zeros(16000 * 2), "Anna")
    assert t.spoken["Anna"] == ("nl", 1)                      # Nederlands resultaat was zekerder: blijft
    t.spoken.clear()
    t(np.zeros(8000), "Bob")                                   # 0,5 s: herkenning telt maar één keer
    assert t.spoken["Bob"] == ("fr", Transcriber.RECHECK_EVERY - 1)


def test_fixed_language_never_detects():
    w = FakeWhisper(logprob=-3)
    t = multilingual(w)
    t.language = "nl"
    t(np.zeros(10), "Anna")
    assert w.calls == ["nl"]


def test_live_api_clients_have_short_timeouts(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test")
    from hint_meet.gate import claude_client
    c = claude_client(3)
    assert c.timeout == 3 and c.max_retries == 1


def test_pipeline_thread_survives_a_failing_callback_and_stop_skips_queued_advice():
    import threading
    calls = []

    def on_event(ev):
        calls.append(ev.index)
        if ev.index == 0:
            raise RuntimeError("fout in de app-koppeling")
    pipe = FakePipeline()
    session = LiveSession([], transcriber=lambda audio, speaker=None: ("tekst", 5.0), pipeline=pipe, on_event=on_event)
    session.worker = threading.Thread(target=session._pipeline_loop)
    session.worker.start()
    session._handle(FakeSegment(), ready_at=time.monotonic())
    session._handle(FakeSegment(1), ready_at=time.monotonic())
    session.work.put(None)
    session.worker.join()
    assert calls == [0, 1] and pipe.calls == 2              # na de fout liep de draad door
    session.worker = None                                   # zoals run() na afloop
    session.stop()
    session.on_event = None
    session._handle(FakeSegment(2), ready_at=time.monotonic())    # nog na Stop afgemaakt
    assert pipe.calls == 2 and session.events[-1].step is None   # alleen transcript, geen pijplijn meer


def test_stop_skips_advice_for_utterances_still_queued():
    import threading
    release = threading.Event()

    class Blocking(FakePipeline):
        def step(self, history, index, on_text=None):
            release.wait(5)   # hint voor uitspraak 0 is bezig
            return super().step(history, index, on_text)
    pipe = Blocking()
    session = LiveSession([], transcriber=lambda audio, speaker=None: ("tekst", 5.0), pipeline=pipe)
    session.worker = threading.Thread(target=session._pipeline_loop)
    session.worker.start()
    for i in range(3):
        session._handle(FakeSegment(i), ready_at=time.monotonic())
    time.sleep(0.1)
    session.stop()                 # 1 en 2 staan nog in de wachtrij
    release.set()
    session.work.put(None)
    session.worker.join()
    assert pipe.calls == 1                                           # de lopende hint maakt af, de rest niet
    assert [e.step is None for e in session.events] == [False, True, True]
