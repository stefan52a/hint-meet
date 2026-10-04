"""Entrypoint: hint-meet live | replay <opname.wav>"""
import argparse
import sys


def main() -> int:
    ap = argparse.ArgumentParser(prog="hint-meet")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("live", help="realtime meeting volgen")
    rp = sub.add_parser("replay", help="opname afspelen voor kalibratie")
    rp.add_argument("wav")
    rp.add_argument("--out", default="logs/replay.csv")
    ap.add_argument("--config", default="config/gate.yaml")
    a = ap.parse_args()
    print(f"{a.cmd}: nog niet geïmplementeerd", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
