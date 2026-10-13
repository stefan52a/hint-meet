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


def test_open_gate_gives_hint_and_left_column_too():
    conf = FakeConfirmer(Advice("x", ["rente.md"]))
    p = Pipeline(FakeKB(), ScriptedGate([0.9]), FakeAdvisor(Advice("Hint", ["rente.md"])), CCONFIG, confirmer=conf)
    got = []
    step = p.step(TALK[:1], 0, on_confirm=lambda i, c: got.append(i))
    p.confirm_pool.shutdown(wait=True)
    assert step.shown and got == [0]   # de gate bepaalt alleen de hint rechts


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
    reply = "KLOPT: Koopprijs € 2,1 mln (art. 3)\nToelichting.\nBRONNEN: 2, 9"
    client.create = lambda **kw: (setattr(client, "kwargs", kw)
                                  or NS(stop_reason="end_turn", content=[NS(type="text", text=reply)]))
    c = ClaudeConfirmer(CCONFIG, client).confirm(TALK[:1], [hit("rente.md"), hit("koop.md")])
    assert c.text == "Koopprijs € 2,1 mln (art. 3)" and c.sources == ["koop.md"] and c.kind == "confirms"
    assert client.kwargs["model"] == "claude-haiku-5-5"


def test_claude_confirmer_none_reply_is_not_shown():
    client = FakeClient()
    client.create = lambda **kw: NS(stop_reason="end_turn", content=[NS(type="text", text="GEEN")])
    assert not ClaudeConfirmer(CCONFIG, client).confirm(TALK[:1], [hit("rente.md")]).shown



def test_reranker_failure_skips_confirmation_instead_of_unfiltered():
    class Down:
        def score(self, question, passages):
            return None   # Jev niet beschikbaar: dan ook geen injectiecheck
    conf = FakeConfirmer(Advice("Klopt", ["rente.md"]))
    p = Pipeline(FakeKB(), ScriptedGate([0.1]), FakeAdvisor(Advice("", [])), CCONFIG, Down(), confirmer=conf)
    assert run(p) == [] and conf.hits is None


def test_reranker_timeout_skips_confirmation():
    import time

    class Slow:
        def score(self, question, passages):
            time.sleep(0.3)
            return [PassageScore(0.9, 0.0)] * len(passages)
    conf = FakeConfirmer(Advice("Klopt", ["rente.md"]))
    config = {**CCONFIG, "confirm": {**CCONFIG["confirm"], "rerank_timeout_s": 0.05}}
    p = Pipeline(FakeKB(), ScriptedGate([0.1]), FakeAdvisor(Advice("", [])), config, Slow(), confirmer=conf)
    assert run(p) == [] and conf.hits is None


def test_stale_confirmation_is_dropped():
    conf = FakeConfirmer(Advice("Klopt", ["rente.md"]))
    config = {**CCONFIG, "confirm": {**CCONFIG["confirm"], "max_age_s": -1}}
    p = Pipeline(FakeKB(), ScriptedGate([0.1]), FakeAdvisor(Advice("", [])), config, confirmer=conf)
    assert run(p) == [] and conf.hits is None


def test_full_confirmer_skips_new_utterances_and_frees_slots_after():
    import threading
    release = threading.Event()

    class Blocking(FakeConfirmer):
        def confirm(self, window, hits):
            release.wait(2)
            return super().confirm(window, hits)
    conf = Blocking(Advice("Klopt", ["rente.md"]))
    talk = parse("# kop\n" + "".join(f"[00:0{i}] Maria: De koopprijs is twee miljoen euro.\n" for i in range(4)))
    p = Pipeline(FakeKB(), ScriptedGate([0.1] * 4), FakeAdvisor(Advice("", [])), CCONFIG, confirmer=conf)
    got = []
    for i in range(3):   # twee lopen, de derde past er niet meer bij
        p.step(talk[:i + 1], i, on_confirm=lambda idx, c: got.append(idx))
    release.set()
    p.confirm_pool.shutdown(wait=True)
    assert sorted(got) == [0, 1]
    assert p.confirm_slots.acquire(blocking=False) and p.confirm_slots.acquire(blocking=False)   # weer vrij


def test_late_confirmation_after_slow_claude_call_is_dropped():
    import time

    class SlowConfirmer(FakeConfirmer):
        def confirm(self, window, hits):
            time.sleep(0.2)
            return super().confirm(window, hits)
    conf = SlowConfirmer(Advice("Klopt", ["rente.md"]))
    config = {**CCONFIG, "confirm": {**CCONFIG["confirm"], "max_age_s": 0.1}}
    p = Pipeline(FakeKB(), ScriptedGate([0.1]), FakeAdvisor(Advice("", [])), config, confirmer=conf)
    assert run(p) == [] and conf.hits is not None   # wel gevraagd, maar te laat voor de kolom


def test_sensitivity_midpoint_keeps_yaml_and_moves_thresholds():
    import math

    import pytest

    from hint_meet.pipeline import Sensitivity
    config = {"gate": {"intervene_min": 0.97, "urgency_min": 1}, "rerank": {"min_relevance": 0.5},
              "confirm": {"min_relevance": 0.6, "min_words": 4, "passages": 3}}
    s = Sensitivity(config)
    s.set_hints(0.5)
    s.set_confirm(0.5)
    assert config["gate"] == {"intervene_min": 0.97, "urgency_min": 1}   # ook een ongewone yaml-waarde blijft staan
    assert config["rerank"]["min_relevance"] == 0.5
    assert config["confirm"] == {"min_relevance": 0.6, "min_words": 4, "passages": 3}
    s.set_hints(1)        # meer hints: drempels op 0, urgentie telt niet meer
    s.set_confirm(1)      # meer bevestigingen, met meer passages
    assert config["gate"] == {"intervene_min": 0.0, "urgency_min": 0} and config["rerank"]["min_relevance"] == 0.0
    assert config["confirm"] == {"min_relevance": 0.0, "min_words": 1, "passages": 5}
    s.set_hints(0)
    s.set_confirm(0)
    # yaml 0.97 ligt boven het uiterste 0.95: "minder" blijft dan 0.97 in plaats van soepeler te worden
    assert config["gate"] == {"intervene_min": 0.97, "urgency_min": 1} and config["rerank"]["min_relevance"] == 0.9
    assert config["confirm"] == {"min_relevance": 0.95, "min_words": 10, "passages": 3}
    s.set_hints(0.75)     # halverwege tussen yaml en het uiterste; vanaf hier zonder minimale urgentie
    assert config["rerank"]["min_relevance"] == 0.25 and config["gate"]["urgency_min"] == 0
    s.set_hints(7)        # onzin van de app wordt begrensd
    assert config["gate"]["intervene_min"] == 0.0
    with pytest.raises(ValueError):
        s.set_hints(math.nan)

def fixed_reply(text):
    client = FakeClient()
    client.create = lambda **kw: NS(stop_reason="end_turn", content=[NS(type="text", text=text)])
    return client


def test_claude_confirmer_about_topic():
    c = ClaudeConfirmer(CCONFIG, fixed_reply("DOSSIER: Art. 19.4: schadepenningen boven 1% op aparte rekening\nBRONNEN: 1"))
    a = c.confirm(TALK[:1], [hit("reglement.md")])
    assert a.shown and a.kind == "about" and a.text.startswith("Art. 19.4")


def test_claude_confirmer_without_kind_label_is_not_shown():
    c = ClaudeConfirmer(CCONFIG, fixed_reply("Koopprijs € 2,1 mln\nBRONNEN: 1"))
    assert not c.confirm(TALK[:1], [hit("koop.md")]).shown


def test_most_relevant_passages_go_to_the_confirmer_first():
    conf = FakeConfirmer(Advice("Klopt", ["derde.md"]))
    rr = FixedReranker({"rente.md": PassageScore(0.65, 0.0), "ander.md": PassageScore(0.7, 0.0),
                        "derde.md": PassageScore(0.95, 0.0)})
    config = {**CCONFIG, "confirm": {**CCONFIG["confirm"], "passages": 2}}
    p = Pipeline(FakeKB(), ScriptedGate([0.1]), FakeAdvisor(Advice("", [])), config, rr, confirmer=conf)
    run(p)
    assert conf.hits == ["derde.md", "ander.md"]



def test_language_can_change_during_the_meeting():
    from hint_meet.advise import ClaudeAdvisor
    config = {**CCONFIG, "advise": {**CCONFIG["advise"], "language": "nl"}}
    adv = ClaudeAdvisor(config, FakeClient())
    conf = ClaudeConfirmer(config, FakeClient())
    p = Pipeline(FakeKB(), ScriptedGate([0.1]), adv, config, confirmer=conf)
    assert "Dutch" in adv.system and "Dutch" in conf.system
    p.set_language("en")
    assert "English" in adv.system and "Dutch" not in adv.system and "English" in conf.system
    assert config["advise"]["language"] == "en"
    p.set_language(None)   # meertalig: de taal van het gesprek
    assert "laatste beurten" in adv.system
