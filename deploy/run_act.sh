#!/bin/sh
# RPi4 실행기(rpi4.act_main) 컨테이너를 세운다. 이미지는 백엔드와 같은 simplelay-backend다.
#
# 시험 배선(2026-09-30): 두 보드 사이 UART 선 대신 같은 LAN을 쓴다. 컨테이너 안에서
# socat이 TCP 7000을 가상 시리얼(/tmp/vserial)로 바꾸고, act_main이 그 가상 시리얼을 연다.
# RPi5는 SIMPLELAY_UART_PORT=socket://<RPi4 IP>:7000 으로 붙는다.
# 실제 UART 선을 쓸 때는 LINK=uart 로 실행한다(/dev/ttyAMA0를 컨테이너에 넘긴다).
#
# 장치 넘기기(2026-10-06 평가): 컨테이너는 넘겨준 장치만 본다. env 파일($DATA_DIR/env)에서
#   - SIMPLELAY_OUTLET_PORT·SIMPLELAY_MOTION_PORT가 /dev/… 이면 그 장치를 자동으로 넘긴다(fake·비움은 넘기지 않는다).
#   - SIMPLELAY_ACT_DEVICES=/dev/snd /dev/i2c-1 처럼 공백으로 더 적는다(마이크: 종료음·위험 소리면 /dev/snd).
# 적힌 장치가 없으면 컨테이너를 세우지 않는다 — USB가 빠진 채 조용히 돌지 않게. USB 이름이 바뀌면
# /dev/serial/by-id/… 경로를 쓰는 편이 낫다(실기기 확인 전).
#
# 무선(2026-10-12): RPi5가 사라져도(Wi-Fi 끊김·백엔드 재시작) socat은 연결 하나만 받는 구조라 죽은 연결을
# 계속 붙잡고 새 연결을 받지 못했다. TCP keepalive(5 s 뒤 2 s 간격 3회 ≈ 11 s)로 죽은 상대를 알아채
# socat이 끝나게 하고, 아래 restart 정책이 다시 세운다.
# 둘 중 하나(socat·act_main)가 끝나면 컨테이너가 끝나고 restart 정책이 둘 다 다시 세운다
# — 연결이 끊긴 가상 시리얼을 act_main이 붙잡고 있는 상태를 남기지 않기 위해서다.
#
# 링크 인증(2026-10-12): TCP 7000은 같은 망 누구에게나 열려 있다. env 파일에 SIMPLELAY_LINK_KEY(RPi5 env와
# 같은 값, 16자 이상)를 두면 서명된 프레임만 받는다(docs/protocol.md "링크 인증"). 키가 들어가므로 파일은 600.
# 2026-10-14부터 키가 **필수**다 — 없으면 실행기가 시작을 거절하고 컨테이너가 재시작을 되풀이한다(docker logs에 이유).
# SIMPLELAY_LINK_AUTH=off_for_mock은 모의 구성 전용이고, 모션 serial·실물 콘센트 등 실물 경로와 함께면 거절된다.
#
# 선점(2026-10-14 보안 점검): socat은 연결 **하나만** 받는다. 키 없는 기기가 RPi5보다 먼저 7000에 붙으면 실행은 못 하지만
# (서명 없는 프레임은 버린다) 그 연결이 살아 있는 동안 RPi5가 붙지 못한다(keepalive는 살아 있는 상대를 끊지 않는다).
# 완화: env 파일에 SIMPLELAY_LINK_ALLOW_FROM=<RPi5 IPv4>를 두면 socat이 그 주소의 연결만 받는다(range=…/32).
# 비워 두면 종전과 같다. 실기기 미검증 — 도커 포트 공개(-p)에서 원래 출발 주소가 보이는지 배포 때 확인한다.
set -e
LINK=${LINK:-lan}
DATA_DIR=${DATA_DIR:-/mnt/rawdata/simplelay-act}
mkdir -p "$DATA_DIR"
ENV_FILE="$DATA_DIR/env"; [ -f "$ENV_FILE" ] || { : > "$ENV_FILE"; chmod 600 "$ENV_FILE"; }

# env 파일의 KEY=값(마지막 줄이 이긴다). 따옴표는 docker --env-file처럼 그대로 둔다 — 쓰지 않는다.
env_value() {
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1 | tr -d '\r'
}

DEVICES=""
for name in SIMPLELAY_OUTLET_PORT SIMPLELAY_MOTION_PORT; do
  value=$(env_value "$name")
  case "$value" in
    /dev/*|/*) DEVICES="$DEVICES $value" ;;
  esac
done
DEVICES="$DEVICES $(env_value SIMPLELAY_ACT_DEVICES)"

DEVICE_ARGS=""
MISSING=""
HOTPLUG=""
for dev in $DEVICES; do
  if [ -e "$dev" ]; then
    case "$dev" in
      # by-id·by-path(USB 시리얼 고정 이름)은 --device로 넘기지 않는다 — --device는 띄운 순간의 장치 번호에 고정돼
      # USB 재열거(ttyACM0→1) 뒤 실행기가 같은 경로를 다시 열 수 없었다(10/14 실물). 아래에서 /dev를 잇는다.
      */serial/by-id/*|*/serial/by-path/*) HOTPLUG=1 ;;
      *) DEVICE_ARGS="$DEVICE_ARGS --device $dev" ;;
    esac
  else
    MISSING="$MISSING $dev"
  fi
done
if [ -n "$MISSING" ]; then
  echo "장치가 없어 실행기를 세우지 않았어요:$MISSING (USB 연결·$ENV_FILE 확인)" >&2
  exit 1
fi
ALLOW_FROM=$(env_value SIMPLELAY_LINK_ALLOW_FROM)
case "$ALLOW_FROM" in
  "") ;;
  *[!0-9.]*) echo "SIMPLELAY_LINK_ALLOW_FROM은 IPv4 주소 하나여야 해요: $ALLOW_FROM" >&2; exit 1 ;;
esac
echo "넘기는 장치:${DEVICE_ARGS:- 없음}${HOTPLUG:+ (+ /dev 연결, USB 시리얼 ttyACM·ttyUSB만 허용 — 재열거 뒤 다시 열기)}"

docker rm -f simplelay-act 2>/dev/null || true

# DEVICE_ARGS는 일부러 따옴표 없이 펼친다(--device 경로 쌍). 장치 경로에 공백은 쓰지 않는다.
if [ "$LINK" = "uart" ]; then
  docker run -d --name simplelay-act --restart always \
    --security-opt apparmor=unconfined \
    --device /dev/ttyAMA0 $DEVICE_ARGS ${HOTPLUG:+-v /dev:/dev --device-cgroup-rule "c 166:* rmw" --device-cgroup-rule "c 188:* rmw"} -v "$DATA_DIR":/data --env-file "$ENV_FILE" \
    -e SIMPLELAY_UART_PORT=/dev/ttyAMA0 \
    simplelay-backend python -m rpi4.act_main
else
  docker run -d --name simplelay-act --restart always \
    --security-opt apparmor=unconfined \
    $DEVICE_ARGS ${HOTPLUG:+-v /dev:/dev --device-cgroup-rule "c 166:* rmw" --device-cgroup-rule "c 188:* rmw"} -p 7000:7000 -v "$DATA_DIR":/data --env-file "$ENV_FILE" \
    -e SIMPLELAY_UART_PORT=/tmp/vserial -e LINK_ALLOW_FROM="$ALLOW_FROM" \
    simplelay-backend bash -c '
      socat -d PTY,link=/tmp/vserial,raw,echo=0 TCP-LISTEN:7000,reuseaddr,keepalive,keepidle=5,keepintvl=2,keepcnt=3${LINK_ALLOW_FROM:+,range=$LINK_ALLOW_FROM/32} &
      for i in $(seq 50); do [ -e /tmp/vserial ] && break; sleep 0.1; done
      python -m rpi4.act_main &
      wait -n; exit 1'
fi

sleep "${SETTLE_S:-3}"
docker ps --filter name=simplelay-act --format '{{.Names}} {{.Status}}'
docker logs --tail 20 simplelay-act
