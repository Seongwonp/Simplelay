#!/bin/sh
# RPi5 호스트의 마이크·whisper.cpp를 쓰는 로컬 음성 인식 서버를 띄운다.
set -eu

DEPLOY_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STT_DIR=/mnt/rawdata/simplelay/stt
mkdir -p "$STT_DIR"
cp "$DEPLOY_DIR/stt/stt_server.py" "$STT_DIR/stt_server.py"

docker rm -f simplelay-stt 2>/dev/null || true
docker run -d --name simplelay-stt --restart always \
  --security-opt apparmor=unconfined \
  --privileged --pid=host \
  -e SIMPLELAY_STT_MODEL="${SIMPLELAY_STT_MODEL:-/mnt/rawdata/simplelay/stt/ggml-base-q8_0.bin}" \
  -e SIMPLELAY_STT_SOURCE="${SIMPLELAY_STT_SOURCE:-}" \
  --entrypoint nsenter \
  simplelay-backend -t 1 -m -u -i -n -p -- /usr/bin/python3 "$STT_DIR/stt_server.py"
sleep 2
docker ps --filter name=simplelay-stt --format '{{.Names}} {{.Status}}'
