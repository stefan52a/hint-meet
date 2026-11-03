""".env vanaf de werkmap inlezen; bestaande omgevingsvariabelen (bv. sleutels uit de Keychain via de app) gaan voor.

Alleen een gewoon bestand: een pipe of iets anders kan het lezen eeuwig laten wachten, dat slaan we over.
"""
from __future__ import annotations

import os
import sys

from dotenv import find_dotenv, load_dotenv


def usable(path: str) -> bool:
    """True als path een gewoon, leesbaar bestand is; anders een waarschuwing op stderr."""
    if not os.path.isfile(path):
        print(f"⚠ {path} is geen gewoon bestand (een pipe?), overgeslagen", file=sys.stderr)
        return False
    if not os.access(path, os.R_OK):
        print(f"⚠ {path} niet leesbaar, overgeslagen", file=sys.stderr)
        return False
    return True


def load() -> None:
    path = find_dotenv(usecwd=True)
    if not path or not usable(path):
        return
    try:
        load_dotenv(path, override=False)
    except (OSError, UnicodeDecodeError) as e:
        print(f"⚠ .env niet gelezen: {e}", file=sys.stderr)
