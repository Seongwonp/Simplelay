#!/bin/sh
# RPi5: 재부팅 뒤 인터넷 길(기본 경로)을 Wi-Fi로 되돌리는 감시 컨테이너를 세운다(2026-10-26).
#
# 증상: 부팅 뒤 connman이 도커 가상 연결(veth*)·유선(eth0) 링크 로컬을 유선 서비스로 보고 'default dev ...' 경로를
# 넣는다. 그 경로가 Wi-Fi(wlan0) 기본 경로를 이기면 허브가 인터넷을 못 쓴다. 다른 경로를 한꺼번에 지우면 connman이
# Wi-Fi를 끊어 버렸다(같은 날 확인) — 그래서 지우지 않고 wlan0 기본 경로만 가장 높은 우선순위(metric 0)로 다시 넣는다.
# 시스템 영역이 읽기 전용이라 connman 설정을 고칠 수 없어, 재시작 정책 always 컨테이너가 nsenter로 호스트에서 확인한다.
#
# 하는 일(15초마다): wlan0에 게이트웨이가 있는데 바깥 주소로 가는 길이 wlan0이 아니면
#   ip route replace default via <wlan0 게이트웨이> dev wlan0 metric 0
# 한 줄만 실행하고 로그 한 줄을 남긴다. wlan0 연결 자체·다른 경로는 건드리지 않는다. 지우면 감시도 멈춘다.
set -e
docker rm -f simplelay-netfix 2>/dev/null || true
docker run -d --name simplelay-netfix --restart always \
  --security-opt apparmor=unconfined \
  --privileged --pid=host \
  --entrypoint nsenter \
  simplelay-backend -t 1 -m -n -- sh -c '
PROBE=8.8.8.8
STUCK=
while :; do
  GW=$(ip route show dev wlan0 2>/dev/null | sed -n "s/^default via \([0-9.]*\).*/\1/p" | head -n 1)
  if [ -n "$GW" ] && ! ip route get $PROBE 2>/dev/null | grep -q " dev wlan0 "; then
    if ip route replace default via "$GW" dev wlan0 metric 0 && ip route get $PROBE | grep -q " dev wlan0 "; then
      echo "$(date "+%F %T") netfix: wlan0 기본 경로를 metric 0으로 다시 넣음"
      STUCK=
    elif [ -z "$STUCK" ]; then
      echo "$(date "+%F %T") netfix: wlan0 기본 경로를 앞세우지 못함 — 런북의 손 명령 확인"
      STUCK=1
    fi
  fi
  sleep 15
done'
sleep 3
docker ps --filter name=simplelay-netfix --format '{{.Names}} {{.Status}}'
docker logs --tail 3 simplelay-netfix
