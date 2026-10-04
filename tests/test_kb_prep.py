import json
import os
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


def test_failed_reconversion_drops_old_shadow(tmp_path):
    src, out = tmp_path / "kb", tmp_path / "out"
    src.mkdir()
    (src / "data.json").write_text('{"a": 1}', encoding="utf-8")
    assert main([str(src), str(out)]) == 0
    assert shadows(out) == ["data.json" + SHADOW_SUFFIX]

    (src / "data.json").write_text("{kapot", encoding="utf-8")
    assert main([str(src), str(out), "--force"]) == 1
    assert shadows(out) == []
    assert index(out) == []


# manifest en eigendom

def manifest(out: Path) -> dict:
    return json.loads((out / "_manifest.json").read_text(encoding="utf-8"))


def make_kb(tmp_path, files: dict[str, str]):
    src, out = tmp_path / "kb", tmp_path / "out"
    src.mkdir()
    for name, text in files.items():
        (src / name).write_text(text, encoding="utf-8")
    return src, out


def test_manifest_records_ownership(tmp_path):
    src, out = make_kb(tmp_path, {"a.txt": "x"})
    assert main([str(src), str(out)]) == 0
    m = manifest(out)
    assert m["version"] == 1 and m["tool"] == "kb_prep"
    entry = m["files"]["a.txt" + SHADOW_SUFFIX]
    assert entry["source"] == str((src / "a.txt").resolve())
    assert entry["source_sha1"] == kb_prep.sha1_of(src / "a.txt")
    assert entry["shadow_sha1"] == kb_prep.sha1_of(out / ("a.txt" + SHADOW_SUFFIX))
    assert entry["ocr"] is True  # OCR staat standaard aan


def test_touched_but_unchanged_source_is_skipped(tmp_path, capsys):
    src, out = make_kb(tmp_path, {"a.txt": "x"})
    main([str(src), str(out)])
    later = (src / "a.txt").stat().st_mtime + 100
    os.utime(src / "a.txt", (later, later))
    capsys.readouterr()
    assert main([str(src), str(out)]) == 0
    assert "0 omgezet, 1 overgeslagen" in capsys.readouterr().out


def test_changed_content_with_old_mtime_is_reconverted(tmp_path):
    src, out = make_kb(tmp_path, {"a.txt": "oud"})
    main([str(src), str(out)])
    st = (src / "a.txt").stat()
    (src / "a.txt").write_text("nieuw", encoding="utf-8")
    os.utime(src / "a.txt", (st.st_atime, st.st_mtime))
    assert main([str(src), str(out)]) == 0
    assert "nieuw" in (out / ("a.txt" + SHADOW_SUFFIX)).read_text(encoding="utf-8")


def test_ocr_setting_change_only_reconverts_pdfs(tmp_path, capsys):
    fitz = pytest.importorskip("pymupdf")
    src, out = make_kb(tmp_path, {"a.txt": "x"})
    doc = fitz.open()
    doc.new_page().insert_text((72, 72), "tekstlaag")
    doc.save(str(src / "b.pdf"))
    main([str(src), str(out)])
    capsys.readouterr()
    assert main([str(src), str(out), "--no-ocr"]) == 0
    assert "1 omgezet, 1 overgeslagen" in capsys.readouterr().out
    assert manifest(out)["files"]["b.pdf" + SHADOW_SUFFIX]["ocr"] is False


def test_foreign_file_at_shadow_path_is_not_overwritten(tmp_path):
    src, out = make_kb(tmp_path, {"a.txt": "x"})
    out.mkdir()
    foreign = out / ("a.txt" + SHADOW_SUFFIX)
    foreign.write_text("---\nsource: \"ergens anders\"\n---\nvan hint-meet", encoding="utf-8")
    assert main([str(src), str(out), "--force"]) == 1
    assert "van hint-meet" in foreign.read_text(encoding="utf-8")
    assert manifest(out)["files"] == {}
    assert index(out) == []


def test_foreign_suffix_file_elsewhere_is_left_alone(tmp_path):
    src, out = make_kb(tmp_path, {"a.txt": "x"})
    out.mkdir()
    (out / ("notities-meeting.kb-hint-meet.md")).write_text("van hint-meet", encoding="utf-8")
    assert main([str(src), str(out)]) == 0
    assert (out / "notities-meeting.kb-hint-meet.md").exists()
    assert [e["md"] for e in index(out)] == ["a.txt" + SHADOW_SUFFIX]


def test_edited_shadow_needs_force(tmp_path):
    src, out = make_kb(tmp_path, {"a.txt": "x"})
    main([str(src), str(out)])
    shadow = out / ("a.txt" + SHADOW_SUFFIX)
    shadow.write_text(shadow.read_text(encoding="utf-8") + "\naantekening", encoding="utf-8")
    (src / "a.txt").write_text("y", encoding="utf-8")

    assert main([str(src), str(out)]) == 1
    assert "aantekening" in shadow.read_text(encoding="utf-8")
    assert main([str(src), str(out), "--force"]) == 0
    assert "aantekening" not in shadow.read_text(encoding="utf-8")


def test_edited_shadow_survives_source_deletion(tmp_path):
    src, out = make_kb(tmp_path, {"a.txt": "x"})
    main([str(src), str(out)])
    shadow = out / ("a.txt" + SHADOW_SUFFIX)
    shadow.write_text("aangepast", encoding="utf-8")
    (src / "a.txt").unlink()
    assert main([str(src), str(out)]) == 1
    assert shadow.exists()
    assert manifest(out)["files"] == {}
    assert index(out) == []


def test_shadow_without_manifest_entry_is_never_overwritten(tmp_path):
    src, out = make_kb(tmp_path, {"a.txt": "x"})
    main([str(src), str(out)])
    shadow = out / ("a.txt" + SHADOW_SUFFIX)
    shadow.write_text(shadow.read_text(encoding="utf-8") + "\neigen aantekening", encoding="utf-8")
    (out / "_manifest.json").unlink()
    assert main([str(src), str(out), "--force"]) == 1
    assert "eigen aantekening" in shadow.read_text(encoding="utf-8")


def test_manifest_cannot_delete_outside_output(tmp_path):
    src, out = make_kb(tmp_path, {})
    out.mkdir()
    victim = tmp_path / ("buiten" + SHADOW_SUFFIX)
    victim.write_text("niet aankomen", encoding="utf-8")
    sha = kb_prep.sha1_of(victim)
    bad = {"version": 1, "tool": "kb_prep", "files": {
        "../buiten" + SHADOW_SUFFIX: {"source": "x", "source_sha1": "x", "shadow_sha1": sha, "ocr": False},
        str(victim): {"source": "x", "source_sha1": "x", "shadow_sha1": sha, "ocr": False},
    }}
    (out / "_manifest.json").write_text(json.dumps(bad), encoding="utf-8")
    assert main([str(src), str(out)]) == 0
    assert victim.exists()
    assert manifest(out)["files"] == {}


def test_foreign_manifest_aborts(tmp_path):
    src, out = make_kb(tmp_path, {"a.txt": "x"})
    out.mkdir()
    (out / "_manifest.json").write_text(json.dumps({"version": 1, "tool": "iets-anders", "files": {}}))
    with pytest.raises(SystemExit):
        main([str(src), str(out)])


def test_other_source_root_with_same_content_is_reconverted(tmp_path):
    src, out = make_kb(tmp_path, {"a.txt": "x"})
    main([str(src), str(out)])
    src2 = tmp_path / "kb2"
    src2.mkdir()
    (src2 / "a.txt").write_text("x", encoding="utf-8")
    assert main([str(src2), str(out), "--force"]) == 0
    assert index(out)[0]["source"] == str((src2 / "a.txt").resolve())


def test_concurrent_run_is_refused(tmp_path):
    import fcntl
    src, out = make_kb(tmp_path, {"a.txt": "x"})
    out.mkdir()
    with (out / ".kb_prep.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        assert main([str(src), str(out)]) == 3
    assert main([str(src), str(out)]) == 0


def test_manifest_saved_after_each_conversion(tmp_path, monkeypatch):
    src, out = make_kb(tmp_path, {"a.txt": "x", "b.txt": "y"})
    real = kb_prep.convert_one

    def crash_on_b(s, d, ocr, sha):
        if s.name == "b.txt":
            raise KeyboardInterrupt
        return real(s, d, ocr, sha)

    monkeypatch.setattr(kb_prep, "convert_one", crash_on_b)
    with pytest.raises(KeyboardInterrupt):
        main([str(src), str(out)])
    assert list(manifest(out)["files"]) == ["a.txt" + SHADOW_SUFFIX]


@pytest.mark.skipif(os.geteuid() == 0, reason="root kan alles lezen")
def test_unreadable_source_is_a_failure_not_a_crash(tmp_path):
    src, out = make_kb(tmp_path, {"a.txt": "x", "b.txt": "y"})
    (src / "b.txt").chmod(0)
    try:
        assert main([str(src), str(out)]) == 1
    finally:
        (src / "b.txt").chmod(0o644)
    assert [e["md"] for e in index(out)] == ["a.txt" + SHADOW_SUFFIX]


def test_no_temp_files_left_behind(tmp_path):
    src, out = make_kb(tmp_path, {"a.txt": "x", "b.json": "{kapot"})
    main([str(src), str(out)])
    assert not list(out.rglob("*.tmp"))


# projecten

def test_project_writes_into_subfolder(tmp_path):
    src, out = make_kb(tmp_path, {"a.txt": "x"})
    assert main([str(src), str(out), "--project", "fabrikam"]) == 0
    assert shadows(out / "fabrikam") == ["a.txt" + SHADOW_SUFFIX]
    assert (out / "fabrikam" / "_manifest.json").exists()
    assert not (out / "_manifest.json").exists()


def test_projects_are_independent(tmp_path):
    src, out = make_kb(tmp_path, {"a.txt": "x"})
    src2 = tmp_path / "kb2"
    src2.mkdir()
    (src2 / "b.txt").write_text("y", encoding="utf-8")
    main([str(src), str(out), "--project", "een"])
    main([str(src2), str(out), "--project", "twee"])
    before = {f: (out / "een" / f).read_bytes() for f in ("_manifest.json", "_index.json")}

    # bron van project twee leeg: alles in twee wordt opgeruimd, een blijft ongemoeid
    (src2 / "b.txt").unlink()
    assert main([str(src2), str(out), "--project", "twee"]) == 0
    assert shadows(out / "twee") == []
    assert index(out / "twee") == []
    assert shadows(out / "een") == ["a.txt" + SHADOW_SUFFIX]
    assert {f: (out / "een" / f).read_bytes() for f in before} == before


@pytest.mark.parametrize("name", ["../weg", "a/b", ".verborgen", "_index", "..", ""])
def test_invalid_project_name_is_refused(tmp_path, name):
    src, out = make_kb(tmp_path, {"a.txt": "x"})
    assert main([str(src), str(out), "--project", name]) == 2
    assert not out.exists()


# standaardwaarden

def test_ocr_is_default_and_no_ocr_skips_it(tmp_path, monkeypatch):
    fitz = pytest.importorskip("pymupdf")
    src, out = make_kb(tmp_path, {})
    doc = fitz.open()
    doc.new_page()  # scan zonder tekstlaag
    doc.save(str(src / "scan.pdf"))
    calls = []

    class Fake:
        @staticmethod
        def image_to_string(*_a, **_k):
            calls.append(1)
            return "gescande tekst"

    monkeypatch.setitem(sys.modules, "pytesseract", Fake)
    assert main([str(src), str(out / "met")]) == 0
    assert calls and "gescande tekst" in (out / "met" / ("scan.pdf" + SHADOW_SUFFIX)).read_text(encoding="utf-8")
    calls.clear()
    assert main([str(src), str(out / "zonder"), "--no-ocr"]) == 0
    assert not calls


@pytest.fixture
def kb_root(tmp_path, monkeypatch):
    root = tmp_path / "KB_md"
    monkeypatch.setenv("KB_ROOT", str(root))
    return root


def test_out_defaults_to_kb_root_and_source_name(tmp_path, kb_root):
    src, _ = make_kb(tmp_path, {"a.txt": "x"})
    assert main([str(src)]) == 0
    assert shadows(kb_root / "kb") == ["a.txt" + SHADOW_SUFFIX]


def test_project_overrides_source_name(tmp_path, kb_root):
    src, _ = make_kb(tmp_path, {"a.txt": "x"})
    assert main([str(src), "--project", "fabrikam"]) == 0
    assert shadows(kb_root / "fabrikam") == ["a.txt" + SHADOW_SUFFIX]


def test_source_name_that_is_no_valid_project_needs_flag(tmp_path, kb_root):
    src = tmp_path / "kado's"
    src.mkdir()
    assert main([str(src)]) == 2
    assert main([str(src), "--project", "kados"]) == 0


def test_kb_root_from_dotenv(tmp_path, monkeypatch):
    monkeypatch.delenv("KB_ROOT", raising=False)
    monkeypatch.chdir(tmp_path)
    (tmp_path / ".env").write_text(f"KB_ROOT={tmp_path / 'uit_env'}\n", encoding="utf-8")
    src, _ = make_kb(tmp_path, {"a.txt": "x"})
    assert main([str(src)]) == 0
    assert shadows(tmp_path / "uit_env" / "kb") == ["a.txt" + SHADOW_SUFFIX]
    assert "KB_ROOT" not in os.environ  # .env lezen verandert de omgeving niet


def test_kb_root_fallback(monkeypatch, tmp_path):
    monkeypatch.delenv("KB_ROOT", raising=False)
    monkeypatch.chdir(tmp_path)
    assert kb_prep.default_root() == Path.home() / "KB_md"


def test_same_basename_from_other_folder_is_refused(tmp_path, kb_root):
    a = tmp_path / "klantA" / "docs"
    b = tmp_path / "klantB" / "docs"
    a.mkdir(parents=True)
    b.mkdir(parents=True)
    (a / "a.txt").write_text("van A", encoding="utf-8")
    (b / "b.txt").write_text("van B", encoding="utf-8")
    assert main([str(a)]) == 0
    assert main([str(b)]) == 2  # zou anders de schaduw van A opruimen
    assert shadows(kb_root / "docs") == ["a.txt" + SHADOW_SUFFIX]
    assert main([str(b), "--project", "docs-B"]) == 0


def test_manifest_records_source_root(tmp_path):
    src, out = make_kb(tmp_path, {"a.txt": "x"})
    main([str(src), str(out)])
    assert manifest(out)["source_root"] == str(src.resolve())
