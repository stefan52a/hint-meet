"""Entrypoint: hint-meet live | replay <opname.wav>"""
import argparse
import sys

from dotenv import find_dotenv, load_dotenv

from .kb import DEFAULT_MODEL, KB, OnnxEmbedder, kb_dir


def main(argv: list[str] | None = None) -> int:
    load_dotenv(find_dotenv(usecwd=True))  # .env vanaf de werkmap; bestaande omgevingsvariabelen gaan voor
    ap = argparse.ArgumentParser(prog="hint-meet")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("live", help="realtime meeting volgen")
    rp = sub.add_parser("replay", help="opname afspelen voor kalibratie")
    rp.add_argument("wav")
    rp.add_argument("--out", default="logs/replay.csv")
    ev = sub.add_parser("eval-kb", help="zoeken testen met een vragenlijst (YAML)")
    ev.add_argument("questions")
    ev.add_argument("--k", type=int)
    ev.add_argument("--model", help="embeddingmodel (standaard multilingual-e5-large)")
    ap.add_argument("--config", default="config/gate.yaml")
    ap.add_argument("--project", help="KB-project, overschrijft KB_PROJECT")
    a = ap.parse_args(argv)
    if a.cmd == "eval-kb":
        return eval_kb_cmd(a)
    try:
        print(f"KB: {kb_dir(a.project)}")
    except ValueError as e:
        print(e, file=sys.stderr)
        return 2
    print(f"{a.cmd}: nog niet geïmplementeerd", file=sys.stderr)
    return 1


def eval_kb_cmd(a) -> int:
    from .evaluate import eval_kb, load_questions, report
    data = load_questions(a.questions)
    k = a.k or data.get("k", 5)
    try:
        root = kb_dir(a.project or data.get("project"))
    except ValueError as e:
        print(e, file=sys.stderr)
        return 2
    print(f"KB: {root}")
    kb = KB(root, OnnxEmbedder(a.model or DEFAULT_MODEL))
    print(f"{len(kb.chunks)} stukjes\n")
    print(report(eval_kb(kb, data["vragen"], k), k))
    return 0


if __name__ == "__main__":
    sys.exit(main())
