#!/bin/sh
# RPi5: 키오스크 앱 부팅 자동 실행·감시 컨테이너(deploy/kiosk_watchdog.py)를 세운다.
# 플랫폼 버스 이름·앱 ID는 기기의 /mnt/rawdata/simplelay/kiosk.env 에 둔다(저장소에 넣지 않음).
set -e
DIR=/mnt/rawdata/simplelay
[ -f "$DIR/kiosk.env" ] || { echo "$DIR/kiosk.env 가 없어요"; exit 2; }
mkdir -p "$DIR/watchdog"
cp "$(dirname "$0")/kiosk_watchdog.py" "$DIR/watchdog/"
docker rm -f simplelay-kiosk-watchdog 2>/dev/null || true
docker run -d --name simplelay-kiosk-watchdog --restart unless-stopped \
  --security-opt apparmor=unconfined \
  -v /run/dbus/system_bus_socket:/run/dbus/system_bus_socket \
  -v "$DIR/watchdog":/watchdog:ro \
  --env-file "$DIR/kiosk.env" \
  simplelay-backend python /watchdog/kiosk_watchdog.py
sleep 3
docker logs --tail 5 simplelay-kiosk-watchdog
