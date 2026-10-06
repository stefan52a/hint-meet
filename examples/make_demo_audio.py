"""Speaks examples/demo-meeting.txt with English macOS voices into a stereo WAV (Stefan left, Anna right),
to try HintMeet with Play Recording… or `hint-meet --project demo live --audio examples/demo-meeting.wav
--channels Stefan,Anna --language en`."""
from pathlib import Path

from hint_meet.testaudio import render
from hint_meet.transcript import load

HERE = Path(__file__).parent

if __name__ == "__main__":
    out = HERE / "demo-meeting.wav"
    render(load(HERE / "demo-meeting.txt"), out, me="Stefan", voices={"Stefan": "Daniel", "Anna": "Samantha"})
    print(f"Demo meeting audio in {out}")
