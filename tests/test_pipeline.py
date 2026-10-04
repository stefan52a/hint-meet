import json
from types import SimpleNamespace as NS

import pytest

from hint_meet.advise import Advice, ClaudeAdvisor
from hint_meet.gate import ClaudeGate, GateResult
from hint_meet.kb import Chunk, Hit
from hint_meet.pipeline import Pipeline
from hint_meet.replay import keyword_hits, replay, score
from hint_meet.transcript import parse

CONFIG = {
    "window_turns": 3,
    "gate": {"provider": "claude", "model": "m", "intervene_min": 0.6, "urgency_min": 1},
    "moments": ["vraag_aan_mij", "onjuiste_bewering", "smalltalk", "overig"],
    "kb": {"query_turns": 2, "gate_passages": 2, "advise_passages": 3},
    "advise": {"model": "m", "effort": "low", "max_sentences": 3},
}

TRANSCRIPT = """# kop
[00:00] Maria: Koffie?
[00:05] Maria: Wat is de rente op de schuld?
#! advies: 3%, 18.000 per jaar
[00:10] Stefan: Moment.
[00:15] Maria: Mooi weer vandaag.
"""


def hit(ref, text="tekst"):
    return Hit(Chunk(ref, "", text), 1.0, 0, 0)


class FakeKB:
    def search(self, query, k=5):
        return [hit("rente.md"), hit("ander.md"), hit("derde.md")][:k]


class ScriptedGate:
    def __init__(self, probs):
        self.probs = probs
        self.seen = []

    def evaluate(self, window, hits):
        self.seen.append((window, hits))
        return GateResult(self.probs[len(self.seen) - 1], "vraag_aan_mij", 2)


class FakeAdvisor:
    def __init__(self, advice):
        self.advice = advice
        self.calls = 0

    def advise(self, window, moment, hits):
        self.calls += 1
        return self.advice


def test_parse_transcript_with_markers():
    u = parse(TRANSCRIPT)
    assert [x.speaker for x in u] == ["Maria", "Maria", "Stefan", "Maria"]
    assert u[1].seconds == 5 and u[1].expect == "3%, 18.000 per jaar"
    assert u[0].expect is None and u[2].expect is None


def test_closed_gate_means_no_advice_call():
    u = parse(TRANSCRIPT)
    adv = FakeAdvisor(Advice("x", ["rente.md"]))
    steps = replay(u, Pipeline(FakeKB(), ScriptedGate([0.1] * 4), adv, CONFIG))
    assert adv.calls == 0 and not any(s.shown for s in steps)


def test_gate_sees_window_and_limited_passages():
    u = parse(TRANSCRIPT)
    gate = ScriptedGate([0.1] * 4)
    replay(u, Pipeline(FakeKB(), gate, FakeAdvisor(Advice("", [])), CONFIG))
    window, hits = gate.seen[3]
    assert [x.text for x in window] == ["Wat is de rente op de schuld?", "Moment.", "Mooi weer vandaag."]
    assert len(hits) == 2


def test_open_gate_shows_advice_and_scores_hit():
    u = parse(TRANSCRIPT)
    adv = FakeAdvisor(Advice("Rente 3%, € 18.000 per jaar.", ["rente.md"]))
    steps = replay(u, Pipeline(FakeKB(), ScriptedGate([0.1, 0.9, 0.1, 0.1]), adv, CONFIG))
    s = score(u, steps)
    assert s.hits == [1] and s.missed == [] and s.false_pos == []
    assert s.keyword_rate == 1.0


def test_advice_without_source_is_suppressed():
    u = parse(TRANSCRIPT)
    steps = replay(u, Pipeline(FakeKB(), ScriptedGate([0.1, 0.9, 0.1, 0.1]),
                               FakeAdvisor(Advice("Iets zonder bron.", [])), CONFIG))
    assert steps[1].suppressed == "geen bron" and not steps[1].shown


def test_repeated_advice_on_next_turn_is_suppressed():
    u = parse(TRANSCRIPT)
    adv = FakeAdvisor(Advice("Rente 3%.", ["rente.md"]))
    steps = replay(u, Pipeline(FakeKB(), ScriptedGate([0.1, 0.9, 0.9, 0.1]), adv, CONFIG))
    assert steps[1].shown and steps[2].suppressed == "herhaling"
    assert score(u, steps).false_pos == []


def test_noise_advice_counts_as_false_positive():
    u = parse(TRANSCRIPT)
    adv = FakeAdvisor(Advice("Over het weer.", ["ander.md"]))
    steps = replay(u, Pipeline(FakeKB(), ScriptedGate([0.9, 0.1, 0.1, 0.1]), adv, CONFIG))
    s = score(u, steps)
    assert s.false_pos == [0] and s.missed == [1]


def test_keyword_hits_normalises_amounts():
    assert keyword_hits("3%, 18.000 per jaar", "Rente is 3%, dat is 18000 per jaar.") == (2, 2)
    assert keyword_hits("geen VPB, verliesverrekening", "Er is geen vpb.") == (1, 2)


# Claude-aanroepen met een nep-client

class FakeClient:
    def __init__(self, payload, stop_reason="end_turn"):
        self.payload, self.stop_reason, self.kwargs = payload, stop_reason, None
        self.messages = self
        self.beta = NS(messages=self)

    def create(self, **kwargs):
        self.kwargs = kwargs
        return NS(stop_reason=self.stop_reason, content=[NS(type="text", text=json.dumps(self.payload))])


def test_claude_gate_parses_and_clamps():
    client = FakeClient({"intervene_probability": 1.4, "moment": "vraag_aan_mij", "urgency": 3})
    r = ClaudeGate(CONFIG, client).evaluate(parse(TRANSCRIPT)[:2], [hit("rente.md")])
    assert r == GateResult(1.0, "vraag_aan_mij", 3)
    assert client.kwargs["output_config"]["format"]["type"] == "json_schema"
    assert "rente.md" in client.kwargs["messages"][0]["content"]


def test_advisor_drops_invented_sources():
    client = FakeClient({"hint": "Rente 3%.", "sources": ["rente.md", "verzonnen.md"]})
    a = ClaudeAdvisor(CONFIG, client).advise(parse(TRANSCRIPT)[:2], "vraag_aan_mij", [hit("rente.md")])
    assert a.sources == ["rente.md"] and a.shown
    assert client.kwargs["fallbacks"] == "default"


def test_advisor_refusal_shows_nothing():
    client = FakeClient({"hint": "x", "sources": ["rente.md"]}, stop_reason="refusal")
    assert not ClaudeAdvisor(CONFIG, client).advise([], "overig", [hit("rente.md")]).shown
