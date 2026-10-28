# SimpleLay 백엔드를 플랫폼 기기 위 컨테이너로 올린다.
#
# 플랫폼의 python3은 온디바이스 AI 서비스 전용으로 격리돼 있다(dev-docs 참고).
# 백엔드는 별도의 Python 런타임을 포함한 컨테이너에서 실행한다.
# 온디바이스 D-Bus는 시스템 버스 소켓을 마운트해 dbus-fast로 직접 부른다.
#
# 빌드(개발 PC, arm64 기기용):
#   docker build --platform linux/arm64 -f deploy/backend.Dockerfile -t simplelay-backend .
# 실행은 deploy/run_backend.sh 참고.
#
# 리포를 패키지로 설치하지 않고 PYTHONPATH에 올려 실행하므로 의존성을 명시적으로 설치한다.
# 개발 환경(py -m pytest / uvicorn rpi.main:app)과 컨테이너가 같은 실행 방식을 쓴다.

FROM python:3.12-slim

WORKDIR /app

# 런타임 의존성 (pyproject의 dependencies + dbus extra와 같은 범위).
# 순수/미리빌드 휠이라 빌드 툴 불필요.
RUN pip install --no-cache-dir \
    "fastapi>=0.111,<1" \
    "uvicorn[standard]>=0.29,<1" \
    "pydantic>=2,<3" \
    "numpy>=1.26,<3" \
    "httpx>=0.27,<1" \
    "dbus-fast>=2,<3" \
    "pyserial>=3.5,<4" \
    "pyserial-asyncio>=0.6,<1" \
    "qrcode[pil]>=8,<9" \
    "sounddevice>=0.4,<1" \
    "adafruit-circuitpython-ads1x15>=2,<3" \
    "adafruit-blinka>=8,<9" \
    "thinqconnect==1.0.14" \
    "supertonic==1.3.1"
# supertonic: 키오스크 음성 안내의 자연스러운 한국어 목소리(온디바이스, 코드 MIT·모델 OpenRAIL-M, 2026-10-25).
# 모델 파일(약 385MB)은 이미지에 넣지 않고 데이터 폴더 /data/tts-models에 둔다. 없으면 espeak-ng로 대신 읽는다.
# thinqconnect: ThinQ 공식 SDK(pyproject [thinq]와 같은 고정 버전, 2026-10-15). 없으면 SIMPLELAY_THINQ_MODE=real·
# fake_cloud에서 서버가 기동을 거절한다. 꺼짐·mock 모드에서는 불러오지 않는다.

# socat: 하드웨어 선 대신 LAN으로 두 보드를 이을 때 RPi4 쪽에서 TCP를 가상 시리얼로
# 바꾼다(시험용, deploy/run_act.sh). 백엔드만 돌릴 때는 쓰지 않는다.
# libportaudio2: sounddevice가 여는 PortAudio 공유 라이브러리 — RPi4 마이크(종료음·위험 소리, 2026-10-06 평가).
# 컨테이너는 /dev/snd를 넘겨받아야 마이크를 본다(deploy/run_act.sh의 SIMPLELAY_ACT_DEVICES).
# espeak-ng: 키오스크 음성 안내 합성(POST /tts, 2026-10-25) — 보드 기본 이미지에 없어 실패널에서 음성이 나오지 않았다.
# pulseaudio-utils: 본체가 보드 소리 서버로 직접 튼다(POST /tts/play) — 격리된 키오스크 앱은 재생 도구를 쓰지 못한다.
RUN apt-get update && apt-get install -y --no-install-recommends socat libportaudio2 espeak-ng pulseaudio-utils \
    && rm -rf /var/lib/apt/lists/*

# 코드만 얹는다(리포 전체 아님 — .dockerignore가 나머지를 막는다).
COPY rpi ./rpi
COPY rpi4 ./rpi4

# rpi.main:app을 import하려면 /app이 경로에 있어야 한다.
ENV PYTHONPATH=/app
# SQLite·설정 자리. 기기에서 /mnt/rawdata를 여기 마운트(루트는 좁다).
ENV SIMPLELAY_DB_PATH=/data/simplelay.db
VOLUME ["/data"]

EXPOSE 8000

# 0.0.0.0로 열어야 키오스크(같은 기기 localhost)와 폰이 붙는다.
CMD ["python", "-m", "uvicorn", "rpi.main:app", "--host", "0.0.0.0", "--port", "8000", "--timeout-graceful-shutdown", "5"]
