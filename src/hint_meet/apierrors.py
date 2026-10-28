"""Een API-key die niet werkt (fout, ontbreekt, geen toegang, geen tegoed, limiet bereikt): de gebruiker zien
waarom, in plaats van dat er stil geen hints of bevestigingen meer komen.

De pijplijn vangt API-fouten af zodat de meeting doorloopt; op die plekken roept hij report(e) aan. Is het een
sleutelprobleem, dan gaat het één keer per melding naar de luisteraar (de app, via de Hub); een tijdelijke fout
(time-out, overbelast) niet, die lost zichzelf op.

check_keys() test de sleutels vooraf, bij het openen van de app en bij de start van een meeting, met gratis
aanroepen: Claude count_tokens (die ziet ook een bereikte limiet of geen tegoed), Jev de modellenlijst (die ziet
een foute of ontbrekende sleutel, geen tegoed niet: dat blijkt pas bij een echte aanroep).
"""
from __future__ import annotations

import sys
import threading
from concurrent.futures import ThreadPoolExecutor

KEYS = {"anthropic": ("Claude", "ANTHROPIC_API_KEY"), "typesafe_sdk": ("Jev", "TYPESAFE_API_KEY")}
# Anthropic meldt geen tegoed of een bereikte limiet als 400 (invalid_request_error), alleen aan de tekst te zien
NO_CREDIT = ("credit balance", "usage limit")

listener = None   # callable(str), gezet door de live-meeting met een Hub
_seen: set[str] = set()
_lock = threading.Lock()


def _message(e: BaseException) -> str:
    body = getattr(e, "body", None)   # Anthropic: {"error": {"message": ..}}
    if isinstance(body, dict) and isinstance(body.get("error"), dict) and body["error"].get("message"):
        return str(body["error"]["message"])
    return str(getattr(e, "_message", None) or e)   # TypeSafe: de tekst zonder status en request-id


def key_problem(e: BaseException) -> str | None:
    """Een zin voor de gebruiker als e betekent dat de API-key niet werkt; anders None."""
    root = type(e).__module__.split(".")[0]
    if isinstance(e, TypeError) and "authentication method" in str(e):   # Anthropic zonder sleutel
        root = "anthropic"
    if root not in KEYS:
        return None
    service, var = KEYS[root]
    status = getattr(e, "status_code", None) or getattr(e, "status", None)
    msg = _message(e)
    missing = isinstance(e, TypeError) or "No API key was provided" in msg
    if not (missing or status in (401, 402, 403)
            or (status == 400 and any(s in msg.lower() for s in NO_CREDIT))):
        return None
    if missing:
        from . import envfile
        if envfile.problem:   # .env komt uit 1Password, maar die gaf niets
            return f"{service}: no API key ({var}): {envfile.problem}"
        return f"{service}: no API key ({var}). Add it in Settings (API-keys) or .env."
    return f"{service} API key ({var}) doesn't work: {msg}"


def report(e: BaseException) -> bool:
    """Meldt e aan de luisteraar als het een sleutelprobleem is (elke melding één keer). True als dat zo is."""
    text = key_problem(e)
    if text is None:
        return False
    with _lock:
        new = text not in _seen
        _seen.add(text)
    if new:
        print(f"⚠ {text}", file=sys.stderr)
        if listener:
            try:
                listener(text)
            except Exception:  # noqa: BLE001 - de melding mag de pijplijn niet stoppen
                pass
    return True


def _check_claude(config: dict, timeout_s: float):
    import anthropic
    model = config.get("advise", {}).get("model", "claude-haiku-4-5")
    anthropic.Anthropic(timeout=timeout_s, max_retries=0).messages.count_tokens(
        model=model, messages=[{"role": "user", "content": "hi"}])


def _check_jev(config: dict, timeout_s: float):
    from typesafe_sdk import TypeSafeClient
    TypeSafeClient(timeout=timeout_s).models.list()


def check_keys(config: dict, timeout_s: float = 8) -> tuple[list[str], list[str]]:
    """Test elke sleutel die deze config nodig heeft (Claude altijd, Jev als gate.provider jev is), tegelijk.
    Geeft (sleutelproblemen, diensten zonder uitsluitsel) en meldt de problemen via report(). Een netwerkfout of
    time-out is geen probleem maar geen uitsluitsel: dan weet je over die sleutel niets."""
    checks = [("Claude", _check_claude)]
    if config.get("gate", {}).get("provider") == "jev":
        checks.append(("Jev", _check_jev))

    def run(named):
        service, check = named
        try:
            check(config, timeout_s)
        except Exception as e:  # noqa: BLE001 - alleen een sleutelprobleem telt
            if report(e):
                return key_problem(e), None
            print(f"API-check {service}: {type(e).__name__}: {e}", file=sys.stderr)
            return None, service
        return None, None

    with ThreadPoolExecutor(len(checks)) as pool:
        results = list(pool.map(run, checks))
    return [p for p, _ in results if p], [s for _, s in results if s]
