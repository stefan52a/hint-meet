""".env inlezen, ook als 1Password hem levert.

1Password (Environments) zet .env neer als named pipe: het bestand bestaat, maar de inhoud komt pas als de
1Password-app draait, ontgrendeld is en deze lezer toelaat. Anders blijft open() eeuwig wachten, en daarmee de
hele pijplijn ("Starting pipeline…" zonder einde). Daarom lezen we een pipe in een eigen draad met een
tijdslimiet; komt er niets, dan gaat hint-meet door zonder .env en zegt waarom (zie apierrors).

1Password is niet gemaakt voor lezers tegelijk: de eerste krijgt de inhoud, de rest kan leeg uitkomen. De app
start er meerdere tegelijk (sleutelcontrole, zoekserver, KB voorbereiden), dus lezen ze om de beurt (een slot)
en wordt een leeg antwoord een paar keer opnieuw geprobeerd.
"""
from __future__ import annotations

import fcntl
import io
import os
import stat
import sys
import tempfile
import threading
import time

from dotenv import find_dotenv, load_dotenv

TIMEOUT_S = 15   # ruim genoeg om in 1Password op Allow te klikken
PROBLEM = ("the .env from 1Password couldn't be read. Open and unlock 1Password (and allow access if it asks), "
           "or put the key in Settings (API-keys).")

EMPTY = ("the .env from 1Password is empty. In 1Password, check that this project's environment has the key and "
         "that its local .env destination is this folder, or put the key in Settings (API-keys).")

LOCK = os.path.join(tempfile.gettempdir(), "hint-meet-dotenv.lock")   # per gebruiker (macOS: eigen tmp-map)
RETRIES, RETRY_S = 3, 0.7

problem: str | None = None   # gezet als .env een 1Password-pipe was die niets leverde


def read_text(path: str, timeout_s: float = TIMEOUT_S) -> str | None:
    """Inhoud van path; voor een pipe hoogstens timeout_s wachten (None: niets gekregen)."""
    if not stat.S_ISFIFO(os.stat(path).st_mode):
        with open(path, encoding="utf-8") as f:
            return f.read()
    out: dict = {}
    opened, cancelled = threading.Event(), threading.Event()

    def read():
        try:
            with open(LOCK, "w") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)   # om de beurt met andere hint-meet-processen
                for attempt in range(RETRIES):
                    if cancelled.is_set():   # tijd om: niet opnieuw gaan wachten (en het slot vrijgeven)
                        return
                    with open(path, encoding="utf-8") as f:
                        opened.set()
                        text = f.read()
                    if text.strip() or attempt == RETRIES - 1:
                        out["text"] = text
                        return
                    opened.clear()
                    time.sleep(RETRY_S)   # leeg: een andere lezer was 1Password net voor
        except OSError as e:
            out["error"] = e

    # daemon: blijft hij hangen (1Password dicht), dan houdt hij het afsluiten niet op
    t = threading.Thread(target=read, daemon=True, name="hint-meet-dotenv")
    t.start()
    t.join(timeout_s)
    cancelled.set()
    # wacht onze lezer nog op een schrijver (1Password dicht), dan losmaken: anders houdt hij het slot vast en
    # kunnen andere processen (de zoekserver blijft draaien) nooit meer lezen. Een paar keer: hij kan net
    # tussen twee pogingen zitten en pas daarna gaan wachten.
    deadline = time.monotonic() + 2
    while t.is_alive() and not opened.is_set() and time.monotonic() < deadline:
        try:
            os.close(os.open(path, os.O_WRONLY | os.O_NONBLOCK))
        except OSError:
            pass   # (nog) geen lezer op de pipe
        t.join(0.05)
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
    if not text.strip() and stat.S_ISFIFO(os.stat(path).st_mode):   # 1Password antwoordt, maar zonder variabelen
        problem = EMPTY
        print("⚠ .env (1Password-pipe) is leeg: geen variabelen in die environment, of een andere bestemming?",
              file=sys.stderr)
        return problem
    load_dotenv(stream=io.StringIO(text))
    return None
