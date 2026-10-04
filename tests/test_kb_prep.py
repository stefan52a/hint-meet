import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import kb_prep  # noqa: E402
from kb_prep import SHADOW_SUFFIX, main  # noqa: E402


def shadows(out: Path) -> list[str]:
    return sorted(str(p.relative_to(out)) for p in out.rglob("*" + SHADOW_SUFFIX))


def index(out: Path) -> list[dict]:
    return json.loads((out / "_index.json").read_text(encoding="utf-8"))


def test_shadow_name_keeps_extension_and_suffix(tmp_path):
    src, out = tmp_path / "kb", tmp_path / "out"
    (src / "sub").mkdir(parents=True)
    (src / "sub" / "notitie.txt").write_text("hallo", encoding="utf-8")
    (src / "tabel.csv").write_text("a;b\n1;2\n", encoding="utf-8")

    assert main([str(src), str(out)]) == 0
    assert shadows(out) == ["sub/notitie.txt" + SHADOW_SUFFIX, "tabel.csv" + SHADOW_SUFFIX]
    assert [e["md"] for e in index(out)] == ["sub/notitie.txt" + SHADOW_SUFFIX, "tabel.csv" + SHADOW_SUFFIX]


# 1. output binnen de bron wordt niet opnieuw ingelezen

@pytest.mark.parametrize("out_rel", ["_md", "."])
def test_output_inside_source_is_not_reingested(tmp_path, out_rel):
    src = tmp_path / "kb"
    src.mkdir()
    (src / "a.txt").write_text("inhoud", encoding="utf-8")
    (src / "eigen.md").write_text("# eigen notitie", encoding="utf-8")
    out = src / out_rel

    assert main([str(src), str(out)]) == 0
    first = shadows(out)
    assert main([str(src), str(out), "--force"]) == 0
    assert shadows(out) == first
    assert not any(SHADOW_SUFFIX + SHADOW_SUFFIX in s for s in first)
    assert not any("_index.json" in s for s in first)
    # de eigen .md van de gebruiker blijft staan en wordt gewoon omgezet
    assert (src / "eigen.md").exists()
    assert any(s.endswith("eigen.md" + SHADOW_SUFFIX) for s in first)


# 2. lege of niet-ondersteunde invoer crasht niet

def test_empty_source_writes_empty_index(tmp_path):
    src, out = tmp_path / "kb", tmp_path / "nog" / "niet" / "aanwezig"
    src.mkdir()
    assert main([str(src), str(out)]) == 0
    assert index(out) == []


def test_only_unsupported_files(tmp_path):
    src, out = tmp_path / "kb", tmp_path / "out"
    src.mkdir()
    (src / "foto.jpg").write_bytes(b"\xff\xd8")
    assert main([str(src), str(out)]) == 0
    assert index(out) == []


# 3. verwijderde bronnen verdwijnen uit output en index

def test_deleted_source_is_removed(tmp_path):
    src, out = tmp_path / "kb", tmp_path / "out"
    src.mkdir()
    (src / "blijft.txt").write_text("x", encoding="utf-8")
    (src / "weg.txt").write_text("y", encoding="utf-8")
    assert main([str(src), str(out)]) == 0
    assert len(shadows(out)) == 2

    (src / "weg.txt").unlink()
    assert main([str(src), str(out)]) == 0
    assert shadows(out) == ["blijft.txt" + SHADOW_SUFFIX]
    assert [e["md"] for e in index(out)] == ["blijft.txt" + SHADOW_SUFFIX]


def test_cleanup_never_touches_other_md_files(tmp_path):
    src, out = tmp_path / "kb", tmp_path / "out"
    src.mkdir()
    out.mkdir()
    (out / "handmatig.md").write_text("niet weggooien", encoding="utf-8")
    assert main([str(src), str(out)]) == 0
    assert (out / "handmatig.md").exists()
    assert index(out) == []


# 4. mislukte OCR telt als mislukt, niet als tekst in de KB

def test_ocr_failure_is_reported_as_failure(tmp_path, monkeypatch):
    fitz = pytest.importorskip("pymupdf")
    src, out = tmp_path / "kb", tmp_path / "out"
    src.mkdir()
    doc = fitz.open()
    doc.new_page()  # pagina zonder tekstlaag
    doc.save(str(src / "scan.pdf"))

    class Broken:
        @staticmethod
        def image_to_string(*_a, **_k):
            raise RuntimeError("tesseract niet gevonden")

    monkeypatch.setitem(sys.modules, "pytesseract", Broken)
    assert main([str(src), str(out), "--ocr"]) == 1
    assert shadows(out) == []
    assert index(out) == []


def test_ocr_failure_raises_from_converter(tmp_path, monkeypatch):
    fitz = pytest.importorskip("pymupdf")
    pdf = tmp_path / "scan.pdf"
    doc = fitz.open()
    doc.new_page()
    doc.save(str(pdf))
    monkeypatch.setitem(sys.modules, "pytesseract", None)  # import faalt
    with pytest.raises(RuntimeError, match="OCR mislukt op pagina 1"):
        kb_prep.conv_pdf(pdf, ocr=True)
