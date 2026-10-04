"""Retrieval over de Markdown-KB (output van tools/kb_prep.py, met _index.json).

Embeddings in LanceDB, daarna een Jev-reranker: één Noul per passage, alleen boven kb.rerank_min door.
"""


def retrieve(query: str, collection: str | None, config: dict) -> list[dict]:
    raise NotImplementedError
