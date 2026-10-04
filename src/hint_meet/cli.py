"""Entrypoint: hint-meet live | replay <opname.wav>"""
import argparse
from pathlib import Path
import sys

from dotenv import find_dotenv, load_dotenv

from .kb import DEFAULT_MODEL, KB, OnnxEmbedder, kb_dir


def main(argv: list[str] | None = None) -> int:
    load_dotenv(find_dotenv(usecwd=True))  # .env vanaf de werkmap; bestaande omgevingsvariabelen gaan voor
    ap = argparse.ArgumentParser(prog="hint-meet")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("live", help="realtime meeting volgen")
    rp = sub.add_parser("replay", help="transcript (.txt) door de pijplijn, met score en CSV-log")
    rp.add_argument("transcript")
    rp.add_argument("--out", default="logs/replay.csv")
    cal = sub.add_parser("calibrate", help="alleen de gate over een transcript, met drempeltabel")
    cal.add_argument("transcript")
    cal.add_argument("--gate", choices=["claude", "jev"], help="provider (standaard uit de config)")
    cal.add_argument("--out", help="CSV met de kans per beurt (standaard logs/gate-<provider>.csv)")
    ev = sub.add_parser("eval-kb", help="zoeken testen met een vragenlijst (YAML)")
    ev.add_argument("questions")
    ev.add_argument("--k", type=int)
    ev.add_argument("--model", help="embeddingmodel (standaard multilingual-e5-large)")
    ap.add_argument("--config", default="config/gate.yaml")
    ap.add_argument("--project", help="KB-project, overschrijft KB_PROJECT")
    a = ap.parse_args(argv)
    if a.cmd == "eval-kb":
        return eval_kb_cmd(a)
    if a.cmd == "replay":
        return replay_cmd(a)
    if a.cmd == "calibrate":
        return calibrate_cmd(a)
    try:
        print(f"KB: {kb_dir(a.project)}")
    except ValueError as e:
        print(e, file=sys.stderr)
        return 2
    print(f"{a.cmd}: nog niet geïmplementeerd", file=sys.stderr)
    return 1


def replay_cmd(a) -> int:
    import yaml

    from .advise import ClaudeAdvisor
    from .gate import make_gate
    from .pipeline import Pipeline
    from .replay import replay, score
    from .transcript import load

    config = yaml.safe_load(open(a.config, encoding="utf-8"))
    try:
        root = kb_dir(a.project)
    except ValueError as e:
        print(e, file=sys.stderr)
        return 2
    utterances = load(a.transcript)
    print(f"KB: {root}\nTranscript: {len(utterances)} beurten, "
          f"{sum(1 for u in utterances if u.expect)} gemarkeerde momenten\n")
    pipeline = Pipeline(KB(root), make_gate(config), ClaudeAdvisor(config), config)

    def show(u, step):
        mark = "◆" if u.expect else " "
        line = f"{mark} [{u.seconds // 60:02d}:{u.seconds % 60:02d}] p={step.gate.intervene:.2f} {u.speaker}: {u.text[:60]}"
        print(line)
        if step.advice is not None:
            tag = "  💡 " if step.shown else f"  ({step.suppressed}) "
            print(tag + step.advice.text.replace("\n", " "))
            if step.advice.sources:
                print("     bron: " + ", ".join(step.advice.sources))

    import anthropic
    try:
        steps = replay(utterances, pipeline, a.out, on_step=show)
    except anthropic.APIStatusError as e:
        msg = e.body.get("error", {}).get("message", str(e)) if isinstance(e.body, dict) else str(e)
        print(f"\nAnthropic API-fout ({e.status_code}): {msg}", file=sys.stderr)
        return 1
    except anthropic.APIConnectionError:
        print("\nGeen verbinding met de Anthropic API.", file=sys.stderr)
        return 1
    s = score(utterances, steps)
    gate_ms = sorted(st.ms["gate"] for st in steps)
    adv_ms = sorted(st.ms["advies"] for st in steps if "advies" in st.ms)
    print(f"\nGeraakt: {len(s.hits)}/{s.moments}  ·  ruis-hints: {len(s.false_pos)}  ·  "
          f"kernfeiten in hints: {s.keyword_rate:.0%}")
    if s.missed:
        print("Gemist: " + ", ".join(f"[{utterances[m].seconds // 60:02d}:{utterances[m].seconds % 60:02d}]" for m in s.missed))
    if s.false_pos:
        print("Ruis: " + ", ".join(f"[{utterances[i].seconds // 60:02d}:{utterances[i].seconds % 60:02d}]" for i in s.false_pos))
    gate_model = getattr(pipeline.gate, "last_model", None) or config["gate"].get("model")
    print(f"Gate {config['gate']['provider']} ({gate_model}) mediaan {gate_ms[len(gate_ms) // 2]:.0f} ms"
          + (f" · advies mediaan {adv_ms[len(adv_ms) // 2]:.0f} ms" if adv_ms else "")
          + f"\nLog: {a.out}")
    return 0


def calibrate_cmd(a) -> int:
    import statistics

    import yaml

    from .calibrate import run_gate, sweep, write_rows
    from .gate import make_gate
    from .transcript import load

    config = yaml.safe_load(open(a.config, encoding="utf-8"))
    if a.gate:
        config["gate"]["provider"] = a.gate
    provider = config["gate"]["provider"]
    try:
        root = kb_dir(a.project)
    except ValueError as e:
        print(e, file=sys.stderr)
        return 2
    utterances = load(a.transcript)
    gate = make_gate(config)
    rows = run_gate(utterances, KB(root), gate, config)
    out = a.out or f"logs/gate-{provider}.csv"
    write_rows(Path(out), utterances, rows)
    model = getattr(gate, "last_model", None) or config["gate"].get("model")
    print(f"Gate: {provider} ({model}) · mediaan {statistics.median(r.ms for r in rows):.0f} ms\n")
    print("drempel  geraakt  ruis")
    for t, hits, n, fp in sweep(utterances, rows, [x / 20 for x in range(4, 20)], config["gate"]["urgency_min"]):
        print(f"  {t:.2f}    {hits:>2}/{n}   {fp:>3}")
    print(f"\nLog: {out}")
    return 0


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
