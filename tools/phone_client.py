"""Test client voor de telefoon-audio: speelt een WAV in echte tijd als 100 ms-frames naar een PhoneSource.

Tijdens een gesimuleerde onderbreking (--drop-at/--drop-for) valt de verbinding weg terwijl de opname doorloopt;
daarna verbindt de client opnieuw en stuurt alles vanaf de laatste ack opnieuw, zoals de telefoon straks doet.

  PYTHONPATH=src .venv/bin/python tools/phone_client.py opname.wav --port 8875 --meeting 00000000000000aa \\
      --drop-at 60 --drop-for 120 [--hub-port 8775]

Via de gateway van HintMeet.app, zoals de telefoon: meeting starten, audio sturen, stoppen, verslag ophalen.

  .venv/bin/python tools/phone_client.py opname.wav --gateway ws://<tailscale-ip>:8790 --token <telefoon-sleutel> \\
      --start <project> [--language nl]
"""
from __future__ import annotations

import argparse
import json
import sys
import threading
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from hint_meet.audio import read_wav  # noqa: E402
from hint_meet.phone import RATE_HZ, encode_frame  # noqa: E402
from hint_meet.server import load_or_create_token  # noqa: E402

FRAME = RATE_HZ // 10   # 100 ms


def main(argv=None) -> int:
    from websockets.sync.client import connect

    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("wav")
    ap.add_argument("--port", type=int, help="poort van de PhoneSource (--phone-port)")
    ap.add_argument("--meeting", help="16 hex-tekens (--phone-meeting)")
    ap.add_argument("--gateway", help="ws://<adres>:8790 van HintMeet.app: start en stop zoals de telefoon")
    ap.add_argument("--start", help="bij --gateway: project(en), met komma's")
    ap.add_argument("--language", default="nl", help="bij --gateway: taal van het gesprek")
    ap.add_argument("--token", help="standaard: de sleutel van HintMeet")
    ap.add_argument("--speed", type=float, default=1.0)
    ap.add_argument("--drop-at", type=float, help="seconden in de opname waarop de verbinding wegvalt")
    ap.add_argument("--drop-for", type=float, default=0.0, help="zo lang blijft de verbinding weg")
    ap.add_argument("--hub-port", type=int, help="overlay-poort: stuur aan het eind een stop-bericht")
    a = ap.parse_args(argv)

    pcm = (np.clip(read_wav(Path(a.wav)).mean(axis=1), -1, 1) * 32767).astype(np.int16)
    if a.gateway:
        if not (a.token and a.start):
            ap.error("--gateway hoort bij --token en --start")
        return via_gateway(a, pcm)
    if a.port is None or not a.meeting:
        ap.error("zonder --gateway: --port en --meeting")
    meeting = int(a.meeting, 16)
    token = a.token or load_or_create_token()
    n_frames = -(-len(pcm) // FRAME)
    drop = (a.drop_at, a.drop_at + a.drop_for) if a.drop_at is not None else None

    acked = [0]
    ws = None

    def reader(sock):
        try:
            for raw in sock:
                msg = json.loads(raw)
                if msg.get("type") == "audio_ack":
                    acked[0] = max(acked[0], int(msg["offset"]))
                elif msg.get("type") == "audio_reject":
                    print(f"afgewezen: {msg.get('reason')}", file=sys.stderr)
        except Exception:  # noqa: BLE001 - verbinding weg
            pass

    def open_ws():
        sock = connect(f"ws://127.0.0.1:{a.port}/?token={token}")
        threading.Thread(target=reader, args=(sock,), daemon=True).start()
        return sock

    t0 = time.monotonic()
    next_send = 0     # eerstvolgende frame dat nog verstuurd moet worden
    for i in range(n_frames):
        wait = t0 + i * 0.1 / a.speed - time.monotonic()
        if wait > 0:
            time.sleep(wait)
        t_audio = i * 0.1
        if drop and drop[0] <= t_audio < drop[1]:
            if ws is not None:
                print(f"[{t_audio:6.1f} s] verbinding weg", file=sys.stderr)
                ws.close()
                ws = None
            continue
        if ws is None:
            ws = open_ws()
            time.sleep(0.2)                                   # audio_ready en eerste ack afwachten
            next_send = min(next_send, acked[0] // FRAME)     # vanaf de laatste ack opnieuw
            print(f"[{t_audio:6.1f} s] verbonden, stuur opnieuw vanaf frame {next_send}", file=sys.stderr)
        while next_send <= i:
            chunk = pcm[next_send * FRAME:(next_send + 1) * FRAME]
            ws.send(encode_frame(meeting, next_send, next_send * FRAME, chunk))
            next_send += 1

    if ws is None:                                            # onderbreking liep tot het eind
        ws = open_ws()
        time.sleep(0.2)
        next_send = min(next_send, acked[0] // FRAME)
    while next_send < n_frames:
        chunk = pcm[next_send * FRAME:(next_send + 1) * FRAME]
        ws.send(encode_frame(meeting, next_send, next_send * FRAME, chunk))
        next_send += 1
    end = time.monotonic() + 30
    while acked[0] < len(pcm) and time.monotonic() < end:
        time.sleep(0.1)
    print(f"klaar: {acked[0]} van {len(pcm)} samples bevestigd", file=sys.stderr)
    ws.close()

    if a.hub_port:
        hub = connect(f"ws://127.0.0.1:{a.hub_port}/?token={token}")
        hub.send(json.dumps({"type": "stop", "final_offset": len(pcm)}))
        time.sleep(0.2)
        hub.close()
    return 0 if acked[0] >= len(pcm) else 1


def via_gateway(a, pcm) -> int:
    """Zoals de telefoon: state, start, wachten op audio_ready, audio in echte tijd, stop, verslag."""
    import uuid
    from websockets.sync.client import connect

    ws = connect(a.gateway, additional_headers={"Authorization": f"Bearer {a.token}"}, open_timeout=5)
    got = {"acked": 0, "ready": None, "state": None, "msgs": []}
    cond = threading.Condition()

    def reader():
        try:
            for raw in ws:
                msg = json.loads(raw)
                kind = msg.get("type")
                with cond:
                    if kind == "audio_ack":
                        got["acked"] = max(got["acked"], int(msg["offset"]))
                    elif kind == "audio_ready":
                        got["ready"] = msg
                    elif kind == "state":
                        got["state"] = msg
                    got["msgs"].append(msg)
                    cond.notify_all()
                if kind in ("utterance", "hint", "status", "summary", "stopped", "audio_ready", "state"):
                    short = {k: v for k, v in msg.items() if k not in ("session", "markdown")}
                    print(f"← {short}", file=sys.stderr)
        except Exception:  # noqa: BLE001 - verbinding dicht
            pass

    def wait(pred, timeout):
        with cond:
            return cond.wait_for(lambda: pred(got), timeout)

    threading.Thread(target=reader, daemon=True).start()
    ws.send(json.dumps({"type": "state"}))
    if not wait(lambda g: g["state"] is not None, 5):
        print("geen state van de gateway", file=sys.stderr)
        return 1
    if got["state"]["phase"] != "idle":   # niet in een lopende meeting (van de Mac of een andere telefoon) praten
        print(f"de Mac is bezig ({got['state']['phase']}); niets gestart", file=sys.stderr)
        return 1
    ws.send(json.dumps({"type": "start", "request_id": uuid.uuid4().hex, "projects": a.start.split(","),
                        "language": a.language, "info": "phone_client"}))
    if not wait(lambda g: g["ready"] is not None, 120):
        print("geen audio_ready: meeting niet gestart?", file=sys.stderr)
        return 1
    meeting = int(got["ready"]["meeting"], 16)
    t0 = time.monotonic()
    for i, start in enumerate(range(0, len(pcm), FRAME)):
        wait_s = t0 + i * 0.1 / a.speed - time.monotonic()
        if wait_s > 0:
            time.sleep(wait_s)
        ws.send(encode_frame(meeting, i, start, pcm[start:start + FRAME]))
    wait(lambda g: g["acked"] >= len(pcm), 30)
    print(f"{got['acked']} van {len(pcm)} samples bevestigd; stop", file=sys.stderr)
    ws.send(json.dumps({"type": "stop", "final_offset": len(pcm)}))
    done = wait(lambda g: (g["state"] or {}).get("phase") == "idle"
                and ((g["state"] or {}).get("last") or {}).get("meeting") == got["ready"]["meeting"], 300)
    ws.close()
    if not done:
        print("meeting niet netjes geëindigd (geen last in state)", file=sys.stderr)
        return 1
    last = got["state"]["last"]
    print(f"klaar: gestopt door {last['stopped_by']}\n{last.get('report_md') or '(geen verslag)'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
