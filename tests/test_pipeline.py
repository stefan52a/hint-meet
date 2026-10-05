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
    "advise": {"model": "m", "effort": "low", "max_points": 4},
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

    def evaluate(self, window, hits, previous_hint=None):
        self.seen.append((window, hits))
        self.previous = getattr(self, "previous", []) + [previous_hint]
        return GateResult(self.probs[len(self.seen) - 1], "vraag_aan_mij", 2)


class FakeAdvisor:
    def __init__(self, advice):
        self.advice = advice
        self.calls = 0

    def advise(self, window, moment, hits, on_text=None):
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
    """Nep voor messages.create (gate) en beta.messages.stream (advies)."""

    def __init__(self, payload=None, reply="", stop_reason="end_turn"):
        self.payload, self.reply, self.stop_reason, self.kwargs = payload, reply, stop_reason, None
        self.messages = self
        self.beta = NS(messages=self)

    def create(self, **kwargs):
        self.kwargs = kwargs
        return NS(stop_reason=self.stop_reason, content=[NS(type="text", text=json.dumps(self.payload))])

    def stream(self, **kwargs):
        self.kwargs = kwargs
        client = self

        class S:
            text_stream = [client.reply[i:i + 7] for i in range(0, len(client.reply), 7)]

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def get_final_message(self):
                return NS(stop_reason=client.stop_reason)

        return S()


def test_claude_gate_parses_and_clamps():
    client = FakeClient({"intervene_probability": 1.4, "moment": "vraag_aan_mij", "urgency": 3})
    r = ClaudeGate(CONFIG, client).evaluate(parse(TRANSCRIPT)[:2], [hit("rente.md")])
    assert r == GateResult(1.0, "vraag_aan_mij", 3)
    assert client.kwargs["output_config"]["format"]["type"] == "json_schema"
    assert "rente.md" in client.kwargs["messages"][0]["content"]


def test_advisor_streams_text_and_maps_numbers_to_sources():
    client = FakeClient(reply="Rente 3%, € 18.000 per jaar.\nBRONNEN: 1, 7")
    seen = []
    a = ClaudeAdvisor(CONFIG, client).advise(parse(TRANSCRIPT)[:2], "vraag_aan_mij",
                                             [hit("rente.md"), hit("ander.md")], on_text=seen.append)
    assert a.text == "Rente 3%, € 18.000 per jaar." and a.sources == ["rente.md"]  # 7 bestaat niet
    assert seen and "BRONNEN" not in seen[-1] and a.first_ms is not None
    assert client.kwargs["fallbacks"] == "default"


def test_advisor_none_reply_shows_nothing_and_never_streams():
    client = FakeClient(reply="GEEN")
    seen = []
    a = ClaudeAdvisor(CONFIG, client).advise([], "overig", [hit("rente.md")], on_text=seen.append)
    assert not a.shown and seen == []


def test_hint_starting_with_geen_is_kept():
    client = FakeClient(reply="Geen VPB: boekwinst valt weg tegen de verliesvoorraad.\nBRONNEN: 1")
    a = ClaudeAdvisor(CONFIG, client).advise([], "vraag_aan_mij", [hit("fiscaal.md")])
    assert a.shown and a.text.startswith("Geen VPB")


def test_advisor_without_sources_line_is_not_shown():
    client = FakeClient(reply="Een hint zonder bronregel.")
    assert not ClaudeAdvisor(CONFIG, client).advise([], "overig", [hit("rente.md")]).shown


def test_advisor_refusal_shows_nothing():
    client = FakeClient(reply="x\nBRONNEN: 1", stop_reason="refusal")
    assert not ClaudeAdvisor(CONFIG, client).advise([], "overig", [hit("rente.md")]).shown


def test_same_source_later_is_not_a_repeat():
    u = parse(TRANSCRIPT)
    adv = FakeAdvisor(Advice("Uit hetzelfde memo.", ["rente.md"]))
    steps = replay(u, Pipeline(FakeKB(), ScriptedGate([0.9, 0.1, 0.1, 0.9]), adv, CONFIG))
    assert steps[0].shown and steps[3].shown  # twee beurten verder: geen herhaling


def test_csv_written_when_replay_fails(tmp_path):
    u = parse(TRANSCRIPT)

    class Breaks(ScriptedGate):
        def evaluate(self, window, hits, previous_hint=None):
            if len(self.seen) == 2:
                raise RuntimeError("API weg")
            return super().evaluate(window, hits, previous_hint)

    out = tmp_path / "log.csv"
    with pytest.raises(RuntimeError):
        replay(u, Pipeline(FakeKB(), Breaks([0.1] * 4), FakeAdvisor(Advice("", [])), CONFIG), out)
    assert len(out.read_text(encoding="utf-8").splitlines()) == 3  # kop + 2 blokken


def test_gate_hears_about_hint_while_it_is_in_the_window():
    u = parse(TRANSCRIPT)
    gate = ScriptedGate([0.9, 0.1, 0.1, 0.1])
    replay(u, Pipeline(FakeKB(), gate, FakeAdvisor(Advice("Rente 3%.", ["rente.md"])), CONFIG))
    assert gate.previous == [None, "Rente 3%.", "Rente 3%.", None]  # window_turns = 3


def test_claude_gate_prompt_mentions_previous_hint():
    client = FakeClient({"intervene_probability": 0.2, "moment": "overig", "urgency": 0})
    ClaudeGate(CONFIG, client).evaluate(parse(TRANSCRIPT)[:2], [hit("rente.md")], "Rente 3%.")
    assert "Net getoonde hint: Rente 3%." in client.kwargs["messages"][0]["content"]


# Jev-gate en kalibratie

class FakeJevClient:
    def __init__(self, noul=0.8, choice="vraag_aan_mij", score=2.6):
        self.calls = []
        self.answer = NS(model="jev-1.13.0",
                         nouls={"hint_nodig": NS(noul=noul)},
                         choices={"moment": NS(choice=choice)},
                         scores={"urgentie": NS(score=score)})

    def system_one(self, state, questions, model=None):
        self.calls.append((state, questions, model))
        return self.answer


def test_jev_gate_maps_answers_and_keeps_state_small():
    pytest.importorskip("typesafe_sdk")
    from hint_meet.gate import JevGate
    client = FakeJevClient()
    gate = JevGate(CONFIG | {"gate": CONFIG["gate"] | {"jev_model": "jev-latest"}}, client)
    r = gate.evaluate(parse(TRANSCRIPT)[:2], [hit("rente.md", "3%")], "vorige hint")
    assert r == GateResult(0.8, "vraag_aan_mij", 3)
    state, questions, model = client.calls[0]
    assert state["onderste_beurt"] == "Maria: Wat is de rente op de schuld?"
    assert state["dossierpassages"][0]["document"] == "rente.md"
    assert state["net_getoonde_hint"] == "vorige hint"
    assert set(questions) == {"hint_nodig", "moment", "urgentie"} and model == "jev-latest"
    assert gate.last_model == "jev-1.13.0"


def test_sweep_counts_hits_and_noise():
    from hint_meet.calibrate import GateRow, sweep
    u = parse(TRANSCRIPT)  # gemarkeerd: index 1
    rows = [GateRow(0, 0.7, "x", 2, 1), GateRow(1, 0.5, "x", 2, 1), GateRow(2, 0.9, "x", 2, 1), GateRow(3, 0.2, "x", 2, 1)]
    assert sweep(u, rows, [0.4, 0.8]) == [(0.4, 1, 1, 1), (0.8, 1, 1, 0)]  # index 2 = beurt na het moment


def test_advisor_passes_thinking_setting():
    client = FakeClient(reply="x\nBRONNEN: 1")
    cfg = CONFIG | {"advise": CONFIG["advise"] | {"thinking": "between_tools"}}
    ClaudeAdvisor(cfg, client).advise([], "overig", [hit("rente.md")])
    assert client.kwargs["thinking"] == {"type": "between_tools"}
    ClaudeAdvisor(CONFIG, client).advise([], "overig", [hit("rente.md")])
    assert "thinking" not in client.kwargs


def test_no_streaming_right_after_a_shown_hint():
    u = parse(TRANSCRIPT)

    class Streams(FakeAdvisor):
        def __init__(self, advice):
            super().__init__(advice)
            self.streamed = []

        def advise(self, window, moment, hits, on_text=None):
            self.streamed.append(on_text is not None)
            return super().advise(window, moment, hits, on_text)

    adv = Streams(Advice("Rente 3%.", ["rente.md"]))
    replay_steps = Pipeline(FakeKB(), ScriptedGate([0.9, 0.9, 0.1, 0.9]), adv, CONFIG)
    for i in range(len(u)):
        replay_steps.step(u, i, on_text=lambda t: None)
    assert adv.streamed == [True, False, True]  # beurt 1 vlak na een hint: niet streamen
