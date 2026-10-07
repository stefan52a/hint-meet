"""Retrieval over de Markdown-KB: alle .md-bestanden in de projectmap, dus zowel de schaduwbestanden
van tools/kb_prep.py als wat hint-meet zelf schrijft. _manifest.json is administratie van kb_prep.

Elk project heeft een eigen KB in KB_ROOT/KB_PROJECT (standaard ~/KB_md/<project>/).

Zoeken is hybride: embeddings (lokaal, meertalig) voor betekenis en BM25 voor exacte termen als
bedragen, artikelnummers en namen. De twee ranglijsten worden samengevoegd met reciprocal rank
fusion. Embeddings worden per stukje gecachet in <kb>/.hint-meet-cache/; het model staat in\n~/.cache/hint-meet/models/.
"""
from __future__ import annotations

import hashlib
import os
import sys
import re
from collections import Counter
from dataclasses import dataclass, replace
from pathlib import Path

import numpy as np

PROJECT_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._ -]*")  # gelijk aan tools/kb_prep.py
SHADOW_SUFFIX = ".kb-hint-meet.md"
CACHE_DIR = ".hint-meet-cache"
DEFAULT_MODEL = "intfloat/multilingual-e5-large"
CHUNK_CHARS = 1200
RRF_K = 60
# Ophogen als de tekst die naar het model gaat verandert (chunking, voorvoegsels, pooling):
# dan worden gecachte embeddings niet meer gebruikt.
EMBED_VERSION = 1
# Ophogen als tokenize() verandert: dan wordt de bewaarde woordindex (bm25-v*.npz) opnieuw gemaakt.
TOKEN_VERSION = 1

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


def kb_dirs(projects: str | None = None) -> list[Path]:
    """Eén of meer projecten, met komma's: "Finance,acme". Projectnamen bevatten geen komma."""
    if projects is None:
        projects = os.environ.get("KB_PROJECT")
    names = list(dict.fromkeys(p.strip() for p in (projects or "").split(",") if p.strip()))
    if not names:
        return [kb_dir(None if projects is None else "")]   # zelfde foutmelding als bij één project
    return [kb_dir(n) for n in names]


def ref_path(roots: list[Path], ref: str) -> Path:
    """Pad van een KB-referentie; bij meerdere projecten begint ref met de projectnaam."""
    if len(roots) == 1:
        return roots[0] / ref
    name, _, rest = ref.partition("/")
    root = next((r for r in roots if r.name == name), roots[0])
    return root / rest


# ---------- stukjes ----------

@dataclass(frozen=True)
class Chunk:
    ref: str       # pad van het brondocument binnen de KB, zonder schaduwsuffix
    heading: str   # kopjespad binnen het document
    text: str

    @property
    def superseded(self) -> bool:
        """Expliciet gemarkeerd als vervallen: een kopje met [VERVALLEN] of [ACHTERHAALD] erin.
        Bewust geen trefwoord-heuristiek: 'het naschrift hierboven is achterhaald' is zelf geldig."""
        h = self.heading.upper()
        return "[VERVALLEN]" in h or "[ACHTERHAALD]" in h

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

def _thousand(num: str) -> str:
    value = float(num.replace(",", ".")) * 1000
    return str(int(value)) if value.is_integer() else str(value)


def tokenize(text: str) -> list[str]:
    text = text.lower()
    text = re.sub(r"(?<=\d)[.](?=\d{3}\b)", "", text)          # 600.000 → 600000
    text = re.sub(r"(\d+(?:[.,]\d+)?)\s*k\b",                   # 600k → 600000, 1,5k → 1500
                  lambda m: _thousand(m.group(1)), text)
    text = re.sub(r"(?<=\d),(?=\d)", ".", text)                # 0,31 → 0.31
    return [t for t in re.findall(r"[a-z0-9à-ÿ]+(?:\.[0-9]+)?", text) if t not in STOPWORDS]


class TermRows:
    """Woordtellingen per stukje, compact: rij i heeft de woorden cols[indptr[i]:indptr[i+1]] (ids in vocab)
    met aantallen counts[...]. Zo te bewaren in een .npz en snel te laden; de vocab groeit alleen aan."""

    def __init__(self, vocab: list[str] | None = None):
        self.vocab = vocab or []
        self.ids = {t: i for i, t in enumerate(self.vocab)}
        self.indptr = [0]
        self.cols: list[np.ndarray] = []
        self.counts: list[np.ndarray] = []

    def add_tokens(self, tokens: list[str]) -> None:
        tf = Counter(tokens)
        ids = np.empty(len(tf), dtype=np.int32)
        for n, t in enumerate(tf):
            i = self.ids.get(t)
            if i is None:
                i = self.ids[t] = len(self.vocab)
                self.vocab.append(t)
            ids[n] = i
        self.add_row(ids, np.fromiter(tf.values(), dtype=np.int32, count=len(tf)))

    def add_row(self, cols: np.ndarray, counts: np.ndarray) -> None:
        self.cols.append(cols)
        self.counts.append(counts)
        self.indptr.append(self.indptr[-1] + len(cols))

    def arrays(self) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        cat = (lambda xs: np.concatenate(xs)) if self.cols else (lambda xs: np.zeros(0, dtype=np.int32))
        return np.array(self.indptr, dtype=np.int64), cat(self.cols).astype(np.int32), cat(self.counts).astype(np.int32)


def merge_rows(parts: list[TermRows]) -> TermRows:
    """Woordtellingen van meerdere KB's onder elkaar, met één gezamenlijke vocab."""
    out = TermRows()
    for rows in parts:
        mapping = np.empty(len(rows.vocab), dtype=np.int32)
        for i, t in enumerate(rows.vocab):
            j = out.ids.get(t)
            if j is None:
                j = out.ids[t] = len(out.vocab)
                out.vocab.append(t)
            mapping[i] = j
        indptr, cols, counts = rows.arrays()
        out.cols.append(mapping[cols])
        out.counts.append(counts)
        out.indptr.extend((indptr[1:] + out.indptr[-1]).tolist())
    return out


class BM25:
    """Okapi BM25 op een kolomindex: per woord de stukjes waarin het voorkomt, zodat een zoekvraag alleen
    die stukjes langsgaat in plaats van de hele KB."""

    def __init__(self, docs: list[list[str]] | None = None, k1: float = 1.5, b: float = 0.75, *,
                 rows: TermRows | None = None):
        if rows is None:
            rows = TermRows()
            for d in docs or []:
                rows.add_tokens(d)
        self.k1, self.b = k1, b
        self.ids = rows.ids
        indptr, cols, counts = rows.arrays()
        self.n = len(indptr) - 1
        row_of = np.repeat(np.arange(self.n, dtype=np.int32), np.diff(indptr))
        self.len = np.bincount(row_of, weights=counts, minlength=self.n).astype(float)
        self.avg = float(self.len.mean()) if self.n else 0.0
        df = np.bincount(cols, minlength=len(rows.vocab))
        self.idf = np.log(1 + (self.n - df + 0.5) / (df + 0.5))
        order = np.argsort(cols, kind="stable")
        self.col_rows = row_of[order]
        self.col_counts = counts[order].astype(float)
        self.col_ptr = np.concatenate([[0], np.cumsum(df)])

    def scores(self, query: list[str]) -> np.ndarray:
        out = np.zeros(self.n)
        for t in set(query):
            j = self.ids.get(t)
            if j is None:
                continue
            start, end = self.col_ptr[j], self.col_ptr[j + 1]
            rows, f = self.col_rows[start:end], self.col_counts[start:end]
            norm = self.k1 * (1 - self.b + self.b * self.len[rows] / self.avg)
            out[rows] += self.idf[j] * f * (self.k1 + 1) / (f + norm)
        return out


# ---------- embeddings ----------

MODEL_DIR = Path("~/.cache/hint-meet/models").expanduser()
# ONNX-export per model; e5 gebruikt mean pooling en de voorvoegsels 'query: ' / 'passage: '
ONNX_REPOS = {"intfloat/multilingual-e5-large": "qdrant/multilingual-e5-large-onnx"}


class OnnxEmbedder:
    """Lokaal embeddingmodel via onnxruntime + tokenizers, in een vaste map met echte bestanden
    (de Hugging Face-cache gebruikt symlinks, die recente onnxruntime-versies weigeren)."""

    def __init__(self, model: str = DEFAULT_MODEL, batch: int = 16, session: bool = True):
        from tokenizers import Tokenizer

        self.name = model
        self.batch = batch
        self.e5 = "e5" in model.lower()
        local = MODEL_DIR / model.replace("/", "--")
        done = local / ".download-compleet"
        if not done.exists():  # ook na een afgebroken download opnieuw proberen
            from huggingface_hub import snapshot_download
            snapshot_download(ONNX_REPOS.get(model, model), local_dir=local)
            done.touch()
        self.tokenizer = Tokenizer.from_file(str(local / "tokenizer.json"))
        self.tokenizer.enable_truncation(512)
        self.tokenizer.enable_padding()
        self.session = None
        if session:  # MLX gebruikt alleen de tokenizer; dan niet ook nog 2 GB ONNX laden
            import onnxruntime as ort
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


class MlxEmbedder(OnnxEmbedder):
    """Hetzelfde e5-model op de GPU via MLX (Apple Silicon): identieke vectoren als de ONNX-versie
    (gemeten: cosinus 1,00000), ±9× sneller (55 i.p.v. 513 ms per stukje). Gebruikt de tokenizer
    van de ONNX-map, zodat beide precies dezelfde invoer zien."""

    def __init__(self, model: str = DEFAULT_MODEL, batch: int = 16):
        from mlx_embeddings.utils import load   # eerst: ontbreekt MLX, dan valt default_embedder terug
        super().__init__(model, batch, session=False)   # alleen de tokenizer
        self.mlx_model, _ = load(model)

    def _embed(self, texts: list[str]) -> np.ndarray:
        import mlx.core as mx
        out = []
        for start in range(0, len(texts), self.batch):
            enc = self.tokenizer.encode_batch(texts[start:start + self.batch])
            ids = mx.array(np.array([e.ids for e in enc], dtype=np.int32))
            mask = mx.array(np.array([e.attention_mask for e in enc], dtype=np.int32))
            vecs = self.mlx_model(ids, attention_mask=mask).text_embeds
            mx.eval(vecs)
            out.append(np.array(vecs, dtype=np.float32))
        return np.concatenate(out)


def default_embedder(model: str = DEFAULT_MODEL):
    """MLX op Apple Silicon als dat beschikbaar is, anders ONNX op de CPU."""
    try:
        return MlxEmbedder(model)
    except ImportError:
        return OnnxEmbedder(model)


# ---------- de kennisbank ----------

@dataclass
class Hit:
    chunk: Chunk
    score: float
    rank_dense: int | None
    rank_bm25: int | None


class KB:
    BATCH_SAVE = 128   # na zoveel nieuwe stukjes de cache bijwerken: stoppen kost dan hooguit één batch

    def __init__(self, root: Path | list[Path], embedder=None, progress=None, on_phase=None, word_progress=None):
        """root: één KB-map, of een lijst voor meerdere projecten tegelijk. Elke map houdt zijn eigen
        bewaarde embeddings en woordindex; in het geheugen worden ze één zoekindex, met de projectnaam
        voor elke referentie (acme/offerte.pdf).
        progress(done, total, seconds_left) wordt aangeroepen tijdens het maken van nieuwe embeddings;
        word_progress(done, total, seconds_left) tijdens het splitsen van nieuwe stukjes in woorden;
        on_phase(key) bij het begin van elke fase: "model", en per map "read-<naam>", "words-<naam>",
        "embed-<naam>" (voor de voortgang in de app)."""
        self.roots = [Path(r) for r in root] if isinstance(root, (list, tuple)) else [Path(root)]
        self.root = self.roots[0]
        self.on_phase = on_phase or (lambda key: None)
        self.word_progress = word_progress
        if embedder is None:
            self.on_phase("model")
        self.embedder = embedder or default_embedder()
        self.progress = progress
        parts = [self._load(r) for r in self.roots]
        if len(parts) == 1:
            self.chunks, rows, self.vectors = parts[0]
        else:
            self.chunks = [replace(c, ref=f"{r.name}/{c.ref}") for r, (chunks, _, _) in zip(self.roots, parts)
                           for c in chunks]
            rows = merge_rows([rows for _, rows, _ in parts])
            filled = [v for chunks, _, v in parts if chunks]
            self.vectors = np.vstack(filled) if filled else np.zeros((0, 1), dtype=np.float32)
        self.bm25 = BM25(rows=rows)

    def _load(self, root: Path) -> tuple[list[Chunk], TermRows, np.ndarray]:
        self.on_phase(f"read-{root.name}")
        chunks = load_chunks(root)
        keys = [c.key for c in chunks]
        self.on_phase(f"words-{root.name}")
        rows = self._term_rows(root, chunks, keys)
        self.on_phase(f"embed-{root.name}")
        return chunks, rows, self._vectors(root, chunks, keys)

    def _term_rows(self, root: Path, chunks: list[Chunk], keys: list[str]) -> TermRows:
        """Woordtellingen per stukje, bewaard in <kb>/.hint-meet-cache/bm25-v*.npz: alleen nieuwe of
        gewijzigde stukjes worden opnieuw in woorden gesplitst (bij een grote KB het meeste werk)."""
        cache = root / CACHE_DIR / f"bm25-v{TOKEN_VERSION}.npz"
        old_keys: list[str] = []
        rows = TermRows()
        if cache.exists():
            try:
                data = np.load(cache)
                vocab = data["vocab"].tobytes().decode("utf-8")
                rows = TermRows(vocab.split("\n") if vocab else [])
                old_keys = data["keys"].astype(str).tolist()
                indptr, cols, counts = data["indptr"], data["cols"], data["counts"]
            except Exception:  # noqa: BLE001 - kapotte of half geschreven cache: gewoon opnieuw maken
                old_keys, rows = [], TermRows()
        if old_keys and old_keys == keys:   # niets veranderd: rechtstreeks gebruiken
            rows.indptr, rows.cols, rows.counts = indptr.tolist(), [cols], [counts]
            return rows
        where = {k: i for i, k in enumerate(old_keys)}
        import time
        todo = sum(1 for k in keys if k not in where)
        done, t0 = 0, time.monotonic()
        for c, k in zip(chunks, keys):
            i = where.get(k)
            if i is None and self.word_progress and done % 2000 == 0:
                rate = (time.monotonic() - t0) / done if done else 0
                self.word_progress(done, todo, rate * (todo - done))
            done += i is None
            if i is None:
                rows.add_tokens(tokenize(c.embed_text))
            else:
                rows.add_row(cols[indptr[i]:indptr[i + 1]], counts[indptr[i]:indptr[i + 1]])
        indptr_a, cols_a, counts_a = rows.arrays()
        tmp = cache.with_name(f".{cache.stem}.{os.getpid()}.tmp.npz")
        try:
            cache.parent.mkdir(exist_ok=True)
            np.savez(tmp, keys=np.array(keys, dtype="S40"), indptr=indptr_a, cols=cols_a, counts=counts_a,
                     vocab=np.frombuffer("\n".join(rows.vocab).encode("utf-8"), dtype=np.uint8))
            os.replace(tmp, cache)
        except OSError as e:  # bv. schijf vol: de KB werkt gewoon, alleen de volgende start is trager
            tmp.unlink(missing_ok=True)
            print(f"Woordindex niet bewaard: {e}", file=sys.stderr)
        return rows

    def _vectors(self, root: Path, chunks: list[Chunk], keys: list[str]) -> np.ndarray:
        if not chunks:
            return np.zeros((0, 1), dtype=np.float32)
        slug = re.sub(r"[^A-Za-z0-9]+", "-", getattr(self.embedder, "name", "model"))
        cache = root / CACHE_DIR / f"embeddings-{slug}-v{EMBED_VERSION}.npz"
        known: dict[str, np.ndarray] = {}
        if cache.exists():
            data = np.load(cache)
            known = dict(zip(data["keys"].tolist(), data["vecs"]))
        missing = [c for c, k in zip(chunks, keys) if k not in known]
        if missing:
            import time
            current = set(keys)
            t0 = time.monotonic()
            for start in range(0, len(missing), self.BATCH_SAVE):
                batch = missing[start:start + self.BATCH_SAVE]
                for c, v in zip(batch, self.embedder.passages([c.embed_text for c in batch])):
                    known[c.key] = v
                self._save(cache, {k: v for k, v in known.items() if k in current})
                if self.progress:
                    done = start + len(batch)
                    rate = (time.monotonic() - t0) / done
                    self.progress(done, len(missing), rate * (len(missing) - done))
        return np.stack([known[k] for k in keys])

    @staticmethod
    def _save(cache: Path, vectors: dict) -> None:
        cache.parent.mkdir(exist_ok=True)
        tmp = cache.with_name(f".{cache.stem}.{os.getpid()}.tmp.npz")  # eigen bestand per proces
        keys = list(vectors)
        np.savez(tmp, keys=np.array(keys), vecs=np.stack([vectors[k] for k in keys]))
        os.replace(tmp, cache)

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
        n = len(self.chunks)
        for hit in self.search(query, k=n, pool=n):  # volledige ranglijst: lange stukken mogen niet alles vullen
            if hit.chunk.ref not in seen:
                seen.append(hit.chunk.ref)
            if len(seen) == k:
                break
        return seen


def retrieve(query: str, collection: str | None, config: dict) -> list[dict]:
    raise NotImplementedError
