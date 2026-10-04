"""Retrieval over de Markdown-KB: alle .md-bestanden in de projectmap, dus zowel de schaduwbestanden
van tools/kb_prep.py als wat hint-meet zelf schrijft. _manifest.json is administratie van kb_prep.

Elk project heeft een eigen KB in KB_ROOT/KB_PROJECT (standaard ~/KB_md/<project>/).

Zoeken is hybride: embeddings (lokaal, meertalig) voor betekenis en BM25 voor exacte termen als
bedragen, artikelnummers en namen. De twee ranglijsten worden samengevoegd met reciprocal rank
fusion. Embeddings worden per stukje gecachet in <kb>/.hint-meet-cache/; het model staat in\n~/.cache/hint-meet/models/.
"""
from __future__ import annotations

import hashlib
import math
import os
import re
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

import numpy as np

PROJECT_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._ -]*")  # gelijk aan tools/kb_prep.py
SHADOW_SUFFIX = ".kb-hint-meet.md"
CACHE_DIR = ".hint-meet-cache"
DEFAULT_MODEL = "intfloat/multilingual-e5-large"
CHUNK_CHARS = 1200
RRF_K = 60

STOPWORDS = set("""
de het een en van in op te dat die is voor met aan er niet zijn om ook als bij of door naar uit
maar dan nog wel wat over tot dit zo je ik we wij u hij zij ze was werd wordt worden kan moet
hebben heeft had al geen meer dus deze hoe waar wie welke onder per na
""".split())


def kb_dir(project: str | None = None) -> Path:
    """KB-map van een project: KB_ROOT/<project>, met project uit het argument of KB_PROJECT."""
    if project is None:
        project = os.environ.get("KB_PROJECT")
    if not project:
        raise ValueError("Geen project gekozen: zet KB_PROJECT in .env of geef --project mee")
    if not PROJECT_NAME.fullmatch(project) or ".." in project:
        raise ValueError(f"Ongeldige projectnaam: {project!r}")
    return Path(os.environ.get("KB_ROOT", "~/KB_md")).expanduser() / project


# ---------- stukjes ----------

@dataclass(frozen=True)
class Chunk:
    ref: str       # pad van het brondocument binnen de KB, zonder schaduwsuffix
    heading: str   # kopjespad binnen het document
    text: str

    @property
    def embed_text(self) -> str:
        return f"{self.ref} › {self.heading}\n{self.text}" if self.heading else f"{self.ref}\n{self.text}"

    @property
    def key(self) -> str:
        return hashlib.sha1(self.embed_text.encode("utf-8")).hexdigest()


def strip_frontmatter(text: str) -> str:
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            return text[end + 5:]
    return text


def split_long(text: str, limit: int = CHUNK_CHARS) -> list[str]:
    """Knip op alinea's, en alinea's die te lang zijn (tabellen) op regels."""
    pieces: list[str] = []
    for para in re.split(r"\n\s*\n", text):
        if len(para) <= limit:
            pieces.append(para)
        else:
            pieces.extend(para.splitlines())
    out: list[str] = []
    buf = ""
    for piece in pieces:
        if not piece.strip():
            continue
        if buf and len(buf) + len(piece) + 2 > limit:
            out.append(buf)
            buf = ""
        buf = f"{buf}\n\n{piece}" if buf else piece
        while len(buf) > limit:  # één regel langer dan de limiet
            out.append(buf[:limit])
            buf = buf[limit:]
    if buf.strip():
        out.append(buf)
    return out


def chunk_markdown(ref: str, text: str) -> list[Chunk]:
    chunks: list[Chunk] = []
    path: list[str] = []
    section: list[str] = []

    def flush():
        body = "\n".join(section).strip()
        if body:
            heading = " › ".join(path)
            chunks.extend(Chunk(ref, heading, piece) for piece in split_long(body))
        section.clear()

    for line in strip_frontmatter(text).splitlines():
        m = re.match(r"(#{1,6})\s+(.*)", line)
        if m:
            flush()
            level = len(m.group(1))
            path[:] = path[:level - 1] + [m.group(2).strip()]
        else:
            section.append(line)
    flush()
    return chunks


def load_chunks(root: Path) -> list[Chunk]:
    chunks: list[Chunk] = []
    for md in sorted(root.rglob("*.md")):
        rel = md.relative_to(root)
        if any(part.startswith(".") for part in rel.parts):
            continue
        ref = str(rel)[:-len(SHADOW_SUFFIX)] if md.name.endswith(SHADOW_SUFFIX) else str(rel)
        chunks.extend(chunk_markdown(ref, md.read_text(encoding="utf-8", errors="replace")))
    return chunks


# ---------- trefwoorden (BM25) ----------

def tokenize(text: str) -> list[str]:
    text = text.lower()
    text = re.sub(r"(?<=\d)[.](?=\d{3}\b)", "", text)          # 600.000 → 600000
    text = re.sub(r"(\d+)\s*k\b", lambda m: m.group(1) + "000", text)  # 600k → 600000
    text = re.sub(r"(?<=\d),(?=\d)", ".", text)                # 0,31 → 0.31
    return [t for t in re.findall(r"[a-z0-9à-ÿ]+(?:\.[0-9]+)?", text) if t not in STOPWORDS]


class BM25:
    def __init__(self, docs: list[list[str]], k1: float = 1.5, b: float = 0.75):
        self.k1, self.b = k1, b
        self.tf = [Counter(d) for d in docs]
        self.len = np.array([len(d) for d in docs], dtype=float)
        self.avg = float(self.len.mean()) if len(docs) else 0.0
        df = Counter(t for d in docs for t in set(d))
        n = len(docs)
        self.idf = {t: math.log(1 + (n - f + 0.5) / (f + 0.5)) for t, f in df.items()}

    def scores(self, query: list[str]) -> np.ndarray:
        out = np.zeros(len(self.tf))
        for t in set(query):
            idf = self.idf.get(t)
            if idf is None:
                continue
            f = np.array([tf.get(t, 0) for tf in self.tf], dtype=float)
            out += idf * f * (self.k1 + 1) / (f + self.k1 * (1 - self.b + self.b * self.len / self.avg))
        return out


# ---------- embeddings ----------

MODEL_DIR = Path("~/.cache/hint-meet/models").expanduser()
# ONNX-export per model; e5 gebruikt mean pooling en de voorvoegsels 'query: ' / 'passage: '
ONNX_REPOS = {"intfloat/multilingual-e5-large": "qdrant/multilingual-e5-large-onnx"}


class OnnxEmbedder:
    """Lokaal embeddingmodel via onnxruntime + tokenizers, in een vaste map met echte bestanden
    (de Hugging Face-cache gebruikt symlinks, die recente onnxruntime-versies weigeren)."""

    def __init__(self, model: str = DEFAULT_MODEL, batch: int = 16):
        import onnxruntime as ort
        from tokenizers import Tokenizer

        self.name = model
        self.batch = batch
        self.e5 = "e5" in model.lower()
        local = MODEL_DIR / model.split("/")[-1]
        if not (local / "model.onnx").exists():
            from huggingface_hub import snapshot_download
            snapshot_download(ONNX_REPOS.get(model, model), local_dir=local)
        self.tokenizer = Tokenizer.from_file(str(local / "tokenizer.json"))
        self.tokenizer.enable_truncation(512)
        self.tokenizer.enable_padding()
        self.session = ort.InferenceSession(str(local / "model.onnx"), providers=["CPUExecutionProvider"])
        self.inputs = {i.name for i in self.session.get_inputs()}

    def _embed(self, texts: list[str]) -> np.ndarray:
        out = []
        for start in range(0, len(texts), self.batch):
            enc = self.tokenizer.encode_batch(texts[start:start + self.batch])
            ids = np.array([e.ids for e in enc], dtype=np.int64)
            mask = np.array([e.attention_mask for e in enc], dtype=np.int64)
            feed = {"input_ids": ids, "attention_mask": mask}
            if "token_type_ids" in self.inputs:
                feed["token_type_ids"] = np.zeros_like(ids)
            hidden = self.session.run(None, feed)[0]
            pooled = (hidden * mask[..., None]).sum(1) / mask.sum(1, keepdims=True)
            out.append(pooled)
        vecs = np.concatenate(out).astype(np.float32)
        return vecs / np.linalg.norm(vecs, axis=1, keepdims=True)

    def passages(self, texts: list[str]) -> np.ndarray:
        return self._embed([f"passage: {t}" if self.e5 else t for t in texts])

    def query(self, text: str) -> np.ndarray:
        return self._embed([f"query: {text}" if self.e5 else text])[0]


# ---------- de kennisbank ----------

@dataclass
class Hit:
    chunk: Chunk
    score: float
    rank_dense: int | None
    rank_bm25: int | None


class KB:
    def __init__(self, root: Path, embedder=None):
        self.root = Path(root)
        self.chunks = load_chunks(self.root)
        self.bm25 = BM25([tokenize(c.embed_text) for c in self.chunks])
        self.embedder = embedder or OnnxEmbedder()
        self.vectors = self._vectors()

    def _vectors(self) -> np.ndarray:
        if not self.chunks:
            return np.zeros((0, 1), dtype=np.float32)
        slug = re.sub(r"[^A-Za-z0-9]+", "-", getattr(self.embedder, "name", "model"))
        cache = self.root / CACHE_DIR / f"embeddings-{slug}.npz"
        known: dict[str, np.ndarray] = {}
        if cache.exists():
            data = np.load(cache)
            known = dict(zip(data["keys"].tolist(), data["vecs"]))
        missing = [c for c in self.chunks if c.key not in known]
        if missing:
            for c, v in zip(missing, self.embedder.passages([c.embed_text for c in missing])):
                known[c.key] = v
            keys = [c.key for c in self.chunks]  # alleen huidige stukjes bewaren
            cache.parent.mkdir(exist_ok=True)
            tmp = cache.with_suffix(".tmp.npz")
            np.savez(tmp, keys=np.array(keys), vecs=np.stack([known[k] for k in keys]))
            os.replace(tmp, cache)
        return np.stack([known[c.key] for c in self.chunks])

    def search(self, query: str, k: int = 5, pool: int = 50) -> list[Hit]:
        if not self.chunks:
            return []
        dense = self.vectors @ self.embedder.query(query)
        sparse = self.bm25.scores(tokenize(query))
        rank_d = {int(i): r for r, i in enumerate(np.argsort(-dense)[:pool])}
        rank_s = {int(i): r for r, i in enumerate(np.argsort(-sparse)[:pool]) if sparse[i] > 0}
        fused: dict[int, float] = {}
        for ranks in (rank_d, rank_s):
            for i, r in ranks.items():
                fused[i] = fused.get(i, 0.0) + 1.0 / (RRF_K + r + 1)
        best = sorted(fused, key=fused.get, reverse=True)[:k]
        return [Hit(self.chunks[i], fused[i], rank_d.get(i), rank_s.get(i)) for i in best]

    def search_docs(self, query: str, k: int = 5) -> list[str]:
        """Unieke documenten in volgorde van hun beste stukje."""
        seen: list[str] = []
        for hit in self.search(query, k=k * 6):
            if hit.chunk.ref not in seen:
                seen.append(hit.chunk.ref)
            if len(seen) == k:
                break
        return seen


def retrieve(query: str, collection: str | None, config: dict) -> list[dict]:
    raise NotImplementedError
