# SimpleLay 백엔드를 플랫폼 기기 위 컨테이너로 올린다.
#
# 왜 컨테이너인가: 플랫폼 이미지의 python3은 온디바이스 AI 서비스 전용으로 격리돼
# 우리가 못 쓴다(dev-docs 참고). 대신 도커가 되므로 파이썬을 컨테이너가 품고 온다.
# 온디바이스 D-Bus는 시스템 버스 소켓을 마운트해 dbus-fast로 직접 부른다.
#
# 빌드(개발 PC, arm64 기기용):
#   docker build --platform linux/arm64 -f deploy/backend.Dockerfile -t simplelay-backend .
# 실행은 deploy/run_backend.sh 참고.
#
# 의존성을 명시적으로 깐다(pip install -e . 대신). 이유: 우리는 리포를 PYTHONPATH로
# 얹어 실행하지(py -m pytest / uvicorn rpi.main:app) 패키지로 설치하지 않는다.
# 컨테이너도 같은 방식이라 pyproject 패키징 메타데이터에 얽히지 않는다.

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
    "dbus-fast>=2,<3"

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
CMD ["python", "-m", "uvicorn", "rpi.main:app", "--host", "0.0.0.0", "--port", "8000"]
