"""키오스크 음성 안내 합성(POST /tts, 2026-10-25) — 보드에 espeak-ng가 없어 실패널 음성이 나오지 않던 것."""
from __future__ import annotations

import subprocess

from fastapi import FastAPI
from fastapi.testclient import TestClient

from rpi.api import tts_router as mod


def _client() -> TestClient:
    app = FastAPI()
    app.include_router(mod.router)
    return TestClient(app)


def test_returns_wav_from_espeak_with_the_kiosk_voice(monkeypatch):
    calls = []
    monkeypatch.setattr(mod.shutil, "which", lambda name: "/usr/bin/espeak-ng")

    def fake_run(cmd, **kw):
        calls.append(cmd)
        return subprocess.CompletedProcess(cmd, 0, stdout=b"RIFFxxxxWAVE", stderr=b"")

    monkeypatch.setattr(mod.subprocess, "run", fake_run)
    res = _client().post("/tts", json={"text": "전자레인지를 눌러요"})
    assert res.status_code == 200
    assert res.headers["content-type"] == "audio/wav"
    assert res.content.startswith(b"RIFF")
    assert calls == [["espeak-ng", "-v", "ko", "-s", "150", "-a", "150", "--stdout", "전자레인지를 눌러요"]]


def test_missing_engine_or_failure_is_503_not_a_crash(monkeypatch):
    monkeypatch.setattr(mod.shutil, "which", lambda name: None)
    assert _client().post("/tts", json={"text": "안녕"}).status_code == 503
    monkeypatch.setattr(mod.shutil, "which", lambda name: "/usr/bin/espeak-ng")

    def boom(cmd, **kw):
        raise subprocess.TimeoutExpired(cmd, 10)

    monkeypatch.setattr(mod.subprocess, "run", boom)
    assert _client().post("/tts", json={"text": "안녕"}).status_code == 503


def test_text_length_is_bounded():
    assert _client().post("/tts", json={"text": "가" * (mod.MAX_TTS_CHARS + 1)}).status_code == 422


def test_chime_is_a_short_wav():
    import io
    import wave

    res = _client().get("/tts/chime")
    assert res.status_code == 200 and res.headers["content-type"] == "audio/wav"
    with wave.open(io.BytesIO(res.content)) as w:
        seconds = w.getnframes() / w.getframerate()
    assert 0.3 < seconds < 1.5


def test_play_queues_chime_then_speech_in_order(monkeypatch):
    played = []
    monkeypatch.setattr(mod, "_play_wav", lambda data: played.append(data[:4]))
    monkeypatch.setattr(mod.shutil, "which", lambda name: "/usr/bin/" + name)
    monkeypatch.setattr(mod.subprocess, "run",
                        lambda cmd, **kw: subprocess.CompletedProcess(cmd, 0, stdout=b"SPEE", stderr=b""))
    c = _client()
    assert c.post("/tts/play", json={"chime": True, "text": "즉석밥 데우기, 지금 할까요?"}).status_code == 202
    mod._play_queue.join()
    assert played == [b"RIFF", b"SPEE"]  # 알림음(wav) 뒤에 말
    assert c.post("/tts/play", json={}).status_code == 422
