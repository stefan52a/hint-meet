import json
import threading
from types import SimpleNamespace as NS

import pytest

from hint_meet import usage


def ledger(tmp_path):
    return json.loads((tmp_path / "usage.json").read_text())


def test_claude_cost_uses_the_model_that_answered_and_counts_cache(tmp_path):
    u = NS(input_tokens=1_000_000, output_tokens=100_000, cache_creation_input_tokens=0, cache_read_input_tokens=0)
    usage.record_claude(NS(model="claude-sonnet-5-5", usage=u), "claude-opus-5-5")   # fallback antwoordde
    assert ledger(tmp_path)["anthropic"]["usd"] == pytest.approx(2.0 + 1.0)
    cached = NS(input_tokens=0, output_tokens=0, cache_creation_input_tokens=1_000_000, cache_read_input_tokens=1_000_000)
    assert usage.claude_cost("claude-opus-5-5", cached) == pytest.approx(4 * 1.25 + 4 * 0.1)


def test_jev_counts_input_tokens_only(tmp_path):
    usage.record_jev(NS(usage=NS(input_tokens=2_000_000, output_tokens=500)))
    j = ledger(tmp_path)["jev"]
    assert j["usd"] == pytest.approx(0.084) and j["calls"] == 1 and j["output_tokens"] == 500


def test_unknown_model_or_missing_usage_is_not_counted_and_never_raises(tmp_path):
    usage.record_claude(NS(model="claude-new-9", usage=NS(input_tokens=10, output_tokens=10)), "claude-new-9")
    usage.record_claude(NS(), "claude-opus-5-5")
    usage.record_jev(object())
    assert not (tmp_path / "usage.json").exists()


def test_prices_from_config_override_the_defaults(tmp_path):
    usage.configure({"costs": {"claude": {"claude-new-9": [1, 2]}, "jev_input": 1.0}})
    try:
        usage.record_claude(NS(model="claude-new-9", usage=NS(input_tokens=1_000_000, output_tokens=0)), "x")
        usage.record_jev(NS(usage=NS(input_tokens=1_000_000, output_tokens=0)))
        assert ledger(tmp_path)["anthropic"]["usd"] == pytest.approx(1.0)
        assert ledger(tmp_path)["jev"]["usd"] == pytest.approx(1.0)
    finally:
        usage.configure({})


def test_concurrent_records_all_add_up(tmp_path):
    r = NS(usage=NS(input_tokens=1_000_000, output_tokens=0))
    threads = [threading.Thread(target=usage.record_jev, args=(r,)) for _ in range(20)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert ledger(tmp_path)["jev"]["calls"] == 20
