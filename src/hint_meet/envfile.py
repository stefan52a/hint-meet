""".env vanaf de werkmap inlezen; bestaande omgevingsvariabelen (bv. sleutels uit de Keychain via de app) gaan voor."""
from __future__ import annotations

from dotenv import find_dotenv, load_dotenv


def load() -> None:
    path = find_dotenv(usecwd=True)
    if path:
        load_dotenv(path, override=False)
