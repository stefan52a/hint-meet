"""Evaluatie van het zoeken: per vraag de rang van het eerste verwachte stuk in de top k."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import yaml

from .kb import KB


@dataclass
class Result:
    question: str
    expect: list[str]
    found: list[str]

    @property
    def rank(self) -> int | None:
        for i, ref in enumerate(self.found, 1):
            if ref in self.expect:
                return i
        return None


def load_questions(path: Path) -> dict:
    data = yaml.safe_load(Path(path).read_text(encoding="utf-8"))
    for v in data["vragen"]:
        if not v.get("expect"):
            raise ValueError(f"vraag zonder expect: {v.get('q')!r}")
    return data


def eval_kb(kb: KB, questions: list[dict], k: int = 5) -> list[Result]:
    return [Result(v["q"], v["expect"], kb.search_docs(v["q"], k=k)) for v in questions]


def report(results: list[Result], k: int) -> str:
    lines = []
    for r in results:
        mark = f"{r.rank}" if r.rank else "✗"
        lines.append(f"{mark:>2}  {r.question}")
        if not r.rank:
            lines.append(f"      verwacht: {', '.join(Path(e).name for e in r.expect)}")
            lines.append(f"      gevonden: {', '.join(Path(f).name for f in r.found)}")
    hits = sum(1 for r in results if r.rank)
    mrr = sum(1 / r.rank for r in results if r.rank) / len(results) if results else 0.0
    lines.append(f"\nTop {k}: {hits}/{len(results)} gevonden, MRR {mrr:.2f}")
    return "\n".join(lines)
