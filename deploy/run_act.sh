#!/bin/sh
# RPi4 실행기(rpi4.act_main) 컨테이너를 세운다. 이미지는 백엔드와 같은 simplelay-backend다.
#
# 시험 배선(2026-09-30): 두 보드 사이 UART 선 대신 같은 LAN을 쓴다. 컨테이너 안에서
# socat이 TCP 7000을 가상 시리얼(/tmp/vserial)로 바꾸고, act_main이 그 가상 시리얼을 연다.
# RPi5는 SIMPLELAY_UART_PORT=socket://<RPi4 IP>:7000 으로 붙는다.
# 실제 UART 선을 쓸 때는 LINK=uart 로 실행한다(/dev/ttyAMA0를 컨테이너에 넘긴다).
#
# 둘 중 하나(socat·act_main)가 끝나면 컨테이너가 끝나고 restart 정책이 둘 다 다시 세운다
# — 연결이 끊긴 가상 시리얼을 act_main이 붙잡고 있는 상태를 남기지 않기 위해서다.
set -e
LINK=${LINK:-lan}
DATA_DIR=/mnt/rawdata/simplelay-act
mkdir -p "$DATA_DIR"
ENV_FILE="$DATA_DIR/env"; [ -f "$ENV_FILE" ] || : > "$ENV_FILE"

docker rm -f simplelay-act 2>/dev/null || true

if [ "$LINK" = "uart" ]; then
  docker run -d --name simplelay-act --restart unless-stopped \
    --security-opt apparmor=unconfined \
    --device /dev/ttyAMA0 -v "$DATA_DIR":/data --env-file "$ENV_FILE" \
    -e SIMPLELAY_UART_PORT=/dev/ttyAMA0 \
    simplelay-backend python -m rpi4.act_main
else
  docker run -d --name simplelay-act --restart unless-stopped \
    --security-opt apparmor=unconfined \
    -p 7000:7000 -v "$DATA_DIR":/data --env-file "$ENV_FILE" \
    -e SIMPLELAY_UART_PORT=/tmp/vserial \
    simplelay-backend bash -c '
      socat -d PTY,link=/tmp/vserial,raw,echo=0 TCP-LISTEN:7000,reuseaddr &
      for i in $(seq 50); do [ -e /tmp/vserial ] && break; sleep 0.1; done
      python -m rpi4.act_main &
      wait -n; exit 1'
fi

sleep 3
docker ps --filter name=simplelay-act --format '{{.Names}} {{.Status}}'
docker logs --tail 20 simplelay-act
