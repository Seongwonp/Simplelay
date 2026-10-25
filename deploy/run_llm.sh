#!/bin/sh
# RPi5: 기기 안 언어 모델 서버(온디바이스 LLM)를 부팅 때 자동으로 띄우는 컨테이너를 세운다(2026-10-26).
#
# 서버 실행 파일은 보드의 플랫폼 이미지에 들어 있고 호스트에서 돌아야 한다. 시스템 영역이 읽기 전용이라
# run_presence.sh와 같은 방식 — 재시작 정책 always 컨테이너가 nsenter로 호스트에서 실행한다. 컨테이너를 지우면 서버도 멈춘다.
# 루프백(127.0.0.1)에만 열고, 백엔드가 SIMPLELAY_LLM_URL로 부른다(말 알아듣기 — 정해진 동작 목록 중 고르기만, 실행은 늘 사람 확인).
#
# 실행 파일·설정 경로는 기기의 /mnt/rawdata/simplelay/llm.env 에 둔다(저장소에 넣지 않음):
#   LLM_SERVICE_BIN=<서버 실행 파일>   LLM_CONFIG=<설정 JSON>   LLM_PORT=8080
# 모델 파일(.gguf)과 대화 형식(.jinja)은 설정 JSON이 가리키는 데이터 폴더에 둔다.
set -e
DIR=/mnt/rawdata/simplelay
[ -f "$DIR/llm.env" ] || { echo "$DIR/llm.env 가 없어요(LLM_SERVICE_BIN=…, LLM_CONFIG=…)"; exit 2; }
. "$DIR/llm.env"
LLM_PORT=${LLM_PORT:-8080}
[ -x "$LLM_SERVICE_BIN" ] || { echo "LLM_SERVICE_BIN 실행 파일이 없어요: $LLM_SERVICE_BIN"; exit 2; }
[ -f "$LLM_CONFIG" ] || { echo "LLM_CONFIG 파일이 없어요: $LLM_CONFIG"; exit 2; }

# 손으로 띄워 둔 서버가 있으면 포트가 겹치지 않게 먼저 멈춘다.
killall "$(basename "$LLM_SERVICE_BIN")" 2>/dev/null || true

docker rm -f simplelay-llm 2>/dev/null || true
# 작업 폴더를 /tmp로 — 실행 파일이 현재 폴더에 진단 파일을 쓰려 해 읽기 전용 영역 오류가 난다.
docker run -d --name simplelay-llm --restart always \
  --security-opt apparmor=unconfined \
  --privileged --pid=host \
  --entrypoint nsenter \
  simplelay-backend -t 1 -m -u -i -n -p -w/tmp -- \
  "$LLM_SERVICE_BIN" --config "$LLM_CONFIG" --host 127.0.0.1 --port "$LLM_PORT" --log-level warn
sleep 15
docker ps --filter name=simplelay-llm --format '{{.Names}} {{.Status}}'
docker logs --tail 3 simplelay-llm 2>&1 | grep -v profraw || true
