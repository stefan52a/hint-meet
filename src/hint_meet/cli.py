"""Entrypoint: hint-meet live | replay <opname.wav>"""
import argparse
import sys

from dotenv import find_dotenv, load_dotenv

from .kb import kb_dir


def main(argv: list[str] | None = None) -> int:
    load_dotenv(find_dotenv(usecwd=True))  # .env vanaf de werkmap; bestaande omgevingsvariabelen gaan voor
    ap = argparse.ArgumentParser(prog="hint-meet")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("live", help="realtime meeting volgen")
    rp = sub.add_parser("replay", help="opname afspelen voor kalibratie")
    rp.add_argument("wav")
    rp.add_argument("--out", default="logs/replay.csv")
    ap.add_argument("--config", default="config/gate.yaml")
    ap.add_argument("--project", help="KB-project, overschrijft KB_PROJECT")
    a = ap.parse_args(argv)
    try:
        print(f"KB: {kb_dir(a.project)}")
    except ValueError as e:
        print(e, file=sys.stderr)
        return 2
    print(f"{a.cmd}: nog niet geïmplementeerd", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
