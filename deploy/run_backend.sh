#!/bin/sh
# rpi5 기기에서 SimpleLay 백엔드 컨테이너를 세운다.
# 이미지(simplelay-backend.tar)를 개발 PC에서 scp로 받아온 뒤 이 스크립트를 실행한다.
#
#   [개발 PC] docker save simplelay-backend | gzip > simplelay-backend.tar.gz
#             scp simplelay-backend.tar.gz root@<기기IP>:/tmp/
#   [기기]    gunzip -c /tmp/simplelay-backend.tar.gz | docker load
#             sh run_backend.sh
set -e

DATA_DIR=/mnt/rawdata/simplelay   # 루트(2GB)가 좁아 rawdata(4.6GB)에 데이터를 둔다
mkdir -p "$DATA_DIR"
# 기기별 설정·비밀(SIMPLELAY_API_KEY, SIMPLELAY_ACT_MODE, SIMPLELAY_UART_PORT, 기상청 키 등)은
# 저장소가 아니라 기기의 이 파일에 둔다(root 전용 600). 없으면 빈 파일로 시작한다.
# SIMPLELAY_LINK_KEY(2026-10-12): RPi4 링크 짝 키 — RPi4 env와 같은 값(16자 이상, 예: openssl rand -hex 32).
# SIMPLELAY_ACT_MODE=uart면 2026-10-14부터 필수다 — 없으면 백엔드가 기동을 거절한다(docker logs에 이유).
# 한쪽만 있으면 링크가 안 열리고 /health actuator_ready=false다(docs/protocol.md "링크 인증").
ENV_FILE="$DATA_DIR/env"
[ -f "$ENV_FILE" ] || { : > "$ENV_FILE"; chmod 600 "$ENV_FILE"; }

# 시연 페이싱(SIMPLELAY_DEMO_PACING, 버튼마다 1.2초 쉼)은 위 env 파일을 따른다 — 없으면 꺼짐(2026-10-06 갭 S9).
# 실물·부분 실물은 끈 채로 둔다(실제 누름이 이미 느리다 — 켜면 이중으로 느려진다). 전부 모의 리허설에서만
# env 파일에 SIMPLELAY_DEMO_PACING=1 줄을 넣는다(docs/결선-운영-런북.md §3-2). 예전처럼 스크립트가 강제로 켜지 않는다.
PACING=off
if grep -Eiq '^[[:space:]]*SIMPLELAY_DEMO_PACING=(1|true|yes|on)[[:space:]]*$' "$ENV_FILE"; then
  PACING=on
fi

# 기존 컨테이너 정리(재실행 안전)
docker rm -f simplelay-backend 2>/dev/null || true

# --network host: 같은 기기의 키오스크 앱이 localhost로 부르면 백엔드에도 루프백(127.0.0.1)으로
# 보인다. 브리지 네트워크(-p 8000:8000)면 172.17.0.1로 보여 API 키 루프백 면제가 안 되고
# 키오스크 요청이 전부 401이 된다(2026-09-30 확인).
docker run -d --name simplelay-backend \
  --restart unless-stopped \
  --security-opt apparmor=unconfined \
  -v /run/dbus/system_bus_socket:/run/dbus/system_bus_socket \
  -v "$DATA_DIR":/data \
  --network host \
  --env-file "$ENV_FILE" \
  -e SIMPLELAY_DB_PATH=/data/simplelay.db \
  simplelay-backend

echo "== 시연 페이싱: $PACING (env 파일 $ENV_FILE 의 SIMPLELAY_DEMO_PACING) =="

echo "== 컨테이너 기동 =="
sleep 3
docker ps --filter name=simplelay-backend --format '{{.Names}} {{.Status}}'
echo "== /health =="
sleep 2
curl -s http://localhost:8000/health || echo "(아직 준비 중일 수 있음 — docker logs simplelay-backend 확인)"
