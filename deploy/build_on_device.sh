#!/bin/sh
# 플랫폼 기기(RPi5·RPi4) 안에서 백엔드 이미지를 만든다.
#
# 왜 docker build가 아닌가: 이 플랫폼은 AppArmor docker-default 프로필을 올리지 못해
# `docker build`의 RUN 단계가 exit 185로 실패한다(2026-09-30 RPi5 확인). 기동과 같은
# `--security-opt apparmor=unconfined` 컨테이너 안에서 설치하고 커밋한다.
# 내용은 deploy/backend.Dockerfile과 같게 유지한다(의존성을 바꾸면 둘 다 고친다).
#
#   [개발 PC] tar -czf ctx.tgz rpi rpi4 deploy   (tests·__pycache__ 제외)
#             scp ctx.tgz root@<기기>:/mnt/rawdata/simplelay-build/
#   [기기]    cd /mnt/rawdata/simplelay-build && tar xzf ctx.tgz && sh deploy/build_on_device.sh
set -e
SRC=$(cd "$(dirname "$0")/.." && pwd)
TAG=${1:-simplelay-backend:latest}

docker rm -f simplelay-build 2>/dev/null || true
docker run --name simplelay-build --security-opt apparmor=unconfined \
  -v "$SRC":/src:ro python:3.12-slim sh -c '
    set -e
    pip install --no-cache-dir \
      "fastapi>=0.111,<1" "uvicorn[standard]>=0.29,<1" "pydantic>=2,<3" \
      "numpy>=1.26,<3" "httpx>=0.27,<1" "dbus-fast>=2,<3" \
      "pyserial>=3.5,<4" "pyserial-asyncio>=0.6,<1" "qrcode[pil]>=8,<9" \
      "sounddevice>=0.4,<1" "thinqconnect==1.0.14" "lgpio>=0.2,<1"
    # lgpio: RPi5 온습도 센서(DHT22) 읽기 — rpi/services/dht22.py(2026-10-20). 장치는 run_backend.sh가 넘긴다.
    # thinqconnect: ThinQ 공식 SDK(2026-10-15) — backend.Dockerfile·pyproject [thinq]와 같은 고정 버전. 없으면
    # SIMPLELAY_THINQ_MODE=real·fake_cloud에서 서버가 기동을 거절한다(꺼짐·mock은 불러오지 않음).
    # libportaudio2: 마이크(sounddevice) — backend.Dockerfile과 같다(2026-10-06 평가)
    apt-get update && apt-get install -y --no-install-recommends socat libportaudio2 espeak-ng pulseaudio-utils
    rm -rf /var/lib/apt/lists/*
    mkdir -p /app /data
    cp -r /src/rpi /src/rpi4 /app/
    find /app -name __pycache__ -prune -exec rm -rf {} + ; find /app -type d -name tests -prune -exec rm -rf {} +
  '
docker commit \
  --change 'WORKDIR /app' \
  --change 'ENV PYTHONPATH=/app' \
  --change 'ENV SIMPLELAY_DB_PATH=/data/simplelay.db' \
  --change 'EXPOSE 8000' \
  --change 'CMD ["python", "-m", "uvicorn", "rpi.main:app", "--host", "0.0.0.0", "--port", "8000", "--timeout-graceful-shutdown", "5"]' \
  simplelay-build "$TAG"
docker rm simplelay-build
echo "== built $TAG"
