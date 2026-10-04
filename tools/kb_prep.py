#!/usr/bin/env python3
"""
kb_prep.py : zet een kennisbank-map om naar Markdown.

Ondersteund: .docx .xlsx .xlsm .csv .pptx .pdf .html .htm .txt .md .json .rtf (via textutil op macOS),
             en met OCR ook .png .jpg .jpeg .tif .tiff .webp
Resultaat: dezelfde mappenstructuur onder <out>/, elk bestand als <naam>.<ext>.kb-hint-meet.md
met YAML-frontmatter. Aan die suffix herkent het script zijn eigen schaduwbestanden: ze worden nooit
als bron gelezen. <out> mag dus ook binnen <bron> liggen of gelijk zijn aan <bron>.

Eigendom staat in <out>/_manifest.json: per schaduwbestand de bron, de hash van de bron, de hash
van wat kb_prep schreef en de OCR-instelling. kb_prep overschrijft of verwijdert alleen bestanden
die in het manifest staan en sindsdien niet zijn aangepast; wat hint-meet of de gebruiker in de
map zet, blijft staan. Herconversie gebeurt als de bronhash of de OCR-instelling verandert.

Gebruik:
    python kb_prep.py <bron-map> [<doel-map>] [--project NAAM] [--force] [--no-ocr]

    <doel-map> standaard KB_ROOT (uit de omgeving of .env, anders ~/KB_md); het project
              is dan standaard de naam van de bronmap: ~/Documents/Fabrikam -> ~/KB_md/Fabrikam/
    --project schrijf naar <doel-map>/NAAM/, zodat elk project een eigen KB heeft
              (bijv. ~/KB_md/fabrikam/); hint-meet kiest die via KB_ROOT + KB_PROJECT

    --force   zet alles opnieuw om, ook als de bron niet veranderd is, en overschrijf eigen
              schaduwbestanden die na conversie zijn aangepast (vreemde bestanden nooit)
    --no-ocr  geen OCR; standaard leest OCR PDF-pagina's zonder tekstlaag (scans) uit,
              wat pytesseract + tesseract (met taal nld) vereist

Vereisten (pip): python-docx openpyxl python-pptx pymupdf markdownify
Optioneel:       pytesseract (OCR)
"""
from __future__ import annotations

import argparse
import csv
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".webp"}
SUPPORTED = {".docx", ".xlsx", ".xlsm", ".csv", ".pptx", ".pdf", ".html", ".htm",
             ".txt", ".md", ".json", ".rtf"} | IMAGE_EXTS
OCR_EXTS = {".pdf", ".pptx"} | IMAGE_EXTS  # uitkomst hangt af van --ocr/--no-ocr
# Ophogen als de conversie zelf verbetert: bestaande schaduwbestanden worden dan opnieuw gemaakt.
CONVERTER_VERSION = 3
LOW_TEXT = 50
OCR_TIMEOUT = 120  # seconden per afbeelding  # minder leesbare tekens dan dit: waarschuwen
PROJECT_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._ -]*")
SHADOW_SUFFIX = ".kb-hint-meet.md"
LEGACY_INDEX = "_index.json"  # vroeger geschreven, nu overbodig naast het manifest; wordt opgeruimd
MANIFEST_NAME = "_manifest.json"
MANIFEST_VERSION = 1
LOCK_NAME = ".kb_prep.lock"

# ---------- hulpfuncties ----------

def sha1_of(path: Path) -> str:
    h = hashlib.sha1()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:12]


def write_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def clean(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"[ \t]+\n", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip() + "\n"


def md_table(rows: list[list[str]]) -> str:
    rows = [[("" if c is None else str(c)).replace("|", "\\|").replace("\n", " ") for c in r] for r in rows]
    if not rows:
        return ""
    width = max(len(r) for r in rows)
    rows = [r + [""] * (width - len(r)) for r in rows]
    head, body = rows[0], rows[1:]
    out = ["| " + " | ".join(head) + " |", "|" + "---|" * width]
    out += ["| " + " | ".join(r) + " |" for r in body]
    return "\n".join(out)


# ---------- converters ----------

def ocr_image(img, what: str) -> str:
    """OCR op een PIL-afbeelding (Nederlands + Engels); fouten worden RuntimeError."""
    try:
        import pytesseract
        from PIL import Image
        if img.mode in ("RGBA", "LA", "PA") or (img.mode == "P" and "transparency" in img.info):
            # transparante achtergrond wordt anders zwart, en zwarte tekst daarop onleesbaar
            rgba = img.convert("RGBA")
            img = Image.new("RGBA", rgba.size, "white")
            img.alpha_composite(rgba)
        if img.mode not in ("RGB", "L"):
            img = img.convert("RGB")
        return pytesseract.image_to_string(img, lang="nld+eng", timeout=OCR_TIMEOUT).strip()
    except Exception as e:  # noqa: BLE001
        raise RuntimeError(f"OCR mislukt op {what}: {e}") from e


def conv_docx(path: Path) -> str:
    from docx import Document
    from docx.table import Table
    from docx.text.paragraph import Paragraph

    doc = Document(str(path))
    parts: list[str] = []
    for block in doc.element.body.iterchildren():
        tag = block.tag.split("}")[-1]
        if tag == "p":
            p = Paragraph(block, doc)
            t = p.text.strip()
            if not t:
                continue
            style = (p.style.name or "").lower()
            m = re.match(r"heading (\d)", style)
            if m:
                parts.append("#" * int(m.group(1)) + " " + t)
            elif "list" in style:
                parts.append("- " + t)
            else:
                parts.append(t)
        elif tag == "tbl":
            tbl = Table(block, doc)
            rows = [[c.text for c in r.cells] for r in tbl.rows]
            parts.append(md_table(rows))
    return "\n\n".join(parts)


def conv_xlsx(path: Path) -> str:
    from openpyxl import load_workbook

    wb = load_workbook(str(path), data_only=True, read_only=True)
    parts: list[str] = []
    for ws in wb.worksheets:
        rows = [list(r) for r in ws.iter_rows(values_only=True)]
        rows = [r for r in rows if any(c not in (None, "") for c in r)]
        if not rows:
            continue
        parts.append(f"## Blad: {ws.title}\n\n" + md_table(rows[:2000]))
        if len(rows) > 2000:
            parts.append(f"_({len(rows) - 2000} rijen weggelaten)_")
    return "\n\n".join(parts)


def conv_csv(path: Path) -> str:
    with path.open(newline="", encoding="utf-8", errors="replace") as f:
        sample = f.read(4096)
        f.seek(0)
        try:
            dialect = csv.Sniffer().sniff(sample, delimiters=",;\t")
        except csv.Error:
            dialect = csv.excel
        rows = list(csv.reader(f, dialect))
    return md_table(rows[:2000])


def iter_shapes(shapes):
    """Alle shapes, ook die binnen groepen."""
    for shape in shapes:
        yield shape
        if hasattr(shape, "shapes"):  # groepsshape
            yield from iter_shapes(shape.shapes)


def conv_pptx(path: Path, ocr: bool = False) -> str:
    from io import BytesIO

    from PIL import Image, UnidentifiedImageError
    from pptx import Presentation

    prs = Presentation(str(path))
    parts: list[str] = []
    for i, slide in enumerate(prs.slides, 1):
        title = ""
        body: list[str] = []
        for shape in slide.shapes:
            if shape.has_text_frame:
                txt = "\n".join(p.text for p in shape.text_frame.paragraphs if p.text.strip())
                if not txt:
                    continue
                if shape == getattr(slide.shapes, "title", None) or (not title and shape.name.lower().startswith("title")):
                    title = txt
                else:
                    body.append(txt)
            if getattr(shape, "has_table", False) and shape.has_table:
                rows = [[c.text for c in r.cells] for r in shape.table.rows]
                body.append(md_table(rows))
        if ocr and readable_chars("\n".join([title, *body])) < LOW_TEXT:
            # slide (vrijwel) zonder tekst: vaak één grote afbeelding (NotebookLM-export, scan met titel)
            for shape in iter_shapes(slide.shapes):
                if not hasattr(shape, "image"):
                    continue
                try:
                    img = Image.open(BytesIO(shape.image.blob))
                except UnidentifiedImageError:
                    continue  # vectorformaten als EMF/WMF kan Pillow niet lezen
                txt = ocr_image(img, f"slide {i}")
                if txt:
                    body.append(txt)
        notes = ""
        if slide.has_notes_slide:
            notes = slide.notes_slide.notes_text_frame.text.strip()
        parts.append(f"## Slide {i}" + (f": {title}" if title else ""))
        parts.extend(body)
        if notes:
            parts.append("> Notities: " + notes.replace("\n", " "))
    return "\n\n".join(parts)


def conv_pdf(path: Path, ocr: bool = False) -> str:
    import pymupdf as fitz

    doc = fitz.open(str(path))
    parts: list[str] = []
    for i, page in enumerate(doc, 1):
        text = page.get_text("text").strip()
        if not text and ocr:
            from PIL import Image
            pix = page.get_pixmap(dpi=200)
            img = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)
            text = ocr_image(img, f"pagina {i}")
        if text:
            parts.append(f"## Pagina {i}\n\n{text}")
    return "\n\n".join(parts)


def conv_image(path: Path, ocr: bool = False) -> str:
    from PIL import Image, ImageSequence
    if not ocr:
        raise RuntimeError("afbeeldingen worden alleen met OCR gelezen")
    with Image.open(path) as img:
        frames = [f.copy() for f in ImageSequence.Iterator(img)]
    if len(frames) == 1:
        return ocr_image(frames[0], "afbeelding")
    # meerpagina-TIFF (scans): elke pagina apart
    return "\n\n".join(f"## Pagina {i}\n\n{ocr_image(f, f'pagina {i}')}" for i, f in enumerate(frames, 1))


def conv_html(path: Path) -> str:
    from markdownify import markdownify
    html = path.read_text(encoding="utf-8", errors="replace")
    return markdownify(html, heading_style="ATX", strip=["script", "style"])


def conv_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def conv_json(path: Path) -> str:
    data = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    return "```json\n" + json.dumps(data, ensure_ascii=False, indent=2) + "\n```"


def conv_rtf(path: Path) -> str:
    # macOS: textutil zit standaard in het systeem
    try:
        out = subprocess.run(["textutil", "-convert", "txt", "-stdout", str(path)],
                             capture_output=True, text=True, check=True)
        return out.stdout
    except Exception:  # noqa: BLE001
        raw = path.read_text(encoding="latin-1", errors="replace")
        return re.sub(r"\\[a-z]+-?\d* ?|[{}]", "", raw)


CONVERTERS = {
    ".docx": conv_docx, ".xlsx": conv_xlsx, ".xlsm": conv_xlsx, ".csv": conv_csv,
    ".pptx": conv_pptx, ".pdf": conv_pdf, ".html": conv_html, ".htm": conv_html,
    ".txt": conv_text, ".md": conv_text, ".json": conv_json, ".rtf": conv_rtf,
    **{ext: conv_image for ext in IMAGE_EXTS},
}


def readable_chars(body: str) -> int:
    """Tekens buiten koppen en witruimte: '## Slide 3' telt niet als inhoud."""
    return sum(len(line.strip()) for line in body.splitlines() if not line.lstrip().startswith("#"))


# ---------- hoofdloop ----------

def convert_one(src: Path, dst: Path, ocr: bool, src_sha1: str) -> tuple[str, int]:
    """Zet src om naar dst; geeft de sha1 van het geschreven bestand en het aantal leesbare tekens."""
    ext = src.suffix.lower()
    fn = CONVERTERS[ext]
    body = fn(src, ocr) if ext in OCR_EXTS else fn(src)
    body = clean(body)
    front = {
        "source": str(src),
        "type": ext.lstrip("."),
        "sha1": src_sha1,
        "modified": datetime.fromtimestamp(src.stat().st_mtime, tz=timezone.utc).isoformat(timespec="seconds"),
        "converted": datetime.now(tz=timezone.utc).isoformat(timespec="seconds"),
        "chars": len(body),
    }
    fm = "---\n" + "\n".join(f"{k}: {json.dumps(v, ensure_ascii=False)}" for k, v in front.items()) + "\n---\n\n"
    write_atomic(dst, fm + f"# {src.stem}\n\n" + body)
    return sha1_of(dst), readable_chars(body)


def is_own_output(path: Path, out: Path) -> bool:
    return path.name.endswith(SHADOW_SUFFIX) or path in (out / LEGACY_INDEX, out / MANIFEST_NAME)


def valid_key(out: Path, key: str) -> bool:
    """Manifest-sleutels moeten relatieve paden binnen <out> zijn die eindigen op de suffix."""
    rel = Path(key)
    return (not rel.is_absolute() and ".." not in rel.parts and key.endswith(SHADOW_SUFFIX)
            and (out / rel).resolve().is_relative_to(out))


def manifest_source_root(out: Path) -> str | None:
    path = out / MANIFEST_NAME
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8")).get("source_root")


def load_manifest(out: Path) -> dict[str, dict]:
    path = out / MANIFEST_NAME
    if not path.exists():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("version") != MANIFEST_VERSION or data.get("tool") != "kb_prep":
        raise SystemExit(f"{path} is geen kb_prep-manifest (versie {MANIFEST_VERSION}), afgebroken")
    files = {}
    for key, entry in data.get("files", {}).items():
        if valid_key(out, key) and isinstance(entry, dict) and "shadow_sha1" in entry:
            files[key] = entry
        else:
            print(f"  ! ongeldige manifestregel genegeerd: {key!r}", file=sys.stderr)
    return files


def save_manifest(out: Path, manifest: dict[str, dict], source_root: Path) -> None:
    write_atomic(out / MANIFEST_NAME,
                 json.dumps({"version": MANIFEST_VERSION, "tool": "kb_prep",
                             "source_root": str(source_root), "files": manifest},
                            ensure_ascii=False, indent=2, sort_keys=True))


def owned_and_unchanged(dst: Path, entry: dict | None) -> bool:
    return entry is not None and dst.exists() and sha1_of(dst) == entry["shadow_sha1"]


def shadow_path(src_root: Path, out: Path, src: Path) -> Path:
    rel = src.relative_to(src_root)
    return out / rel.parent / (rel.name + SHADOW_SUFFIX)


def default_root() -> Path:
    """KB_ROOT uit de omgeving of een .env vanaf de werkmap, anders ~/KB_md."""
    if "KB_ROOT" not in os.environ:
        try:
            from dotenv import dotenv_values, find_dotenv
            root = dotenv_values(find_dotenv(usecwd=True)).get("KB_ROOT")
        except ImportError:
            root = None
        if root:
            return Path(root).expanduser()
    return Path(os.environ.get("KB_ROOT") or "~/KB_md").expanduser()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Zet een KB-map om naar Markdown.")
    ap.add_argument("src", type=Path, help="bronmap met documenten")
    ap.add_argument("out", type=Path, nargs="?",
                    help="doelmap (standaard KB_ROOT, project = naam van de bronmap)")
    ap.add_argument("--project", help="submap onder <out> voor dit project")
    ap.add_argument("--force", action="store_true",
                    help="alles opnieuw omzetten, ook aangepaste eigen schaduwbestanden overschrijven")
    ap.add_argument("--ocr", action=argparse.BooleanOptionalAction, default=True,
                    help="OCR op PDF-pagina's zonder tekstlaag (standaard aan)")
    a = ap.parse_args(argv)
    if a.out is None:
        a.out = default_root()
        if a.project is None:
            a.project = a.src.expanduser().resolve().name
    if a.project is not None:
        if not PROJECT_NAME.fullmatch(a.project) or ".." in a.project:
            print(f"Ongeldige projectnaam: {a.project!r} (letters, cijfers, spatie, . _ -); "
                  "kies er een met --project", file=sys.stderr)
            return 2
        a.out = a.out / a.project
    a.src, a.out = a.src.expanduser().resolve(), a.out.expanduser().resolve()

    if not a.src.is_dir():
        print(f"Bronmap niet gevonden: {a.src}", file=sys.stderr)
        return 2
    a.out.mkdir(parents=True, exist_ok=True)

    with (a.out / LOCK_NAME).open("a") as lock:  # "a": nooit iets leegmaken
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(f"Er draait al een kb_prep op {a.out}", file=sys.stderr)
            return 3
        return run(a)


def run(a: argparse.Namespace) -> int:
    print(f"Bron: {a.src}\nDoel: {a.out}")
    manifest = load_manifest(a.out)
    bound = manifest_source_root(a.out)
    if manifest and bound and bound != str(a.src) and not a.force:
        # anders ruimt deze run alle schaduwbestanden van de andere bronmap op
        print(f"{a.out} hoort bij bronmap {bound}, niet bij {a.src}. Kies een ander project met "
              f"--project, of gebruik --force om deze KB aan de nieuwe bronmap te koppelen.", file=sys.stderr)
        return 2
    stats = {"ok": 0, "skip": 0, "fail": 0, "unsupported": 0, "removed": 0, "conflict": 0}
    low_text: list[tuple[Path, int]] = []
    expected: set[str] = set()
    failures: list[tuple[Path, str]] = []
    for src in sorted(p for p in a.src.rglob("*") if p.is_file()):
        if src.name.startswith(("~$", ".")) or is_own_output(src, a.out) or src == a.out / LOCK_NAME:
            continue
        ext = src.suffix.lower()
        if ext not in SUPPORTED or (ext in IMAGE_EXTS and not a.ocr):
            stats["unsupported"] += 1
            continue
        rel = src.relative_to(a.src)
        dst = shadow_path(a.src, a.out, src)
        key = str(dst.relative_to(a.out))
        expected.add(key)
        entry = manifest.get(key)

        if dst.exists():
            if entry is None:
                stats["conflict"] += 1
                print(f"  ! {rel}: {key} bestaat al en staat niet in het manifest, overgeslagen", file=sys.stderr)
                continue
            if not owned_and_unchanged(dst, entry) and not a.force:
                stats["conflict"] += 1
                print(f"  ! {rel}: {key} is na conversie aangepast, overgeslagen (--force overschrijft)",
                      file=sys.stderr)
                continue

        try:
            src_sha1 = sha1_of(src)
            if (not a.force and owned_and_unchanged(dst, entry) and entry.get("source") == str(src)
                    and entry.get("source_sha1") == src_sha1
                    and entry.get("converter") == CONVERTER_VERSION
                    and (ext not in OCR_EXTS or entry.get("ocr") == a.ocr)):
                stats["skip"] += 1
                if entry.get("chars", LOW_TEXT) < LOW_TEXT:
                    low_text.append((rel, entry["chars"]))  # blijft melden tot de bron beter is
                continue
            shadow_sha1, chars = convert_one(src, dst, a.ocr, src_sha1)
        except Exception as e:  # noqa: BLE001
            stats["fail"] += 1
            if owned_and_unchanged(dst, entry):
                dst.unlink()  # geen verouderde versie in de index laten staan
            manifest.pop(key, None)
            save_manifest(a.out, manifest, a.src)
            failures.append((rel, f"{type(e).__name__}: {e}"))
            print(f"  ✗ {rel}: {e}", file=sys.stderr)
            continue
        manifest[key] = {
            "source": str(src),
            "source_sha1": src_sha1,
            "shadow_sha1": shadow_sha1,
            "ocr": a.ocr,
            "converter": CONVERTER_VERSION,
            "chars": chars,
            "converted": datetime.now(tz=timezone.utc).isoformat(timespec="seconds"),
        }
        save_manifest(a.out, manifest, a.src)  # direct vastleggen, zodat een crash geen eigen output verweesd achterlaat
        stats["ok"] += 1
        if chars < LOW_TEXT:
            low_text.append((rel, chars))
            hint = "" if a.ocr or ext not in OCR_EXTS else ", probeer zonder --no-ocr"
            print(f"  ⚠ {rel}: maar {chars} tekens tekst{hint}")
        else:
            print(f"  ✓ {rel}")

    # schaduwbestanden van verwijderde of niet meer ondersteunde bronnen opruimen,
    # maar alleen als ze van kb_prep zijn en sindsdien niet zijn aangepast
    for key in sorted(set(manifest) - expected):
        dst = a.out / key
        if owned_and_unchanged(dst, manifest[key]):
            dst.unlink()
            stats["removed"] += 1
            print(f"  - {key} (bron weg)")
        elif dst.exists():
            stats["conflict"] += 1
            print(f"  ! {key}: bron weg maar bestand is aangepast, laten staan", file=sys.stderr)
        del manifest[key]
    save_manifest(a.out, manifest, a.src)

    (a.out / LEGACY_INDEX).unlink(missing_ok=True)

    print(f"\nKlaar: {stats['ok']} omgezet, {stats['skip']} overgeslagen (al actueel), "
          f"{stats['fail']} mislukt, {stats['unsupported']} niet-ondersteund, {stats['removed']} opgeruimd, "
          f"{stats['conflict']} conflict, {len(low_text)} met weinig tekst.")
    if low_text:
        print(f"\nWeinig tekst (< {LOW_TEXT} tekens), staat wel in de KB maar controleer de bron:")
        for rel, chars in low_text:
            print(f"  {rel}: {chars}")
    if failures:
        print("\nMislukt:")
        for rel, err in failures:
            print(f"  {rel}: {err}")
    return 1 if failures or stats["conflict"] else 0


if __name__ == "__main__":
    sys.exit(main())
