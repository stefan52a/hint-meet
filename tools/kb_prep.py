#!/usr/bin/env python3
"""
kb_prep.py : zet een kennisbank-map om naar Markdown.

Ondersteund: .docx .xlsx .xlsm .csv .pptx .pdf .html .htm .txt .md .json .rtf (via textutil op macOS),
             .eml (kop, tekst en bijlagen), en met OCR ook .png .jpg .jpeg .tif .tiff .webp
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
    .kbignore in de root van de bronmap sluit bestanden uit (gitignore-syntax, bv. tmp/ of *.log);
              al bestaande schaduwbestanden daarvan worden opgeruimd
    .kbpasswords in de root van de bronmap: wachtwoorden (één per regel, # is commentaar) die
              kb_prep probeert bij beveiligde PDF's; het bestand zelf komt nooit in de KB
    Altijd overgeslagen: dependency-mappen (node_modules, __pycache__, venv, Pods, ...), mappen die
              met een punt beginnen (.git, .venv) en build-mappen (build, dist, target, out, bin,
              obj) als er een projectbestand naast staat (package.json, pyproject.toml, Makefile, ...)
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
import shutil
import subprocess
import time
import sys
from datetime import datetime, timezone
from pathlib import Path

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".webp"}
SUPPORTED = {".docx", ".xlsx", ".xlsm", ".csv", ".pptx", ".pdf", ".html", ".htm",
             ".txt", ".md", ".json", ".rtf", ".eml"} | IMAGE_EXTS
OCR_EXTS = {".pdf", ".pptx", ".docx", ".eml"} | IMAGE_EXTS  # uitkomst hangt af van --ocr/--no-ocr
# Ophogen als de conversie zelf verbetert: bestaande schaduwbestanden worden dan opnieuw gemaakt.
CONVERTER_VERSION = 3
# Per bestandstype hoger dan de basis, zodat een verbetering alleen dat type opnieuw doet.
# 4: docx zonder stijl, OCR in docx met alleen afbeeldingen, foto's zonder tekst.
# 5 (afbeeldingen): korte OCR-tekst van foto's bewaren, gemarkeerd als onzeker.
# 4 (eml): ingebedde afbeeldingen overslaan.
TYPE_VERSION = {".docx": 4, ".eml": 4, **{ext: 5 for ext in IMAGE_EXTS}}
PHOTO_NOTE = "## Foto zonder (veel) herkenbare tekst"  # kop: telt niet mee als tekst


def converter_version(ext: str) -> int | str:
    if ext == ".eml":
        # bijlagen gaan door de andere converters: elke wijziging daarin telt mee, dus een
        # vingerafdruk van alle versies (een maximum mist een ophoging onder het maximum)
        return f"{CONVERTER_VERSION}|" + ",".join(f"{k}={v}" for k, v in sorted(TYPE_VERSION.items()))
    return max(CONVERTER_VERSION, TYPE_VERSION.get(ext, 0))
MAX_EMAIL_DEPTH = 5  # doorgestuurd in doorgestuurd in ...
IGNORE_FILE = ".kbignore"  # gitignore-syntax, in de root van de bronmap
PASSWORD_FILE = ".kbpasswords"  # wachtwoorden voor beveiligde PDF's, één per regel, in de root van de bronmap
PDF_PASSWORDS: list[str] = []  # gevuld door run()
LOW_TEXT = 50
OCR_TIMEOUT = 120  # seconden per afbeelding  # minder leesbare tekens dan dit: waarschuwen
PROJECT_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._ -]*")
SHADOW_SUFFIX = ".kb-hint-meet.md"
LEGACY_INDEX = "_index.json"  # vroeger geschreven, nu overbodig naast het manifest; wordt opgeruimd
MANIFEST_NAME = "_manifest.json"
MANIFEST_VERSION = 1
LOCK_NAME = ".kb_prep.lock"
# dependencies en gegenereerde bestanden horen niet in de KB; mappen met een punt (.git, .venv) ook niet
SKIP_DIRS = {"node_modules", "bower_components", "jspm_packages", "__pycache__", "venv", "site-packages",
             "Pods", "DerivedData"}
# gewone woorden: alleen overslaan naast een projectbestand, een map "dist" in de administratie blijft staan
BUILD_DIRS = {"build", "dist", "target", "out", "bin", "obj"}
PROJECT_MARKERS = {"package.json", "pyproject.toml", "setup.py", "Cargo.toml", "pom.xml", "build.gradle",
                   "build.gradle.kts", "Makefile", "CMakeLists.txt", "go.mod", "Package.swift", "composer.json"}
OCR_STRIP = 8000  # pixels: hogere afbeeldingen in stroken door tesseract (dat weigert bv. 6000x41844)
# macOS/Linux staan 255 bytes per naam toe; ruimte laten voor ".<naam>.<pid>.tmp" van write_atomic
MAX_SHADOW_NAME = 255 - len(".99999999.tmp") - 1

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

def no_tick(done: int, total: int, unit: str) -> None:
    """Voortgang binnen een bestand (pagina's, slides); standaard doet het niets."""


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
        if img.width > OCR_STRIP * 4:
            img = img.resize((OCR_STRIP * 4, max(1, img.height * OCR_STRIP * 4 // img.width)))
        strips = (img.crop((0, y, img.width, min(y + OCR_STRIP, img.height)))
                  for y in range(0, img.height, OCR_STRIP))  # één strook tegelijk in het geheugen
        return "\n".join(pytesseract.image_to_string(s, lang="nld+eng", timeout=OCR_TIMEOUT).strip()
                         for s in strips).strip()
    except Exception as e:  # noqa: BLE001
        raise RuntimeError(f"OCR mislukt op {what}: {e}") from e


def conv_docx(path: Path, ocr: bool = False, tick=no_tick) -> str:
    from io import BytesIO

    from docx import Document
    from PIL import Image, UnidentifiedImageError
    from docx.table import Table
    from docx.text.paragraph import Paragraph

    try:
        doc = Document(str(path))
    except KeyError:  # onderdeel zonder content-type, bv. ingesloten fonts uit Google Docs
        doc = Document(repaired_ooxml(path))
    parts: list[str] = []
    for block in doc.element.body.iterchildren():
        tag = block.tag.split("}")[-1]
        if tag == "p":
            p = Paragraph(block, doc)
            t = p.text.strip()
            if not t:
                continue
            style = ((p.style.name if p.style is not None else None) or "").lower()
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
    if ocr and readable_chars("\n".join(parts)) < LOW_TEXT:
        # document (vrijwel) zonder tekst, bv. alleen geplakte screenshots
        blobs = [rel.target_part.blob for rel in doc.part.rels.values()
                 if "image" in rel.reltype and not rel.is_external]
        for i, blob in enumerate(blobs, 1):
            tick(i - 1, len(blobs), "afbeelding")
            try:
                img = Image.open(BytesIO(blob))
                img.load()
            except (UnidentifiedImageError, OSError, ValueError, ZeroDivisionError):
                continue  # WMF/EMF of kapot plaatje: overslaan, de rest van het document telt
            txt = ocr_image(img, f"afbeelding {i}")
            if txt:
                parts.append(txt)
    return "\n\n".join(parts)


def repaired_ooxml(path: Path):
    """Kopie van een Office-bestand (in het geheugen) waarin elk onderdeel een content-type heeft."""
    import zipfile
    from io import BytesIO
    from xml.sax.saxutils import escape
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        ct = z.read("[Content_Types].xml").decode("utf-8")
        known = {m.lower() for m in re.findall(r'Extension="([^"]+)"', ct)}
        missing = sorted({n.rsplit(".", 1)[-1].lower() for n in names
                          if "." in n.rsplit("/", 1)[-1] and n != "[Content_Types].xml"} - known)
        extra = "".join(f'<Default Extension="{escape(e, {chr(34): "&quot;"})}" ContentType="application/octet-stream"/>'
                        for e in missing)
        buf = BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as out:
            for n in names:
                data = z.read(n)
                if n == "[Content_Types].xml":
                    data = ct.replace("</Types>", extra + "</Types>").encode("utf-8")
                out.writestr(n, data)
    buf.seek(0)
    return buf


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


def conv_pptx(path: Path, ocr: bool = False, tick=no_tick) -> str:
    from io import BytesIO

    from PIL import Image, UnidentifiedImageError
    from pptx import Presentation

    prs = Presentation(str(path))
    parts: list[str] = []
    n_slides = len(prs.slides)
    for i, slide in enumerate(prs.slides, 1):
        tick(i - 1, n_slides, "slide")
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


def conv_pdf(path: Path, ocr: bool = False, tick=no_tick) -> str:
    import pymupdf as fitz

    doc = fitz.open(str(path))
    if doc.needs_pass and not any(doc.authenticate(pw) for pw in ["", *PDF_PASSWORDS]):
        raise RuntimeError(f"PDF is beveiligd met een wachtwoord (niet gevonden in {PASSWORD_FILE})")
    parts: list[str] = []
    for i, page in enumerate(doc, 1):
        tick(i - 1, doc.page_count, "pagina")
        text = page.get_text("text").strip()
        if not text and ocr:
            from PIL import Image
            pix = page.get_pixmap(dpi=200)
            img = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)
            text = ocr_image(img, f"pagina {i}")
        if text:
            parts.append(f"## Pagina {i}\n\n{text}")
    return "\n\n".join(parts)


def conv_image(path: Path, ocr: bool = False, tick=no_tick) -> str:
    from PIL import Image, ImageSequence
    if not ocr:
        raise RuntimeError("afbeeldingen worden alleen met OCR gelezen")
    with Image.open(path) as img:
        frames = [f.copy() for f in ImageSequence.Iterator(img)]
    if len(frames) == 1:
        text = ocr_image(frames[0], "afbeelding")
        if readable_chars(text) >= LOW_TEXT:
            return text
        # foto: naam en pad blijven vindbaar; korte OCR-tekst kan ruis zijn, maar ook "Enter PIN"
        # of een merknaam op een drukmeter, dus bewaren en als onzeker markeren
        snippet = " ".join(text.split())
        return PHOTO_NOTE + (f"\n\nHerkende tekst (OCR, onzeker): {snippet}" if snippet else "")
    # meerpagina-TIFF (scans): elke pagina apart
    parts = []
    for i, frame in enumerate(frames, 1):
        tick(i - 1, len(frames), "pagina")
        parts.append(f"## Pagina {i}\n\n{ocr_image(frame, f'pagina {i}')}")
    return "\n\n".join(parts)


def conv_html(path: Path) -> str:
    from markdownify import markdownify
    html = path.read_text(encoding="utf-8", errors="replace")
    return markdownify(html, heading_style="ATX", strip=["script", "style"])


def render_email(msg, ocr: bool, tick, depth: int = 0) -> str:
    """Kopregels, tekst (plain of html) en bijlagen van een e-mailbericht als Markdown."""
    import tempfile
    from markdownify import markdownify

    h = "#" * min(depth + 2, 6)
    head = []
    for label, field in (("Van", "from"), ("Aan", "to"), ("Cc", "cc"), ("Datum", "date"), ("Onderwerp", "subject")):
        if msg[field]:
            head.append(f"- **{label}:** {msg[field]}")
    parts = ["\n".join(head)]

    body = msg.get_body(preferencelist=("plain", "html"))
    if body is not None:
        text = body.get_content()
        if body.get_content_subtype() == "html":
            text = markdownify(text, heading_style="ATX", strip=["script", "style", "img"])
        parts.append(text.strip())

    for att in msg.iter_attachments():
        if att.get_content_maintype() == "image" and att.get_content_disposition() != "attachment":
            continue  # ingebedde afbeelding in de html (logo, handtekening), geen echte bijlage
        if att.get_content_type() == "message/rfc822":
            if depth + 1 >= MAX_EMAIL_DEPTH:
                parts.append(f"{h} Doorgestuurd bericht\n\n_(niet gelezen: dieper dan {MAX_EMAIL_DEPTH} niveaus)_")
                continue
            try:
                inner = att.get_payload()[0] if att.is_multipart() else att.get_content()
                parts.append(f"{h} Doorgestuurd bericht\n\n" + render_email(inner, ocr, tick, depth + 1))
            except Exception as e:  # noqa: BLE001
                parts.append(f"{h} Doorgestuurd bericht\n\n_(niet gelezen: {type(e).__name__}: {e})_")
            continue
        name = att.get_filename() or "bijlage"
        ext = Path(name).suffix.lower()
        if ext not in CONVERTERS or ext == ".eml" or (ext in IMAGE_EXTS and not ocr):
            parts.append(f"{h} Bijlage: {name}\n\n_(niet gelezen: bestandstype)_")
            continue
        try:
            with tempfile.TemporaryDirectory() as tmp:
                f = Path(tmp) / ("bijlage" + ext)
                if att.get_content_maintype() == "text":
                    # decodeer met de charset uit de mail; de converters lezen utf-8
                    f.write_text(att.get_content(), encoding="utf-8")
                else:
                    f.write_bytes(att.get_payload(decode=True) or b"")
                fn = CONVERTERS[ext]
                text = fn(f, ocr, tick) if ext in OCR_EXTS else fn(f)
            parts.append(f"{h} Bijlage: {name}\n\n{text.strip()}")
        except Exception as e:  # noqa: BLE001
            # een kapotte bijlage mag de mail zelf niet uit de KB houden
            parts.append(f"{h} Bijlage: {name}\n\n_(niet gelezen: {type(e).__name__}: {e})_")
    return "\n\n".join(p for p in parts if p)


def conv_eml(path: Path, ocr: bool = False, tick=no_tick) -> str:
    from email import policy
    from email.parser import BytesParser

    with path.open("rb") as f:
        msg = BytesParser(policy=policy.default).parse(f)
    return render_email(msg, ocr, tick)


def conv_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def conv_json(path: Path) -> str:
    raw = path.read_text(encoding="utf-8", errors="replace")
    try:
        raw = json.dumps(json.loads(raw), ensure_ascii=False, indent=2)
    except json.JSONDecodeError:
        pass  # bv. tsconfig met commentaar: dan de tekst zoals hij is
    return "```json\n" + raw.strip() + "\n```"


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
    ".txt": conv_text, ".md": conv_text, ".json": conv_json, ".rtf": conv_rtf, ".eml": conv_eml,
    **{ext: conv_image for ext in IMAGE_EXTS},
}


def readable_chars(body: str) -> int:
    """Tekens buiten koppen en witruimte: '## Slide 3' telt niet als inhoud."""
    return sum(len(line.strip()) for line in body.splitlines() if not line.lstrip().startswith("#"))


# ---------- hoofdloop ----------

def all_zero(path: Path) -> bool:
    with path.open("rb") as f:
        return all(not chunk.strip(b"\0") for chunk in iter(lambda: f.read(1 << 20), b""))


def convert_one(src: Path, dst: Path, ocr: bool, src_sha1: str, tick=no_tick) -> tuple[str, int]:
    """Zet src om naar dst; geeft de sha1 van het geschreven bestand en het aantal leesbare tekens."""
    ext = src.suffix.lower()
    fn = CONVERTERS[ext]
    with src.open("rb") as f:
        head = f.read(4096)
    if head and not head.strip(b"\0") and all_zero(src):
        raise RuntimeError("bestand bevat alleen nullen (beschadigd, bv. een Dropbox-conflictkopie)")
    if ext in {".docx", ".xlsx", ".xlsm", ".pptx"} and not head.startswith(b"PK"):
        raise RuntimeError(f"geen geldig {ext}-bestand (ander formaat met een {ext}-naam?)")
    body = fn(src, ocr, tick) if ext in OCR_EXTS else fn(src)
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


def shadow_name(name: str) -> str:
    """<naam>.kb-hint-meet.md, ingekort met een hash als de naam te lang wordt voor het bestandssysteem."""
    if len((name + SHADOW_SUFFIX).encode()) <= MAX_SHADOW_NAME:
        return name + SHADOW_SUFFIX
    tag = "~" + hashlib.sha1(name.encode()).hexdigest()[:8]
    room = MAX_SHADOW_NAME - len((tag + SHADOW_SUFFIX).encode())
    head = name.encode()[:room].decode("utf-8", errors="ignore").rstrip()
    return head + tag + SHADOW_SUFFIX


def shadow_path(src_root: Path, out: Path, src: Path) -> Path:
    rel = src.relative_to(src_root)
    return out / rel.parent / shadow_name(rel.name)


def lock_holder(text: str) -> str:
    """" (sinds 11:42, gestart vanuit de terminal, bron …, proces 4711)" uit het lockbestand, of ""."""
    try:
        info = json.loads(text)
        since = datetime.fromtimestamp(info["started"]).strftime("%H:%M")
        return f" (sinds {since}, gestart vanuit {info['from']}, bron {info['source']}, proces {info['pid']})"
    except (ValueError, KeyError, TypeError):
        return ""   # oud of leeg lockbestand


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

    with (a.out / LOCK_NAME).open("a+") as lock:  # "a+": pas leegmaken als we de lock hebben
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            lock.seek(0)
            print(f"Er draait al een kb_prep op {a.out}{lock_holder(lock.read())}. Wacht tot die klaar is "
                  "of stop hem, en probeer het daarna opnieuw.", file=sys.stderr)
            return 3
        # wie de lock heeft, zodat een tweede kb_prep kan zeggen welke run er al bezig is
        lock.truncate(0)
        lock.write(json.dumps({"pid": os.getpid(), "started": time.time(), "source": str(a.src),
                               "from": "HintMeet" if os.environ.get("KB_PREP_MACHINE")
                               else "de terminal" if sys.stdin.isatty() else "een script"}))
        lock.flush()
        try:
            return run(a)
        except KeyboardInterrupt:
            print("\nAfgebroken. Wat al omgezet is, blijft bewaard; de volgende run gaat verder.",
                  file=sys.stderr)
            return 130


def fmt_duration(seconds: float) -> str:
    if seconds < 90:
        return f"{seconds:.0f} s"
    if seconds < 90 * 60:
        return f"{seconds / 60:.0f} min"
    return f"{seconds / 3600:.1f} u"


class Progress:
    """Voortgangsregel die zichzelf overschrijft, alleen in een terminal.

    In een terminal: [ 3/18] naam op één regel, en alleen meldingen (⚠ ✗ ! -) als eigen regel.
    Anders (pipe, logbestand): elke regel blijft staan, ook ✓, zoals voorheen.
    """

    def __init__(self, total: int):
        self.total = total
        # beide naar de terminal: wie stdout naar een logbestand stuurt, wil daar ook de ✓-regels
        self.tty = sys.stderr.isatty() and sys.stdout.isatty()
        self.width = len(str(total))

    def update(self, i: int, name: str) -> None:
        self.i, self.name = i, name
        self.started = time.monotonic()
        if os.environ.get("KB_PREP_MACHINE"):  # voor HintMeet (hint-meet prepare): voortgang als regel
            print(f"@progress {i - 1} {self.total} Documenten bijwerken · {name}", flush=True)
        self._render("")

    def tick(self, done: int, total: int, unit: str) -> None:
        """Pagina's of slides binnen het huidige bestand, met een schatting van de resterende tijd."""
        if total <= 1:
            return
        tail = f" · {unit} {done + 1}/{total}"
        if done:
            left = (time.monotonic() - self.started) / done * (total - done)
            if left >= 5:
                tail += f" · nog ~{fmt_duration(left)}"
        if os.environ.get("KB_PREP_MACHINE"):  # deelvoortgang binnen het bestand, als breuk van het geheel
            print(f"@progress {self.i - 1 + done / total:.3f} {self.total} Documenten bijwerken · {self.name}{tail}",
                  flush=True)
        self._render(tail)

    def _render(self, tail: str) -> None:
        if not self.tty:
            return
        cols = shutil.get_terminal_size((80, 20)).columns - 1
        head = f"[{self.i:>{self.width}}/{self.total}] "
        room = cols - len(head) - len(tail)
        name = self.name if len(self.name) <= room else self.name[:max(room - 1, 0)] + "…"
        sys.stderr.write("\r\033[K" + (head + name + tail)[:cols])
        sys.stderr.flush()

    def clear(self) -> None:
        if self.tty:
            sys.stderr.write("\r\033[K")
            sys.stderr.flush()

    def log(self, msg: str, *, routine: bool = False, err: bool = False) -> None:
        """routine=True (✓) alleen buiten de terminal tonen, daar zegt de voortgangsregel genoeg."""
        if routine and self.tty:
            return
        self.clear()
        print(msg, file=sys.stderr if err else sys.stdout)


def is_build_dir(name: str, siblings: list[str]) -> bool:
    return (name in SKIP_DIRS or name.startswith(".") or name.endswith(".egg-info")
            or (name in BUILD_DIRS and not PROJECT_MARKERS.isdisjoint(siblings)))


def iter_sources(src_root: Path, unreadable: list[Path]):
    """Alle bestanden onder src_root, zonder af te dalen in dependency- en build-mappen.
    Mappen die niet te lezen zijn komen in unreadable: hun bestanden zijn niet weg, alleen onzichtbaar."""
    for dirpath, dirnames, filenames in os.walk(src_root, onerror=lambda e: unreadable.append(Path(e.filename))):
        dirnames[:] = [d for d in dirnames if not is_build_dir(d, filenames)]
        for name in filenames:
            yield Path(dirpath) / name


def load_passwords(src_root: Path) -> list[str]:
    path = src_root / PASSWORD_FILE
    if not path.exists():
        return []
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")]


def load_ignore(src_root: Path):
    """Patronen uit <bron>/.kbignore (gitignore-syntax), of None als er geen bestand is."""
    path = src_root / IGNORE_FILE
    if not path.exists():
        return None
    import pathspec
    return pathspec.GitIgnoreSpec.from_lines(path.read_text(encoding="utf-8").splitlines())


def run(a: argparse.Namespace) -> int:
    print(f"Bron: {a.src}\nDoel: {a.out}")
    manifest = load_manifest(a.out)
    bound = manifest_source_root(a.out)
    if manifest and bound and bound != str(a.src) and not a.force:
        # anders ruimt deze run alle schaduwbestanden van de andere bronmap op
        print(f"{a.out} hoort bij bronmap {bound}, niet bij {a.src}. Kies een ander project met "
              f"--project, of gebruik --force om deze KB aan de nieuwe bronmap te koppelen.", file=sys.stderr)
        return 2
    stats = {"ok": 0, "skip": 0, "fail": 0, "unsupported": 0, "removed": 0, "conflict": 0, "photos": 0,
             "ignored": 0}
    low_text: list[tuple[Path, int]] = []
    expected: set[str] = set()
    failures: list[tuple[Path, str]] = []
    todo: list[Path] = []
    ignore = load_ignore(a.src)
    PDF_PASSWORDS[:] = load_passwords(a.src)
    unreadable: list[Path] = []
    for src in sorted(iter_sources(a.src, unreadable)):
        if src.name.startswith(("~$", ".")) or is_own_output(src, a.out) or src == a.out / LOCK_NAME:
            continue
        if ignore and ignore.match_file(src.relative_to(a.src).as_posix()):
            stats["ignored"] += 1
            continue
        ext = src.suffix.lower()
        if ext not in SUPPORTED or (ext in IMAGE_EXTS and not a.ocr):
            stats["unsupported"] += 1
            continue
        todo.append(src)

    for d in unreadable:
        print(f"  ! {d}: map niet te lezen, bestaande schaduwbestanden blijven staan", file=sys.stderr)
        stats["conflict"] += 1
    for key, entry in manifest.items():  # niet opruimen wat we alleen niet konden zien
        if any(Path(entry.get("source", "")).is_relative_to(d) for d in unreadable):
            expected.add(key)

    progress = Progress(len(todo))
    try:
        return convert_all(a, todo, manifest, progress, stats, low_text, expected, failures)
    finally:
        progress.clear()  # ook bij Ctrl-C of een crash geen halve voortgangsregel laten staan


def convert_all(a, todo, manifest, progress, stats, low_text, expected, failures) -> int:
    for i, src in enumerate(todo, 1):
        ext = src.suffix.lower()
        rel = src.relative_to(a.src)
        progress.update(i, str(rel))
        dst = shadow_path(a.src, a.out, src)
        key = str(dst.relative_to(a.out))
        expected.add(key)
        entry = manifest.get(key)

        if dst.exists():
            if entry is None:
                stats["conflict"] += 1
                progress.log(f"  ! {rel}: {key} bestaat al en staat niet in het manifest, overgeslagen", err=True)
                continue
            if not owned_and_unchanged(dst, entry) and not a.force:
                stats["conflict"] += 1
                progress.log(f"  ! {rel}: {key} is na conversie aangepast, overgeslagen (--force overschrijft)",
                             err=True)
                continue

        try:
            src_sha1 = sha1_of(src)
            if (not a.force and owned_and_unchanged(dst, entry) and entry.get("source") == str(src)
                    and entry.get("source_sha1") == src_sha1
                    and entry.get("converter") == converter_version(ext)
                    and (ext not in OCR_EXTS or entry.get("ocr") == a.ocr)):
                stats["skip"] += 1
                if ext in IMAGE_EXTS and entry.get("chars", LOW_TEXT) < LOW_TEXT:
                    stats["photos"] += 1
                elif entry.get("chars", LOW_TEXT) < LOW_TEXT:
                    low_text.append((rel, entry["chars"]))  # blijft melden tot de bron beter is
                continue
            shadow_sha1, chars = convert_one(src, dst, a.ocr, src_sha1, tick=progress.tick)
        except Exception as e:  # noqa: BLE001
            stats["fail"] += 1
            if owned_and_unchanged(dst, entry):
                dst.unlink()  # geen verouderde versie in de KB laten staan
            manifest.pop(key, None)
            save_manifest(a.out, manifest, a.src)
            failures.append((rel, f"{type(e).__name__}: {e}"))
            progress.log(f"  ✗ {rel}: {e}", err=True)
            continue
        manifest[key] = {
            "source": str(src),
            "source_sha1": src_sha1,
            "shadow_sha1": shadow_sha1,
            "ocr": a.ocr,
            "converter": converter_version(ext),
            "chars": chars,
            "converted": datetime.now(tz=timezone.utc).isoformat(timespec="seconds"),
        }
        save_manifest(a.out, manifest, a.src)  # direct vastleggen, zodat een crash geen eigen output verweesd achterlaat
        stats["ok"] += 1
        if chars < LOW_TEXT and ext in IMAGE_EXTS:
            stats["photos"] += 1
            progress.log(f"  ✓ {rel} (foto zonder tekst)", routine=True)
        elif chars < LOW_TEXT:
            low_text.append((rel, chars))
            hint = "" if a.ocr or ext not in OCR_EXTS else ", probeer zonder --no-ocr"
            progress.log(f"  ⚠ {rel}: maar {chars} tekens tekst{hint}")
        else:
            progress.log(f"  ✓ {rel}", routine=True)
    progress.clear()

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
          f"{stats['conflict']} conflict, {len(low_text)} met weinig tekst"
          + (f", {stats['photos']} foto's met weinig of geen tekst" if stats["photos"] else "")
          + (f", {stats['ignored']} genegeerd via {IGNORE_FILE}" if stats["ignored"] else "")
          + ".")
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
