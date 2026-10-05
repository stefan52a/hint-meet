"""Entrypoint: hint-meet live | replay <opname.wav>"""
import argparse
import time
from pathlib import Path
import sys

from dotenv import find_dotenv, load_dotenv

from .kb import DEFAULT_MODEL, KB, OnnxEmbedder, kb_dir


def main(argv: list[str] | None = None) -> int:
    load_dotenv(find_dotenv(usecwd=True))  # .env vanaf de werkmap; bestaande omgevingsvariabelen gaan voor
    ap = argparse.ArgumentParser(prog="hint-meet")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("kb", help="toon welke KB-map gebruikt wordt")
    lv = sub.add_parser("live", help="realtime meeting volgen (microfoon, systeemaudio, of een WAV in echte tijd)")
    lv.add_argument("--mic", help="invoerapparaat voor jouw stem (standaard: systeemstandaard)")
    lv.add_argument("--system", help="apparaat met de systeemaudio van de meeting, bv. 'BlackHole 2ch'")
    lv.add_argument("--me", default="Stefan", help="naam bij de microfoon")
    lv.add_argument("--other", default="Gesprekspartner", help="naam bij de systeemaudio")
    lv.add_argument("--wav", "--audio", dest="wav",
                    help="speel een opname (wav, mp3, m4a, …) in echte tijd af in plaats van apparaten")
    lv.add_argument("--channels", default="Stefan,Gesprekspartner", help="bij --wav: spreker per kanaal")
    lv.add_argument("--speed", type=float, default=1.0, help="bij --wav: afspeelsnelheid")
    lv.add_argument("--devices", action="store_true", help="toon de audioapparaten en stop")
    lv.add_argument("--ui", action="store_true", help="start de server voor de overlay (HintMeet.app)")
    lv.add_argument("--port", type=int, default=8765, help="poort voor de overlay")
    lv.add_argument("--no-summary", action="store_true", help="geen verslag met actiepunten na afloop")
    rp = sub.add_parser("replay", help="transcript (.txt) of opname (.wav) door de pijplijn, met score en CSV-log")
    rp.add_argument("transcript", help=".txt-transcript of .wav-opname")
    rp.add_argument("--script", help="bij een .wav: het transcript met #!-markeringen (standaard <wav>.txt)")
    rp.add_argument("--channels", default="Stefan,Gesprekspartner",
                    help="bij een .wav: spreker per kanaal, komma-gescheiden")
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
    if a.cmd == "live":
        return live_cmd(a)
    if a.cmd == "kb":
        try:
            print(f"KB: {kb_dir(a.project)}")
        except ValueError as e:
            print(e, file=sys.stderr)
            return 2
        return 0
    print(f"{a.cmd}: onbekend commando", file=sys.stderr)
    return 2


AUDIO_EXTS = {".wav", ".mp3", ".m4a", ".aac", ".flac", ".ogg", ".opus", ".mp4"}


def audio_replay_cmd(a, config, root) -> int:
    import json
    import statistics

    from .advise import ClaudeAdvisor
    from .audio import Transcriber, kb_terms, segments_from_wav
    from .gate import make_gate
    from .pipeline import Pipeline
    from .replay import audio_replay, latency_ms, score, wer
    from .transcript import load

    wav = Path(a.transcript)
    script_path = Path(a.script) if a.script else wav.with_suffix(".txt")
    script = load(script_path) if script_path.exists() else []
    tl_path = wav.with_suffix(".tijdlijn.json")
    timeline = json.loads(tl_path.read_text(encoding="utf-8")) if tl_path.exists() else []
    kb = KB(root)
    t = time.perf_counter()
    transcriber = Transcriber(kb_terms(kb.chunks))
    print(f"KB: {root}\nWhisper geladen in {time.perf_counter() - t:.1f} s; woordenlijst: {transcriber.prompt}\n")
    try:
        segments = segments_from_wav(wav, a.channels.split(","))
    except ValueError as e:
        print(e, file=sys.stderr)
        return 2
    pipeline = Pipeline(kb, make_gate(config), ClaudeAdvisor(config), config)

    def show(u, step, timing):
        mark = "◆" if u.expect else " "
        gate_ms, first_ms = latency_ms(step, timing)
        print(f"{mark} [{u.seconds // 60:02d}:{u.seconds % 60:02d}] p={step.gate.intervene:.2f} "
              f"({gate_ms / 1000:.1f} s) {u.speaker}: {u.text[:70]}")
        if step.advice is not None:
            tag = f"  💡 na {first_ms / 1000:.1f} s: " if step.shown and first_ms else f"  ({step.suppressed or 'leeg'}) "
            print(tag + step.advice.text.replace("\n", " "))

    import anthropic
    try:
        utterances, steps, timings = audio_replay(segments, transcriber, pipeline, script, timeline, a.out, show)
    except anthropic.APIStatusError as e:
        print(f"\nAnthropic API-fout ({e.status_code})", file=sys.stderr)
        return 1
    errors = total = 0
    for u, tm in zip(utterances, timings):
        if tm.script_index is not None:
            e, n = wer(script[tm.script_index].text, u.text)
            errors, total = errors + e, total + n
    s = score(utterances, steps)
    asr = statistics.median(tm.asr_ms for tm in timings)
    detect = statistics.median(tm.detect_ms for tm in timings)
    gate_lat = [latency_ms(st, tm)[0] for st, tm in zip(steps, timings)]
    first = sorted(f for f in (latency_ms(st, tm)[1] for st, tm in zip(steps, timings) if st.shown) if f)
    print(f"\nGeraakt: {len(s.hits)}/{s.moments}  ·  ruis-hints: {len(s.false_pos)}  ·  "
          f"WER Whisper: {errors / total:.1%}" if total else "")
    print(f"Mediaan per uitspraak: einde herkend {detect:.0f} ms · Whisper {asr:.0f} ms · "
          f"tot gatebeslissing {statistics.median(gate_lat):.0f} ms")
    if first:
        print(f"Tot eerste woorden van de hint: mediaan {first[len(first) // 2]:.0f} ms, max {first[-1]:.0f} ms")
    print(f"Log: {a.out}")
    return 0


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
    if Path(a.transcript).suffix.lower() in AUDIO_EXTS:
        return audio_replay_cmd(a, config, root)
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


def live_cmd(a) -> int:
    import shutil
    import statistics

    import yaml

    if a.devices:
        import sounddevice as sd
        print(sd.query_devices())
        return 0

    from .advise import ClaudeAdvisor
    from .audio import Transcriber, kb_terms
    from .gate import make_gate
    from .live import DeviceSource, LiveSession, WavSource
    from .pipeline import Pipeline

    config = yaml.safe_load(open(a.config, encoding="utf-8"))
    try:
        root = kb_dir(a.project)
    except ValueError as e:
        print(e, file=sys.stderr)
        return 2
    kb = KB(root)
    transcriber = Transcriber(kb_terms(kb.chunks))
    pipeline = Pipeline(kb, make_gate(config), ClaudeAdvisor(config), config)
    if a.wav:
        try:
            wav = WavSource(Path(a.wav), a.channels.split(","), a.speed)
        except ValueError as e:
            print(e, file=sys.stderr)
            return 2
        sources, until = [wav], (lambda: wav.finished)
    else:
        sources = [DeviceSource(a.mic, a.me)]
        if a.system:
            sources.append(DeviceSource(a.system, a.other))
        until = None
    cols = shutil.get_terminal_size((100, 20)).columns - 1
    started = time.time()
    hub = feedback = None
    sources_by_ref = {}
    if a.ui:
        from .server import FeedbackLog, Hub, source_paths
        sources_by_ref = source_paths(root)
        feedback = FeedbackLog(Path("logs") / "feedback.jsonl")

        def on_message(msg):
            if msg.get("type") == "feedback" and msg.get("session") in (None, hub.session):
                feedback.record(msg.get("id"), msg.get("rating"))
            elif msg.get("type") == "stop":
                session.stop()

        hub = Hub(port=a.port, on_message=on_message)
        hub.start()
        hub.send(type="hello", project=root.name, version=1)
        print(f"Overlay-server op ws://127.0.0.1:{a.port}")
    print(f"KB: {root}\nLuistert naar: " + (a.wav or ", ".join(f"{s.label} ({s.device or 'standaard'})" for s in sources))
          + "\nStoppen met Ctrl-C.\n")

    shown_hints: list[str] = []

    def on_text(partial):
        sys.stdout.write("\r\033[K  💡 " + partial.replace("\n", " ")[:cols - 5])
        sys.stdout.flush()
        if hub:
            hub.send(type="hint", id=len(session.utterances) - 1, state="streaming", text=partial)

    def on_event(ev):
        st, u = ev.step, ev.utterance
        uid = len(session.utterances) - 1
        if hub:
            hub.send(type="utterance", id=uid, time=f"{u.seconds // 60:02d}:{u.seconds % 60:02d}",
                     speaker=u.speaker, text=u.text)
            if st is not None and st.advice is not None:
                if st.shown:
                    srcs = [{"ref": r, "path": sources_by_ref.get(r) or str(root / r)} for r in st.advice.sources]
                    # eerst de context vastleggen: een snelle 👍 moet er al bij kunnen
                    feedback.remember(uid, utterance=u.text, hint=st.advice.text, sources=st.advice.sources,
                                      gate=round(st.gate.intervene, 3), moment=st.gate.moment)
                    hub.send(type="hint", id=uid, state="final", text=st.advice.text, sources=srcs)
                elif st.advice.text:
                    hub.send(type="hint", id=uid, state="retracted", text=st.advice.text,
                             reason=st.suppressed or "geen bron")
        if st is not None and st.shown:
            shown_hints.append(st.advice.text)
        if st is None:
            print(f"[{u.seconds // 60:02d}:{u.seconds % 60:02d}] {'(achterstand) ' if ev.stale else ''}{u.speaker}: {u.text}")
            return
        lat = ev.wait_ms + ev.asr_ms + st.ms.get("zoeken", 0) + st.ms.get("gate", 0)
        if st.advice is not None:
            sys.stdout.write("\r\033[K")
            if st.shown:
                first = lat + st.ms.get("advies_eerste", 0)
                print(f"  💡 ({first / 1000:.1f} s) {st.advice.text}\n     bron: {', '.join(st.advice.sources)}")
            elif st.advice.text:
                print(f"  ✗ ingetrokken ({st.suppressed or 'geen bron'})")
        print(f"[{u.seconds // 60:02d}:{u.seconds % 60:02d}] p={st.gate.intervene:.2f} {u.speaker}: {u.text}")

    session = LiveSession(sources, transcriber, pipeline, on_event=on_event, on_text=on_text)
    out = Path("logs") / f"live-{time.strftime('%Y%m%d-%H%M%S')}.txt"
    try:
        if session.run(until=until):
            print("\nGestopt.")
    finally:
        session.save_transcript(out)  # ook bij een fout: wat er gezegd is, blijft bewaard
    if session.overflows:
        print(f"Let op: {session.overflows} audioblokken gevallen (verwerking te traag of apparaat overbelast).")
    stale = sum(1 for e in session.events if e.stale)
    if stale:
        print(f"Let op: {stale} uitspraken zonder advies wegens achterstand van meer dan "
              f"{LiveSession.STALE_MS / 1000:.0f} s.")
    if session.events:
        waits = [e.wait_ms for e in session.events]
        firsts = [e.wait_ms + e.asr_ms + e.step.ms.get("zoeken", 0) + e.step.ms.get("gate", 0)
                  + e.step.ms["advies_eerste"] for e in session.events
                  if e.step and e.step.shown and "advies_eerste" in e.step.ms]
        print(f"\n{len(session.events)} uitspraken · wachtrij mediaan {statistics.median(waits):.0f} ms, max {max(waits):.0f} ms"
              + (f" · na einde-detectie tot eerste woorden: mediaan {statistics.median(firsts):.0f} ms, max {max(firsts):.0f} ms" if firsts else ""))
    print(f"Transcript: {out}")
    if not a.no_summary and len(session.utterances) >= 3:
        from .summary import summarize, write_note
        try:
            md = summarize(session.utterances, config)
            # een testrun (--wav) hoort niet als echte meeting in de KB
            note = write_note(Path("logs") if a.wav else root, session.utterances, shown_hints, md, started)
            print(f"\n{md}\n\nVerslag: {note}")
            if hub:
                hub.send(type="summary", markdown=md, path=str(note))
        except Exception as e:  # noqa: BLE001 - het verslag mag het transcript niet kosten
            print(f"Verslag mislukt: {e}", file=sys.stderr)
    if hub:
        hub.send(type="stopped")
        time.sleep(0.3)
        hub.stop()
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
