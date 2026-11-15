"""Buddy's local Kokoro TTS worker.

Reads one JSON request per line on stdin: {"id": 1, "text": "...", "voice": "af_heart", "speed": 1.0}
Writes one JSON reply per line on stdout:  {"id": 1, "path": "/tmp/....wav"} or {"id": 1, "error": "..."}
Exits on its own after IDLE_SECONDS without requests so the model doesn't sit in memory.
"""

import json
import os
import sys
import tempfile
import threading

import soundfile as sf
from kokoro_onnx import Kokoro

IDLE_SECONDS = 600


def reply(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def main():
    model_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
    kokoro = Kokoro(os.path.join(model_dir, "kokoro-v1.0.onnx"), os.path.join(model_dir, "voices-v1.0.bin"))
    kokoro.create("Ready.", voice="af_heart", speed=1.0, lang="en-us")  # warm up
    reply({"ready": True})

    out_dir = tempfile.mkdtemp(prefix="buddy-tts-")
    idle = None

    def reset_idle():
        nonlocal idle
        if idle:
            idle.cancel()
        idle = threading.Timer(IDLE_SECONDS, lambda: os._exit(0))
        idle.daemon = True
        idle.start()

    reset_idle()
    for line in sys.stdin:
        reset_idle()
        try:
            req = json.loads(line)
            samples, rate = kokoro.create(
                req["text"], voice=req.get("voice", "af_heart"), speed=float(req.get("speed", 1.0)), lang="en-us"
            )
            path = os.path.join(out_dir, f"{req['id']}.wav")
            sf.write(path, samples, rate)
            reply({"id": req["id"], "path": path})
        except Exception as e:  # keep serving; Buddy falls back to Apple's voice for this sentence
            reply({"id": req.get("id") if isinstance(req, dict) else None, "error": str(e)})


if __name__ == "__main__":
    main()
