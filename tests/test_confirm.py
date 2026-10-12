from types import SimpleNamespace as NS

from hint_meet.advise import Advice
from hint_meet.confirm import ClaudeConfirmer
from hint_meet.gate import GateResult
from hint_meet.pipeline import Pipeline
from hint_meet.rerank import PassageScore
from hint_meet.transcript import parse

from test_pipeline import CONFIG, FakeAdvisor, FakeClient, FakeKB, ScriptedGate, hit
from test_rerank import FixedReranker

CCONFIG = {**CONFIG, "rerank": {"max_injection": 0.5},
           "confirm": {"min_words": 4, "min_relevance": 0.6, "passages": 3}}

TALK = parse("""# kop
[00:00] Maria: De koopprijs is twee komma een miljoen euro.
[00:05] Maria: Ja.
""")


class FakeConfirmer:
    def __init__(self, advice):
        self.advice = advice
        self.hits = None

    def confirm(self, window, hits):
        self.hits = [h.chunk.ref for h in hits]
        return self.advice


class SmalltalkGate(ScriptedGate):
    def evaluate(self, window, hits, previous_hint=None):
        super().evaluate(window, hits, previous_hint)
        return GateResult(0.1, "smalltalk", 0)


def run(pipeline, index=0):
    got = []
    pipeline.step(TALK[:index + 1], index, on_confirm=lambda i, c: got.append((i, c.text, c.sources)))
    if pipeline.confirm_pool:
        pipeline.confirm_pool.shutdown(wait=True)   # de bevestiging draait op de achtergrond
    return got


def test_closed_gate_confirms_backed_statement():
    conf = FakeConfirmer(Advice("Koopprijs € 2,1 mln", ["rente.md"]))
    p = Pipeline(FakeKB(), ScriptedGate([0.1]), FakeAdvisor(Advice("", [])), CCONFIG, confirmer=conf)
    assert run(p) == [(0, "Koopprijs € 2,1 mln", ["rente.md"])]


def test_open_gate_gives_hint_not_confirmation():
    conf = FakeConfirmer(Advice("x", ["rente.md"]))
    p = Pipeline(FakeKB(), ScriptedGate([0.9]), FakeAdvisor(Advice("Hint", ["rente.md"])), CCONFIG, confirmer=conf)
    assert run(p) == [] and conf.hits is None


def test_smalltalk_and_short_utterances_are_skipped():
    conf = FakeConfirmer(Advice("x", ["rente.md"]))
    p = Pipeline(FakeKB(), SmalltalkGate([0.1]), FakeAdvisor(Advice("", [])), CCONFIG, confirmer=conf)
    assert run(p) == []
    p = Pipeline(FakeKB(), ScriptedGate([0.1, 0.1]), FakeAdvisor(Advice("", [])), CCONFIG, confirmer=conf)
    assert run(p, index=1) == [] and conf.hits is None   # "Ja." heeft te weinig woorden


def test_confirmation_without_source_is_not_shown():
    conf = FakeConfirmer(Advice("Klopt", []))
    p = Pipeline(FakeKB(), ScriptedGate([0.1]), FakeAdvisor(Advice("", [])), CCONFIG, confirmer=conf)
    assert run(p) == []


def test_reranker_keeps_only_relevant_passages_for_confirmation():
    conf = FakeConfirmer(Advice("Klopt", ["ander.md"]))
    rr = FixedReranker({"ander.md": PassageScore(0.9, 0.0), "derde.md": PassageScore(0.9, 0.9)})
    p = Pipeline(FakeKB(), ScriptedGate([0.1]), FakeAdvisor(Advice("", [])), CCONFIG, rr, confirmer=conf)
    assert run(p) == [(0, "Klopt", ["ander.md"])] and conf.hits == ["ander.md"]   # derde.md: injectie


def test_nothing_relevant_means_no_claude_call():
    conf = FakeConfirmer(Advice("Klopt", ["rente.md"]))
    p = Pipeline(FakeKB(), ScriptedGate([0.1]), FakeAdvisor(Advice("", [])), CCONFIG, FixedReranker({}),
                 confirmer=conf)
    assert run(p) == [] and conf.hits is None


def test_failing_confirmer_does_not_break_the_pipeline():
    class Broken:
        def confirm(self, window, hits):
            raise TimeoutError("traag")
    p = Pipeline(FakeKB(), ScriptedGate([0.1]), FakeAdvisor(Advice("", [])), CCONFIG, confirmer=Broken())
    assert run(p) == []


def test_claude_confirmer_keeps_one_line_and_maps_sources():
    client = FakeClient()
    reply = "- Koopprijs € 2,1 mln (art. 3)\nToelichting.\nBRONNEN: 2, 9"
    client.create = lambda **kw: (setattr(client, "kwargs", kw)
                                  or NS(stop_reason="end_turn", content=[NS(type="text", text=reply)]))
    c = ClaudeConfirmer(CCONFIG, client).confirm(TALK[:1], [hit("rente.md"), hit("koop.md")])
    assert c.text == "Koopprijs € 2,1 mln (art. 3)" and c.sources == ["koop.md"]
    assert client.kwargs["model"] == "claude-haiku-5-5"


def test_claude_confirmer_none_reply_is_not_shown():
    client = FakeClient()
    client.create = lambda **kw: NS(stop_reason="end_turn", content=[NS(type="text", text="GEEN")])
    assert not ClaudeConfirmer(CCONFIG, client).confirm(TALK[:1], [hit("rente.md")]).shown

