"""Transcript als tekst: "[mm:ss] Spreker: tekst", met optioneel "#! advies: ..." eronder."""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

LINE = re.compile(r"\[(\d+):(\d{2})\]\s*([^:]+):\s*(.+)")


@dataclass
class Utterance:
    seconds: int
    speaker: str
    text: str
    expect: str | None = None  # kernfeiten als hier advies hoort (alleen in testtranscripten)

    def __str__(self) -> str:
        return f"{self.speaker}: {self.text}"


def parse(text: str) -> list[Utterance]:
    out: list[Utterance] = []
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("#!"):
            m = re.match(r"#!\s*advies:\s*(.*)", line)
            if m and out:
                out[-1].expect = m.group(1).strip()
            continue
        if not line or line.startswith("#"):
            continue
        m = LINE.match(line)
        if m:
            out.append(Utterance(int(m.group(1)) * 60 + int(m.group(2)), m.group(3).strip(), m.group(4).strip()))
    return out


def load(path: Path) -> list[Utterance]:
    return parse(Path(path).read_text(encoding="utf-8"))
