"""De meeting overleeft de app: loopt HintMeet.app vast en wordt hij geforceerd gestopt, dan draait de pijplijn
door (opname, transcript, hints) en neemt de herstarte app hem weer over.

Wat daarvoor nodig is: de uitvoer gaat via een pipe naar de app. Valt die weg, dan geeft elke print een
BrokenPipeError, en die stopt de draad die toevallig print (bv. de pijplijndraad: geen hints meer) of laat het
afsluiten hangen. Bij de eerste mislukte schrijfpoging gaan stdout en stderr daarom naar het logboek dat de app
anders zelf schreef (dup2 op fd 1 en 2, zodat ook uitvoer van C-bibliotheken daar terechtkomt).
"""
from __future__ import annotations

import os
import sys
import threading


class _Fallback:
    """Om sys.stdout/sys.stderr heen: schrijft gewoon door, tot de pipe weg is; dan naar het logboek."""

    def __init__(self, stream, switch):
        self._stream, self._switch = stream, switch

    def write(self, s):
        try:
            return self._stream.write(s)
        except OSError:   # BrokenPipeError: de app is weg
            self._switch()
            return self._stream.write(s)

    def flush(self):
        try:
            self._stream.flush()
        except OSError:
            self._switch()

    def __getattr__(self, name):
        return getattr(self._stream, name)


def install(log_path: str | None):
    """stdout en stderr laten uitwijken naar log_path (of /dev/null) zodra de app er niet meer is."""
    lock = threading.Lock()
    switched = []

    def switch():
        with lock:
            if switched:
                return
            try:
                fd = os.open(log_path or os.devnull, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            except OSError:
                fd = os.open(os.devnull, os.O_WRONLY)
            os.dup2(fd, 1)
            os.dup2(fd, 2)
            os.close(fd)
            switched.append(True)
        print("App weggevallen: de meeting loopt door, uitvoer naar dit logboek", file=sys.stderr)

    sys.stdout = _Fallback(sys.stdout, switch)
    sys.stderr = _Fallback(sys.stderr, switch)
