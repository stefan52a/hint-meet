"""Wat de API-aanroepen kosten, opgeteld per dienst, zodat de app kan tonen hoeveel tegoed er nog is.

Anthropic en Jev geven het resterende tegoed niet via de API. Daarom telt hint-meet zelf: na elke aanroep de
tokens uit het antwoord maal de prijs (config/gate.yaml, costs; anders de standaard hieronder), opgeteld in één
bestand voor alle processen (meeting, Find Documents, verslag). De app trekt dat af van het tegoed dat je in
Settings invult. Alleen het gebruik van hint-meet zelf: andere apps met dezelfde sleutel ziet dit niet.

Het bestand: {"anthropic": {"usd": .., "input_tokens": .., "output_tokens": .., "calls": ..}, "jev": {..},
"updated": "2026-10-23T10:00:00"}. Tellen mag nooit een hint of de meeting kosten: elke fout wordt ingeslikt.
"""
from __future__ import annotations

import fcntl
import json
import os
import sys
import time
from pathlib import Path

LEDGER = Path("~/Library/Application Support/hint-meet/usage.json").expanduser()

# USD per miljoen tokens (invoer, uitvoer), Anthropic-prijzen van oktober 2026. Claude Haiku 5.5 is boven 100K
# tokens invoer duurder; zulke lange prompts maakt hint-meet niet.
CLAUDE_PRICES = {
    "claude-haiku-4-5": (1.00, 5.00),
    "claude-haiku-5-5": (0.10, 0.50),
    "claude-sonnet-4-6": (3.00, 15.00),
    "claude-sonnet-5": (2.00, 10.00),
    "claude-sonnet-5-5": (2.00, 10.00),
    "claude-opus-5": (5.00, 25.00),
    "claude-opus-5-5": (4.00, 20.00),
}
CACHE_WRITE, CACHE_READ = 1.25, 0.10   # maal de invoerprijs
JEV_INPUT_PRICE = 0.042   # USD per miljoen invoertokens; uitvoer is gratis

_prices: dict = {}      # overschreven door configure() met costs uit gate.yaml
_unknown: set[str] = set()


def configure(config: dict):
    """Prijzen uit config/gate.yaml (costs: {claude: {model: [in, out]}, jev_input: ..}), als die er staan."""
    costs = config.get("costs") or {}
    _prices.clear()
    _prices.update({m: tuple(p) for m, p in (costs.get("claude") or {}).items()})
    if "jev_input" in costs:
        _prices["jev"] = float(costs["jev_input"])


def ledger_path() -> Path:
    return Path(os.environ["HINT_MEET_USAGE"]) if os.environ.get("HINT_MEET_USAGE") else LEDGER


def claude_cost(model: str, usage) -> float | None:
    """USD voor één Claude-antwoord; None bij een onbekend model (dan liever niets dan een verkeerd bedrag)."""
    price = _prices.get(model) or CLAUDE_PRICES.get(model)
    if price is None:
        return None
    p_in, p_out = price
    tokens = lambda name: int(getattr(usage, name, 0) or 0)   # noqa: E731
    return (tokens("input_tokens") * p_in + tokens("cache_creation_input_tokens") * p_in * CACHE_WRITE
            + tokens("cache_read_input_tokens") * p_in * CACHE_READ + tokens("output_tokens") * p_out) / 1e6


def record_claude(response, requested_model: str):
    """Na een Claude-aanroep (ook de final message van een stream). Met fallbacks kan een ander model antwoorden:
    dan telt de prijs van dat model."""
    try:
        usage = getattr(response, "usage", None)
        if usage is None:
            return
        model = getattr(response, "model", None)
        model = model if isinstance(model, str) and model else requested_model
        usd = claude_cost(model, usage)
        if usd is None:
            if model not in _unknown:
                _unknown.add(model)
                print(f"Kosten: geen prijs voor {model} (config/gate.yaml, costs); niet meegeteld", file=sys.stderr)
            return
        _add("anthropic", usd, int(getattr(usage, "input_tokens", 0) or 0),
             int(getattr(usage, "output_tokens", 0) or 0))
    except Exception as e:  # noqa: BLE001 - tellen mag nooit een hint kosten
        print(f"Kosten niet geteld: {type(e).__name__}: {e}", file=sys.stderr)


def record_jev(response):
    """Na een Jev-aanroep (system_one): alleen invoertokens kosten geld."""
    try:
        usage = getattr(response, "usage", None)
        if usage is None:
            return
        tokens_in = int(getattr(usage, "input_tokens", 0) or 0)
        price = _prices.get("jev", JEV_INPUT_PRICE)
        _add("jev", tokens_in * price / 1e6, tokens_in, int(getattr(usage, "output_tokens", 0) or 0))
    except Exception as e:  # noqa: BLE001
        print(f"Kosten niet geteld: {type(e).__name__}: {e}", file=sys.stderr)


def _add(service: str, usd: float, tokens_in: int, tokens_out: int):
    """Optellen in het gedeelde bestand, onder een slot: meeting, zoeken en verslag kunnen tegelijk tellen."""
    path = ledger_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path.with_name(path.name + ".lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
        except ValueError:
            data = {}   # kapot bestand: opnieuw beginnen is beter dan nooit meer tellen
        s = data.setdefault(service, {})
        s["usd"] = float(s.get("usd", 0)) + usd
        s["input_tokens"] = int(s.get("input_tokens", 0)) + tokens_in
        s["output_tokens"] = int(s.get("output_tokens", 0)) + tokens_out
        s["calls"] = int(s.get("calls", 0)) + 1
        data["updated"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        tmp = path.with_name(path.name + ".tmp")
        tmp.write_text(json.dumps(data, indent=1), encoding="utf-8")
        os.replace(tmp, path)   # de app leest nooit een half bestand
