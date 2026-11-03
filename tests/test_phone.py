import numpy as np
import pytest

from hint_meet.phone import FrameError, PhoneStream, encode_frame


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
