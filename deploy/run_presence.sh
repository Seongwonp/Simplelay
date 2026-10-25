#!/bin/sh
# RPi5: 사람 감지(온디바이스) 스크립트를 부팅 때 자동으로 띄우는 컨테이너를 세운다(2026-10-26).
#
# 감지 스크립트는 보드의 카메라·영상 도구·온디바이스 런타임을 써서 보드(호스트) 위에서 돌아야 한다. 시스템 영역이
# 읽기 전용이라 부팅 서비스를 새로 넣을 수 없으므로, 재시작 정책 always 컨테이너가 nsenter로 호스트 쪽에서 스크립트를
# 실행한다(도커가 부팅 때 뜨면 함께 뜨고, 스크립트가 죽으면 다시 띄운다). 컨테이너를 지우면 감지도 멈춘다.
#
# 감지 스크립트 경로는 기기의 /mnt/rawdata/simplelay/presence.env 의 PRESENCE_SCRIPT= 에 둔다(저장소에 넣지 않음).
# 결과는 사람 수만 담은 파일(presence_cam.json), 사진은 저장하지 않는다. 카메라 끄기 표시 파일이 있으면 카메라를 닫는다.
set -e
DIR=/mnt/rawdata/simplelay
[ -f "$DIR/presence.env" ] || { echo "$DIR/presence.env 가 없어요(PRESENCE_SCRIPT=<감지 스크립트 경로>)"; exit 2; }
. "$DIR/presence.env"
[ -n "$PRESENCE_SCRIPT" ] && [ -f "$PRESENCE_SCRIPT" ] || { echo "PRESENCE_SCRIPT 파일이 없어요: $PRESENCE_SCRIPT"; exit 2; }

# 손으로 띄워 둔 감지(setsid)가 있으면 겹치지 않게 먼저 멈춘다.
pkill -f "$PRESENCE_SCRIPT" 2>/dev/null || true
killall presence_watch gst-launch-1.0 2>/dev/null || true

docker rm -f simplelay-presence 2>/dev/null || true
docker run -d --name simplelay-presence --restart always \
  --security-opt apparmor=unconfined \
  --privileged --pid=host \
  --entrypoint nsenter \
  simplelay-backend -t 1 -m -u -i -n -p -- sh "$PRESENCE_SCRIPT"
sleep 8
docker ps --filter name=simplelay-presence --format '{{.Names}} {{.Status}}'
ls -la "$DIR/presence_cam.json" 2>/dev/null || echo "아직 결과 파일 없음(카메라 연결·카메라 끄기 표시 확인)"
