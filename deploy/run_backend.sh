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

# 기존 컨테이너 정리(재실행 안전)
docker rm -f simplelay-backend 2>/dev/null || true

docker run -d --name simplelay-backend \
  --restart unless-stopped \
  --security-opt apparmor=unconfined \
  -v /run/dbus/system_bus_socket:/run/dbus/system_bus_socket \
  -v "$DATA_DIR":/data \
  -p 8000:8000 \
  -e SIMPLELAY_DB_PATH=/data/simplelay.db \
  -e SIMPLELAY_DEMO_PACING=1 \
  simplelay-backend

echo "== 컨테이너 기동 =="
sleep 3
docker ps --filter name=simplelay-backend --format '{{.Names}} {{.Status}}'
echo "== /health =="
sleep 2
curl -s http://localhost:8000/health || echo "(아직 준비 중일 수 있음 — docker logs simplelay-backend 확인)"
