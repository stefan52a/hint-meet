""".env inlezen, ook als 1Password hem levert.

1Password (Environments) zet .env neer als named pipe: het bestand bestaat, maar de inhoud komt pas als de
1Password-app draait, ontgrendeld is en deze lezer toelaat. Anders blijft open() eeuwig wachten, en daarmee de
hele pijplijn ("Starting pipeline…" zonder einde). Daarom lezen we een pipe in een eigen draad met een
tijdslimiet; komt er niets, dan gaat hint-meet door zonder .env en zegt waarom (zie apierrors).
"""
from __future__ import annotations

import io
import os
import stat
import sys
import threading

from dotenv import find_dotenv, load_dotenv

TIMEOUT_S = 15   # ruim genoeg om in 1Password op Allow te klikken
PROBLEM = ("the .env from 1Password couldn't be read. Open and unlock 1Password (and allow access if it asks), "
           "or put the key in Settings (API-keys).")

problem: str | None = None   # gezet als .env een 1Password-pipe was die niets leverde


def read_text(path: str, timeout_s: float = TIMEOUT_S) -> str | None:
    """Inhoud van path; voor een pipe hoogstens timeout_s wachten (None: niets gekregen)."""
    if not stat.S_ISFIFO(os.stat(path).st_mode):
        with open(path, encoding="utf-8") as f:
            return f.read()
    out: dict = {}

    def read():
        try:
            with open(path, encoding="utf-8") as f:
                out["text"] = f.read()
        except OSError as e:
            out["error"] = e

    # daemon: blijft hij hangen (1Password dicht), dan houdt hij het afsluiten niet op
    t = threading.Thread(target=read, daemon=True, name="hint-meet-dotenv")
    t.start()
    t.join(timeout_s)
    return out.get("text")


def load(timeout_s: float = TIMEOUT_S) -> str | None:
    """.env vanaf de werkmap in de omgeving zetten; bestaande variabelen (bv. uit de Keychain) gaan voor.
    Geeft een melding als de 1Password-pipe niets leverde, anders None."""
    global problem
    path = find_dotenv(usecwd=True)
    if not path:
        return None
    try:
        text = read_text(path, timeout_s)
    except OSError as e:
        print(f".env niet gelezen: {e}", file=sys.stderr)
        return None
    if text is None:
        problem = PROBLEM
        print(f"⚠ .env is een 1Password-pipe die binnen {timeout_s:.0f} s niets gaf: 1Password dicht of "
              "vergrendeld? Verder zonder .env.", file=sys.stderr)
        return problem
    load_dotenv(stream=io.StringIO(text))
    return None
