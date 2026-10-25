"""키오스크 음성 안내(2026-10-25) — 문장을 한국어 음성으로 만들어 보드 스피커로 튼다(POST /tts/play), wav로도 돌려준다(POST /tts).

키오스크는 RPi5 위에서 ``espeak-ng``를 직접 부르도록 만들어졌지만, 보드 기본 이미지에는 그 프로그램이 없고 키오스크 앱은 격리돼
재생 도구도 쓰지 못해 실패널에서 음성이 한 번도 나오지 않았다(10/25 확인 — 소리 출력·스피커는 정상). 그래서 본체 컨테이너가
목소리를 만들고(Supertonic, 없으면 espeak-ng) 보드 소리 서버로 직접 튼다. 같은 인증 의존성 아래(키오스크는 보드 루프백이라 면제).
"""
from __future__ import annotations

import os
import queue
import shutil
import subprocess
import tempfile
import threading

from fastapi import APIRouter, HTTPException, Response
from pydantic import BaseModel, Field

router = APIRouter()

#: 한 번에 만드는 문장 길이 상한 — 화면 안내 한두 문장이면 충분하다.
MAX_TTS_CHARS = 300
#: 합성 시간 상한(초) — 넘으면 음성 없이 넘어간다(음성은 보조 채널).
TTS_TIMEOUT_S = 10.0


class TtsRequest(BaseModel):
    text: str = Field(min_length=1, max_length=MAX_TTS_CHARS)


def espeak_command(text: str) -> list[str]:
    """키오스크가 예전에 부르던 것과 같은 목소리(-v ko, 약간 느리게 -s 150, 크게 -a 150), wav를 표준 출력으로."""
    return ["espeak-ng", "-v", "ko", "-s", "150", "-a", "150", "--stdout", text]


# 자연스러운 목소리(10/25 사용자 — espeak는 '외국인이 억지로 한국어 하는 느낌'). 온디바이스 Supertonic, 모델이 없으면 espeak-ng.
TTS_MODEL_DIR = os.environ.get("SIMPLELAY_TTS_MODEL_DIR", "/data/tts-models")
TTS_VOICE = os.environ.get("SIMPLELAY_TTS_VOICE", "F1")
#: 합성 단계 — 보드(RPi5)에서 한 문장 8단계 약 5초·5단계 약 3초(10/25 실측). 5에서도 귀로 차이가 작았다.
TTS_STEPS = 5
_engine_lock = threading.Lock()
_engine: object | None = None
_engine_failed = False
_cache: dict[str, bytes] = {}
_CACHE_MAX = 32


def _load_engine():
    global _engine, _engine_failed
    with _engine_lock:
        if _engine is None and not _engine_failed:
            try:
                if not os.path.isdir(TTS_MODEL_DIR):
                    raise FileNotFoundError(TTS_MODEL_DIR)
                import supertonic  # 이미지에만 있다 — 개발 PC·시험에서는 espeak-ng 경로

                tts = supertonic.TTS(model="supertonic-3", model_dir=TTS_MODEL_DIR, auto_download=False)
                _engine = (tts, tts.get_voice_style(TTS_VOICE))
            except Exception:  # noqa: BLE001 - 목소리가 없으면 espeak-ng로 읽는다(음성은 보조 채널)
                _engine_failed = True
        return _engine


#: 만든 음성을 보드에 남겨 두는 곳 — 재시작한 뒤에도 같은 문장은 바로 나온다(목소리 모델이 있을 때만).
TTS_CACHE_DIR = os.path.normpath(os.path.join(TTS_MODEL_DIR, "..", "tts-cache"))


def _disk_path(text: str) -> str:
    import hashlib

    key = hashlib.sha256(f"{TTS_VOICE}|{TTS_STEPS}|{text}".encode("utf-8")).hexdigest()[:32]
    return os.path.join(TTS_CACHE_DIR, key + ".wav")


def synthesize_wav(text: str) -> bytes | None:
    """문장 → wav. 같은 문장은 기억해 둔 것을 쓴다(안내 문장은 몇 가지가 반복된다)."""
    if text in _cache:
        return _cache[text]
    if os.path.isdir(TTS_MODEL_DIR):
        try:
            with open(_disk_path(text), "rb") as f:
                _cache[text] = f.read()
                return _cache[text]
        except OSError:
            pass
    data: bytes | None = None
    engine = _load_engine()
    if engine is not None:
        tts, style = engine
        try:
            wav, _ = tts.synthesize(text, style, total_steps=TTS_STEPS, lang="ko")
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
                path = f.name
            try:
                tts.save_audio(wav, path)
                with open(path, "rb") as f:
                    data = f.read()
            finally:
                os.unlink(path)
        except Exception:  # noqa: BLE001
            data = None
        if data is not None:
            try:
                os.makedirs(TTS_CACHE_DIR, exist_ok=True)
                tmp = _disk_path(text) + ".tmp"
                with open(tmp, "wb") as f:
                    f.write(data)
                os.replace(tmp, _disk_path(text))
            except OSError:
                pass
    if data is None and shutil.which("espeak-ng") is not None:
        try:
            out = subprocess.run(espeak_command(text), capture_output=True, timeout=TTS_TIMEOUT_S)
            data = out.stdout if out.returncode == 0 and out.stdout else None
        except (subprocess.SubprocessError, OSError):
            data = None
    if data is not None:
        if len(_cache) >= _CACHE_MAX:
            _cache.pop(next(iter(_cache)))
        _cache[text] = data
    return data


def chime_wav(rate: int = 22050) -> bytes:
    """짧은 '딩동' 알림음(두 음, 약 1.6초) — 제안이 뜰 때 키오스크가 음성 앞에 튼다(사용자 요청 10/25). 파일 없이 만들어 쓴다."""
    import io
    import math
    import struct
    import wave

    # 10/25 사용자 요청 '고급스럽게' — 삑 소리 같던 사인파 두 개 대신 유리 종 같은 두 음(A5 → E5)을 겹쳐 울리고 짧은 잔향을 둔다.
    total = int(rate * 1.6)
    dry = [0.0] * total
    partials = ((1.0, 1.0), (2.0, 0.22), (3.01, 0.06), (4.2, 0.025))  # 기음 + 약한 배음(종의 맑은 끝)
    for start_s, freq, gain in ((0.0, 880.0, 0.9), (0.26, 659.26, 1.0)):
        s0 = int(rate * start_s)
        for i in range(total - s0):
            t = i / rate
            attack = min(1.0, i / (rate * 0.006))
            v = 0.0
            for mult, amp in partials:
                v += amp * math.exp(-t * (2.2 + 1.6 * mult)) * math.sin(2 * math.pi * freq * mult * t)
            dry[s0 + i] += gain * attack * v
    wet = dry[:]
    for delay_s, fb in ((0.0297, 0.32), (0.0371, 0.28), (0.0411, 0.25)):  # 짧은 빗살 잔향 — 방 안에서 울리는 느낌
        d = int(rate * delay_s)
        buf = [0.0] * total
        for i in range(total):
            buf[i] = dry[i] + (fb * buf[i - d] if i >= d else 0.0)
        for i in range(total):
            wet[i] += 0.18 * (buf[i] - dry[i])
    fade = int(rate * 0.25)
    peak = max(abs(x) for x in wet) or 1.0
    frames = bytearray()
    for i, x in enumerate(wet):
        g = min(1.0, (total - i) / fade)
        frames += struct.pack("<h", int(0.32 * 32767 * g * x / peak))
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(bytes(frames))
    return buf.getvalue()


_CHIME = None


def _chime_bytes() -> bytes:
    global _CHIME
    if _CHIME is None:
        _CHIME = chime_wav()
    return _CHIME


@router.get("/tts/chime")
def chime() -> Response:
    return Response(content=_chime_bytes(), media_type="audio/wav")


class TtsPlayRequest(BaseModel):
    text: str | None = Field(default=None, max_length=MAX_TTS_CHARS)
    chime: bool = False


_play_queue: "queue.Queue[tuple[bool, threading.Thread | None, dict]] | None" = None
_play_lock = threading.Lock()
#: 쌓인 안내가 이보다 많으면 새 것은 버린다(소리가 한참 밀려 나오지 않게).
MAX_QUEUED = 4


def _play_wav(data: bytes) -> None:
    if not data or shutil.which("paplay") is None:
        return
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        f.write(data)
        path = f.name
    try:
        subprocess.run(["paplay", path], capture_output=True, timeout=30)
    except (subprocess.SubprocessError, OSError):
        pass
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def _worker(q: "queue.Queue[tuple[bool, threading.Thread | None, dict]]") -> None:
    while True:
        chime_first, maker, result = q.get()
        try:
            if chime_first:
                _play_wav(_chime_bytes())
            if maker is not None:
                maker.join(TTS_TIMEOUT_S + 5)
                if result.get("wav"):
                    _play_wav(result["wav"])
        except Exception:  # noqa: BLE001 - 소리는 보조 — 재생 줄은 죽지 않는다
            pass
        finally:
            q.task_done()


def _enqueue(chime_first: bool, text: str | None) -> bool:
    global _play_queue
    with _play_lock:
        if _play_queue is None:
            _play_queue = queue.Queue()
            threading.Thread(target=_worker, args=(_play_queue,), daemon=True, name="tts-play").start()
        if _play_queue.qsize() >= MAX_QUEUED:
            return False
        # 말은 받자마자 만들기 시작한다(보드에서 한 문장 약 3초) — 키오스크는 딩동과 말을 따로 보내므로, 차례가 올 때
        # 만들면 딩동이 끝난 뒤 3초를 더 기다렸다(10/25 사용자 '좀 늦게 나온다'). 재생 순서는 줄이 지킨다.
        result: dict = {}
        maker = None
        if text:
            maker = threading.Thread(target=lambda: result.update(wav=synthesize_wav(text)), daemon=True)
            maker.start()
        _play_queue.put((chime_first, maker, result))
        return True


@router.post("/tts/play", status_code=202)
def play(body: TtsPlayRequest) -> dict:
    """보드 스피커로 튼다(2026-10-25) — 본체 컨테이너가 보드 소리 서버로 직접. 격리된 키오스크 앱은 재생 도구를 쓰지 못했다.
    알림음과 말은 한 줄로 차례대로라 겹치지 않는다. 바로 돌려주고 재생은 뒤에서."""
    text = (body.text or "").strip() or None
    if not body.chime and text is None:
        raise HTTPException(status_code=422, detail="틀 소리가 없어요")
    return {"queued": _enqueue(body.chime, text)}


@router.post("/tts")
def synthesize_speech(body: TtsRequest) -> Response:
    text = body.text.strip()
    if not text:
        raise HTTPException(status_code=422, detail="읽을 문장이 없어요")
    data = synthesize_wav(text)
    if data is None:
        raise HTTPException(status_code=503, detail="음성을 만들지 못했어요")
    return Response(content=data, media_type="audio/wav")


# 보드에서는 서버가 뜰 때 목소리를 미리 불러 둔다(약 2초·메모리 약 500MB, 10/25 실측) — 첫 안내가 늦지 않게.
if os.path.isdir(TTS_MODEL_DIR):
    threading.Thread(target=_load_engine, daemon=True, name="tts-warm").start()
