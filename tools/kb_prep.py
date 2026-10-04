#!/usr/bin/env python3
"""
kb_prep.py : zet een kennisbank-map om naar Markdown.

Ondersteund: .docx .xlsx .xlsm .csv .pptx .pdf .html .htm .txt .md .json .rtf (via textutil op macOS)
Resultaat: dezelfde mappenstructuur onder <out>/, elk bestand als <naam>.<ext>.kb-hint-meet.md
met YAML-frontmatter. Aan die suffix herkent het script zijn eigen schaduwbestanden: ze worden nooit
als bron gelezen, en alleen zij worden opgeruimd als de bron verdwenen is. <out> mag dus ook binnen
<bron> liggen of gelijk zijn aan <bron>.

Gebruik:
    python kb_prep.py <bron-map> <doel-map> [--force] [--ocr]

    --force   overschrijf ook als de .md nieuwer is dan de bron
    --ocr     probeer OCR op PDF-pagina's zonder tekstlaag (vereist pytesseract + tesseract)

Vereisten (pip): python-docx openpyxl python-pptx pymupdf markdownify
Optioneel:       pytesseract (OCR)
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

SUPPORTED = {".docx", ".xlsx", ".xlsm", ".csv", ".pptx", ".pdf", ".html", ".htm",
             ".txt", ".md", ".json", ".rtf"}
SHADOW_SUFFIX = ".kb-hint-meet.md"
INDEX_NAME = "_index.json"

# ---------- hulpfuncties ----------

def sha1_of(path: Path) -> str:
    h = hashlib.sha1()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:12]


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


def conv_pptx(path: Path) -> str:
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
            try:
                import pytesseract
                from PIL import Image
                pix = page.get_pixmap(dpi=200)
                img = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)
                text = pytesseract.image_to_string(img, lang="nld+eng").strip()
            except Exception as e:  # noqa: BLE001
                raise RuntimeError(f"OCR mislukt op pagina {i}: {e}") from e
        if text:
            parts.append(f"## Pagina {i}\n\n{text}")
    return "\n\n".join(parts)


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
}


# ---------- hoofdloop ----------

def convert_one(src: Path, dst: Path, ocr: bool) -> str:
    ext = src.suffix.lower()
    fn = CONVERTERS[ext]
    body = fn(src, ocr) if ext == ".pdf" else fn(src)
    body = clean(body)
    front = {
        "source": str(src),
        "type": ext.lstrip("."),
        "sha1": sha1_of(src),
        "modified": datetime.fromtimestamp(src.stat().st_mtime, tz=timezone.utc).isoformat(timespec="seconds"),
        "converted": datetime.now(tz=timezone.utc).isoformat(timespec="seconds"),
        "chars": len(body),
    }
    fm = "---\n" + "\n".join(f"{k}: {json.dumps(v, ensure_ascii=False)}" for k, v in front.items()) + "\n---\n\n"
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(fm + f"# {src.stem}\n\n" + body, encoding="utf-8")
    return "ok"


def is_own_output(path: Path, out: Path) -> bool:
    return path.name.endswith(SHADOW_SUFFIX) or path == out / INDEX_NAME


def shadow_path(src_root: Path, out: Path, src: Path) -> Path:
    rel = src.relative_to(src_root)
    return out / rel.parent / (rel.name + SHADOW_SUFFIX)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Zet een KB-map om naar Markdown.")
    ap.add_argument("src", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--ocr", action="store_true")
    a = ap.parse_args(argv)
    a.src, a.out = a.src.expanduser().resolve(), a.out.expanduser().resolve()

    if not a.src.is_dir():
        print(f"Bronmap niet gevonden: {a.src}", file=sys.stderr)
        return 2
    a.out.mkdir(parents=True, exist_ok=True)

    stats = {"ok": 0, "skip": 0, "fail": 0, "unsupported": 0, "removed": 0}
    expected: set[Path] = set()
    failures: list[tuple[Path, str]] = []
    for src in sorted(p for p in a.src.rglob("*") if p.is_file()):
        if src.name.startswith(("~$", ".")) or is_own_output(src, a.out):
            continue
        ext = src.suffix.lower()
        if ext not in SUPPORTED:
            stats["unsupported"] += 1
            continue
        rel = src.relative_to(a.src)
        dst = shadow_path(a.src, a.out, src)
        expected.add(dst)
        if dst.exists() and not a.force and dst.stat().st_mtime >= src.stat().st_mtime:
            stats["skip"] += 1
            continue
        try:
            convert_one(src, dst, a.ocr)
            stats["ok"] += 1
            print(f"  ✓ {rel}")
        except Exception as e:  # noqa: BLE001
            stats["fail"] += 1
            dst.unlink(missing_ok=True)  # geen verouderde versie in de index laten staan
            failures.append((rel, f"{type(e).__name__}: {e}"))
            print(f"  ✗ {rel}: {e}", file=sys.stderr)

    # schaduwbestanden van verwijderde of niet meer ondersteunde bronnen opruimen
    for md in a.out.rglob("*" + SHADOW_SUFFIX):
        if md not in expected:
            md.unlink()
            stats["removed"] += 1
            print(f"  - {md.relative_to(a.out)} (bron weg)")

    # index voor de retriever
    index = []
    for md in sorted(a.out.rglob("*" + SHADOW_SUFFIX)):
        head = md.read_text(encoding="utf-8", errors="replace")[:2000]
        m = re.search(r'^source: "(.*)"$', head, re.M)
        index.append({"md": str(md.relative_to(a.out)), "source": m.group(1) if m else None})
    (a.out / INDEX_NAME).write_text(json.dumps(index, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"\nKlaar: {stats['ok']} omgezet, {stats['skip']} overgeslagen (al actueel), "
          f"{stats['fail']} mislukt, {stats['unsupported']} niet-ondersteund, {stats['removed']} opgeruimd. "
          f"Index: {a.out / INDEX_NAME}")
    if failures:
        print("\nMislukt:")
        for rel, err in failures:
            print(f"  {rel}: {err}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
