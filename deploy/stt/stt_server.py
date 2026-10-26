#!/usr/bin/env python3
"""호스트 마이크와 whisper.cpp를 잇는 작은 로컬 STT 서버."""

import json
import math
import os
import re
import subprocess
import tempfile
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


HOST = "127.0.0.1"
PORT = 8091
MODEL = os.environ.get(
    "SIMPLELAY_STT_MODEL", "/mnt/rawdata/simplelay/stt/ggml-base-q8_0.bin"
)
SOURCE = os.environ.get("SIMPLELAY_STT_SOURCE", "").strip()
_LISTEN_LOCK = threading.Lock()
_BRACKETED = re.compile(r"\[[^\]]*\]|\([^)]*\)")
_TIMESTAMP = re.compile(r"^\s*\[[^\]]+\]\s*")


def _record(path, seconds):
    command = [
        "parecord", "--rate=16000", "--channels=1", "--format=s16le",
        "--file-format=wav", path,
    ]
    if SOURCE:
        command.insert(1, f"--device={SOURCE}")
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        process.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=1)
    if process.returncode not in (0, -15):
        detail = process.stderr.read().decode("utf-8", "replace").strip()
        raise RuntimeError(detail or "녹음 장치를 열지 못했어요.")


def _has_speech(path):
    """무음 환각을 막는 보수적인 RMS 문턱. 20 ms 구간의 연속 음성을 찾는다."""
    with wave.open(path, "rb") as audio:
        if audio.getnchannels() != 1 or audio.getsampwidth() != 2:
            return False
        rate = audio.getframerate()
        samples = audio.readframes(audio.getnframes())
    if not samples:
        return False
    values = memoryview(samples).cast("h")
    window = max(1, rate // 50)
    active = 0
    threshold = int(os.environ.get("SIMPLELAY_STT_RMS_THRESHOLD", "500"))
    for start in range(0, len(values), window):
        chunk = values[start:start + window]
        if not chunk:
            continue
        rms = math.sqrt(sum(int(value) ** 2 for value in chunk) / len(chunk))
        active = active + 1 if rms >= threshold else 0
        if active >= 5:  # 100 ms 이상 이어진 소리만 말로 본다.
            return True
    return False


def _transcribe(path):
    result = subprocess.run(
        ["whisper-cli", "-m", MODEL, "-l", "ko", "-t", "4", "-nt", "-f", path],
        capture_output=True, text=True, timeout=20, check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "음성을 알아듣지 못했어요.")
    lines = []
    for line in result.stdout.splitlines():
        line = _TIMESTAMP.sub("", line).strip()
        if line and not line.startswith(("whisper_", "main:")):
            lines.append(line)
    return " ".join(_BRACKETED.sub("", " ".join(lines)).split())


def listen(seconds):
    with tempfile.TemporaryDirectory(prefix="simplelay-stt-") as directory:
        path = os.path.join(directory, "in.wav")
        started = time.monotonic()
        _record(path, seconds)
        record_ms = round((time.monotonic() - started) * 1000)
        if not _has_speech(path):
            return {"text": "", "reason": "no_speech"}
        started = time.monotonic()
        text = _transcribe(path)
        stt_ms = round((time.monotonic() - started) * 1000)
        if not text:
            return {"text": "", "reason": "no_speech"}
        return {"text": text, "reason": "ok", "ms": {"record": record_ms, "stt": stt_ms}}


class Handler(BaseHTTPRequestHandler):
    def _json(self, status, body):
        payload = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        if self.path != "/listen":
            self._json(404, {"detail": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length) or b"{}")
            seconds = body.get("seconds")
            if isinstance(seconds, bool) or not isinstance(seconds, int) or not 1 <= seconds <= 8:
                raise ValueError
        except (ValueError, json.JSONDecodeError):
            self._json(400, {"detail": "seconds는 1~8 사이 정수여야 해요."})
            return
        if not _LISTEN_LOCK.acquire(blocking=False):
            self._json(409, {"detail": "이미 듣고 있어요."})
            return
        try:
            self._json(200, listen(seconds))
        except (OSError, subprocess.SubprocessError, RuntimeError) as exc:
            self._json(503, {"detail": str(exc) or "음성 인식을 시작하지 못했어요."})
        finally:
            _LISTEN_LOCK.release()

    def log_message(self, fmt, *args):
        print("stt:", fmt % args, flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
