#!/bin/sh
# rpi5 기기에서 SimpleLay 백엔드 컨테이너를 세운다.
# 이미지(simplelay-backend.tar)를 개발 PC에서 scp로 받아온 뒤 이 스크립트를 실행한다.
#
#   [개발 PC] docker save simplelay-backend | gzip > simplelay-backend.tar.gz
#             scp simplelay-backend.tar.gz root@<기기IP>:/tmp/
#   [기기]    gunzip -c /tmp/simplelay-backend.tar.gz | docker load
#             sh run_backend.sh
set -e

DATA_DIR=${DATA_DIR:-/mnt/rawdata/simplelay}   # 루트(2GB)가 좁아 rawdata(4.6GB)에 데이터를 둔다
SETTLE_S=${SETTLE_S:-3}
mkdir -p "$DATA_DIR"
# 기기별 설정·비밀(SIMPLELAY_API_KEY, SIMPLELAY_ACT_MODE, SIMPLELAY_UART_PORT, 기상청 키 등)은
# 저장소가 아니라 기기의 이 파일에 둔다(root 전용 600). 없으면 빈 파일로 시작한다.
# SIMPLELAY_LINK_KEY(2026-10-12): RPi4 링크 짝 키 — RPi4 env와 같은 값(16자 이상, 예: openssl rand -hex 32).
# SIMPLELAY_ACT_MODE=uart면 2026-10-14부터 필수다 — 없으면 백엔드가 기동을 거절한다(docker logs에 이유).
# 한쪽만 있으면 링크가 안 열리고 /health/detail actuator_ready=false다(docs/protocol.md "링크 인증").
ENV_FILE="$DATA_DIR/env"
[ -f "$ENV_FILE" ] || { : > "$ENV_FILE"; chmod 600 "$ENV_FILE"; }

# 시연 페이싱(SIMPLELAY_DEMO_PACING, 버튼마다 1.2초 쉼)은 위 env 파일을 따른다 — 없으면 꺼짐(2026-10-06 갭 S9).
# 실물·부분 실물은 끈 채로 둔다(실제 누름이 이미 느리다 — 켜면 이중으로 느려진다). 전부 모의 리허설에서만
# env 파일에 SIMPLELAY_DEMO_PACING=1 줄을 넣는다(docs/결선-운영-런북.md §3-2). 예전처럼 스크립트가 강제로 켜지 않는다.
PACING=off
if grep -Eiq '^[[:space:]]*SIMPLELAY_DEMO_PACING=(1|true|yes|on)[[:space:]]*$' "$ENV_FILE"; then
  PACING=on
fi

# ThinQ(2026-10-15): PAT·클라이언트 ID는 데이터 폴더의 thinq/에 둔다(컨테이너 /data/thinq) — 컨테이너를 다시
# 만들어도 남는다. PAT는 사용자가 직접 "$DATA_DIR/thinq/thinq_pat"에 넣는다(값은 출력하지 않는다).
# env 파일에 같은 설정을 적었으면 그 값을 쓰고 여기서 덮어쓰지 않는다. 켜기는 env 파일의 SIMPLELAY_THINQ_MODE.
THINQ_DIR="$DATA_DIR/thinq"
mkdir -p "$THINQ_DIR"
chmod 700 "$THINQ_DIR"
THINQ_ARGS=
if ! grep -Eq '^[[:space:]]*SIMPLELAY_THINQ_CLIENT_ID(_FILE)?=' "$ENV_FILE"; then
  THINQ_ARGS="-e SIMPLELAY_THINQ_CLIENT_ID_FILE=/data/thinq/thinq_client_id"
fi
THINQ_PAT=없음
if grep -Eq '^[[:space:]]*SIMPLELAY_THINQ_PAT(_FILE)?=' "$ENV_FILE"; then
  THINQ_PAT="env 파일 설정"
elif [ -f "$THINQ_DIR/thinq_pat" ]; then
  chmod 600 "$THINQ_DIR/thinq_pat"
  THINQ_ARGS="$THINQ_ARGS -e SIMPLELAY_THINQ_PAT_FILE=/data/thinq/thinq_pat"
  THINQ_PAT="파일 있음"
fi

# 잠시 쉬기 이어받기(2026-10-14 마감 2번) — 컨테이너를 지우기 **전에** 실행 중 서버에서 읽는다.
# 업데이트 전 배포본(568f995)은 잠시 쉬기를 메모리에만 두고 공개 /health의 dnd_until로만 알린다. 그 값을 새 컨테이너에
# 넘기면 새 서버가 남은 시간 동안 옛 범위(새 제안만 쉼)로 이어받는다(확인 가능한 값일 때만 — 서버가 다시 검사).
# 이후 버전은 서버 DB에 끝 시각·범위를 남겨 이어받기가 필요 없다(공개 /health에 dnd_until이 없다).
# RPi5 기기에는 curl이 없고 busybox wget만 있다(2026-10-14 확인) — curl이 없거나 실패하면 wget으로 읽는다.
http_get() {
  curl -s --max-time 3 "$1" 2>/dev/null || wget -q -T 3 -O - "$1" 2>/dev/null
}
CARRY=
OLD_HEALTH=$(http_get http://localhost:8000/health) || OLD_HEALTH=
if [ -z "$OLD_HEALTH" ]; then
  echo "== 실행 중 서버에서 잠시 쉬기를 읽지 못함 — 켜 두었다면 업데이트 뒤 잠시 쉬기 재설정 필요 =="
elif printf '%s' "$OLD_HEALTH" | grep -q '"dnd_until"'; then
  CARRY=$(printf '%s' "$OLD_HEALTH" | sed -n 's/.*"dnd_until": *"\([0-9TZ:.+-]*\)".*/\1/p')
  if [ -n "$CARRY" ]; then
    echo "== 잠시 쉬기 이어받기: $CARRY 까지, 업데이트 전 범위(새 제안만 쉼 — 자동 실행은 그대로) =="
  elif printf '%s' "$OLD_HEALTH" | grep -Eq '"dnd_until": *null'; then
    echo "== 이어받을 잠시 쉬기 없음 =="
  else
    echo "== 잠시 쉬기 값을 확인하지 못함 — 켜 두었다면 업데이트 뒤 잠시 쉬기 재설정 필요 =="
  fi
else
  echo "== 잠시 쉬기는 서버 DB에 남아 있음(이어받기 불필요) =="
fi

# 기존 컨테이너 정리(재실행 안전) — 먼저 종료 신호로 세운다(2026-10-16). `rm -f`로 바로 죽이면 서버가 정상 종료 표시를
# 남기지 못해 '허브가 갑자기 꺼짐'으로 보고 사용자가 허용한 자동 실행을 모두 끈다(배포할 때마다 자동 실행이 풀렸다).
docker stop --time 15 simplelay-backend >/dev/null 2>&1 || true
docker rm -f simplelay-backend 2>/dev/null || true

# 시간대(2026-10-16) — 컨테이너 기본은 UTC라 루틴 시각(예: 19:35)·조용한 시간(22:00~07:00)이 한국 시각보다 9시간 늦게
# 맞았다. 호스트 시간대를 넘긴다(못 읽으면 Asia/Seoul). env 파일에 TZ= 줄이 있으면 그 값을 따른다(덮지 않는다).
TZ_ARGS=
if ! grep -Eq '^[[:space:]]*TZ=' "$ENV_FILE"; then
  HOST_TZ=$(readlink -f /etc/localtime 2>/dev/null | sed -n 's|.*/zoneinfo/||p')
  case "$HOST_TZ" in
    */*) ;;
    *) HOST_TZ=Asia/Seoul ;;
  esac
  TZ_ARGS="-e TZ=$HOST_TZ"
fi

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
  ${CARRY:+-e SIMPLELAY_PAUSE_CARRYOVER_UNTIL=$CARRY} \
  $THINQ_ARGS \
  $TZ_ARGS \
  simplelay-backend

echo "== 시연 페이싱: $PACING (env 파일 $ENV_FILE 의 SIMPLELAY_DEMO_PACING) =="
echo "== ThinQ PAT: $THINQ_PAT ($THINQ_DIR/thinq_pat) =="
if [ -n "$TZ_ARGS" ]; then
  echo "== 시간대: ${TZ_ARGS#-e TZ=} =="
else
  echo "== 시간대: env 파일의 TZ =="
fi

echo "== 컨테이너 기동 =="
sleep "$SETTLE_S"
docker ps --filter name=simplelay-backend --format '{{.Names}} {{.Status}}'
echo "== /health =="
sleep "$SETTLE_S"
http_get http://localhost:8000/health || echo "(아직 준비 중일 수 있음 — docker logs simplelay-backend 확인)"
