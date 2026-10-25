"""키오스크 음성 안내(2026-10-25) — 문장을 한국어 음성(wav)으로 만들어 돌려준다.

키오스크는 RPi5 위에서 ``espeak-ng``를 직접 부르도록 만들어졌지만, 보드 기본 이미지에는 그 프로그램이 없어 실패널에서 음성이
한 번도 나오지 않았다(10/25 확인 — 소리 출력·스피커는 정상). 그래서 음성 합성은 본체 컨테이너(espeak-ng 설치)가 하고, 키오스크는
받은 wav를 보드의 재생 도구로 튼다. 같은 인증 의존성 아래(키오스크는 보드 루프백이라 면제).
"""
from __future__ import annotations

import shutil
import subprocess

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


def chime_wav(rate: int = 22050) -> bytes:
    """짧은 '딩동' 알림음(두 음, 약 0.6초) — 제안이 뜰 때 키오스크가 음성 앞에 튼다(사용자 요청 10/25). 파일 없이 만들어 쓴다."""
    import io
    import math
    import struct
    import wave

    frames = bytearray()
    for freq, dur in ((988.0, 0.22), (784.0, 0.38)):  # B5 → G5
        n = int(rate * dur)
        for i in range(n):
            t = i / rate
            env = min(1.0, i / (rate * 0.01)) * math.exp(-4.0 * t)  # 짧은 시작 · 부드러운 감쇠
            frames += struct.pack("<h", int(0.45 * 32767 * env * math.sin(2 * math.pi * freq * t)))
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(bytes(frames))
    return buf.getvalue()


_CHIME = None


@router.get("/tts/chime")
def chime() -> Response:
    global _CHIME
    if _CHIME is None:
        _CHIME = chime_wav()
    return Response(content=_CHIME, media_type="audio/wav")


@router.post("/tts")
def synthesize_speech(body: TtsRequest) -> Response:
    text = body.text.strip()
    if not text:
        raise HTTPException(status_code=422, detail="읽을 문장이 없어요")
    if shutil.which("espeak-ng") is None:
        raise HTTPException(status_code=503, detail="음성 합성 프로그램이 없어요")
    try:
        out = subprocess.run(espeak_command(text), capture_output=True, timeout=TTS_TIMEOUT_S, check=True)
    except (subprocess.SubprocessError, OSError) as exc:
        raise HTTPException(status_code=503, detail="음성을 만들지 못했어요") from exc
    return Response(content=out.stdout, media_type="audio/wav")
