import numpy as np
import pytest

from hint_meet.kb import KB, SHADOW_SUFFIX, chunk_markdown, split_long, tokenize


class FakeEmbedder:
    """Woordzak-vectoren: deterministisch, geen model nodig."""
    name = "fake"

    def __init__(self):
        self.calls = 0

    def _vec(self, text):
        v = np.zeros(256, dtype=np.float32)
        for t in tokenize(text):
            v[hash(t) % 256] += 1
        n = np.linalg.norm(v)
        return v / n if n else v

    def passages(self, texts):
        self.calls += len(texts)
        return np.stack([self._vec(t) for t in texts])

    def query(self, text):
        return self._vec(text)


def write(root, rel, text):
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding="utf-8")


def test_tokenize_normalises_amounts():
    assert "600000" in tokenize("€ 600.000")
    assert "600000" in tokenize("zo'n 600k")
    assert "0.31" in tokenize("0,31% marktaandeel")
    assert "37d" in tokenize("artikel 37d")
    assert "de" not in tokenize("de agio")


def test_chunks_follow_headings_and_drop_frontmatter():
    md = "---\nsource: \"x\"\n---\n\n# Memo\n\nIntro\n\n## BTW\n\nArtikel 37d.\n\n## VPB\n\nVerliesvoorraad."
    chunks = chunk_markdown("memo.md", md)
    assert [c.heading for c in chunks] == ["Memo", "Memo › BTW", "Memo › VPB"]
    assert all("source:" not in c.text for c in chunks)


def test_long_table_is_split_on_lines():
    table = "\n".join(f"| rij {i} | {'x' * 50} |" for i in range(100))
    parts = split_long(table, limit=500)
    assert len(parts) > 5 and all(len(p) <= 500 for p in parts)


def test_shadow_suffix_is_stripped_from_ref(tmp_path):
    write(tmp_path, "dossier/memo.md" + SHADOW_SUFFIX, "# Memo\n\nAgio van € 400.000.")
    write(tmp_path, "eigen-notitie.md", "# Notitie\n\nVan hint-meet zelf.")
    kb = KB(tmp_path, FakeEmbedder())
    assert {c.ref for c in kb.chunks} == {"dossier/memo.md", "eigen-notitie.md"}


def test_hidden_folders_are_skipped(tmp_path):
    write(tmp_path, ".hint-meet-cache/x.md", "# geheim")
    write(tmp_path, "a.md", "# A\n\ntekst")
    assert {c.ref for c in KB(tmp_path, FakeEmbedder()).chunks} == {"a.md"}


def test_exact_amount_found_via_bm25(tmp_path):
    write(tmp_path, "fiscaal.md", "# Fiscaal\n\nBoekwinst Globex € 504.457,66 valt weg tegen de verliesvoorraad.")
    write(tmp_path, "waarde.md", "# Waardering\n\nDe software is € 400.000 waard volgens de memo.")
    write(tmp_path, "ruis.md", "# Ruis\n\nIets over hosting bij Hetzner.")
    kb = KB(tmp_path, FakeEmbedder())
    assert kb.search_docs("hoe zit het met die 400k voor de software", k=1) == ["waarde.md"]


def test_embeddings_are_cached(tmp_path):
    write(tmp_path, "a.md", "# A\n\neen")
    write(tmp_path, "b.md", "# B\n\ntwee")
    emb = FakeEmbedder()
    KB(tmp_path, emb)
    assert emb.calls == 2
    KB(tmp_path, emb)
    assert emb.calls == 2  # alles uit de cache
    write(tmp_path, "c.md", "# C\n\ndrie")
    KB(tmp_path, emb)
    assert emb.calls == 3  # alleen het nieuwe stukje


def test_search_docs_is_unique_and_ordered(tmp_path):
    write(tmp_path, "a.md", "# A\n\n## x\n\nagio agio\n\n## y\n\nagio")
    write(tmp_path, "b.md", "# B\n\nagio")
    docs = KB(tmp_path, FakeEmbedder()).search_docs("agio", k=5)
    assert sorted(docs) == ["a.md", "b.md"] and len(docs) == 2


def test_empty_kb(tmp_path):
    kb = KB(tmp_path, FakeEmbedder())
    assert kb.search("iets") == [] and kb.search_docs("iets") == []
