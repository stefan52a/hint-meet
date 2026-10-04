"""Retrieval over de Markdown-KB: alle .md-bestanden in de projectmap, dus zowel de schaduwbestanden
van tools/kb_prep.py als wat hint-meet zelf schrijft. _manifest.json is administratie van kb_prep.

Elk project heeft een eigen KB in KB_ROOT/KB_PROJECT (standaard ~/KB_md/<project>/).
Embeddings in LanceDB, daarna een Jev-reranker: één Noul per passage, alleen boven kb.rerank_min door.
"""
import os
import re
from pathlib import Path

PROJECT_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._ -]*")  # gelijk aan tools/kb_prep.py


def kb_dir(project: str | None = None) -> Path:
    """KB-map van een project: KB_ROOT/<project>, met project uit het argument of KB_PROJECT."""
    if project is None:
        project = os.environ.get("KB_PROJECT")
    if not project:
        raise ValueError("Geen project gekozen: zet KB_PROJECT in .env of geef --project mee")
    if not PROJECT_NAME.fullmatch(project) or ".." in project:
        raise ValueError(f"Ongeldige projectnaam: {project!r}")
    return Path(os.environ.get("KB_ROOT", "~/KB_md")).expanduser() / project



def retrieve(query: str, collection: str | None, config: dict) -> list[dict]:
    raise NotImplementedError
