#!/bin/sh
# Standalone handoff tool: use the existing image's Python, with no hub.
set -eu
TOOL_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
IMAGE=${TOUCHBRIDGE_IMAGE:-simplelay-backend}
PORT=${TOUCHBRIDGE_PORT:-}
if [ -z "$PORT" ]; then
  echo 'TOUCHBRIDGE_PORT=/dev/serial/by-id/... sh touchbridge-console.sh' >&2
  ls -l /dev/serial/by-id/ 2>/dev/null || true
  exit 2
fi
if [ "$(docker inspect -f '{{.State.Running}}' simplelay-act 2>/dev/null || true)" = true ]; then
  echo 'simplelay-act가 USB를 사용 중이에요. 먼저 docker stop simplelay-act' >&2
  exit 2
fi
DEVICE=$(readlink -f "$PORT")
if [ ! -c "$DEVICE" ]; then
  echo 'USB 시리얼 장치를 찾지 못했어요.' >&2
  exit 2
fi
TTY=
if [ -t 0 ] && [ -t 1 ]; then TTY=-it; fi
# The tool is copied beside this launcher for handoff. In a repo checkout,
# point TOUCHBRIDGE_TOOL at the repo's rpi/tools/touchbridge_console.py.
TOOL=${TOUCHBRIDGE_TOOL:-$TOOL_DIR/touchbridge_console.py}
LOG_DIR=${TOUCHBRIDGE_LOG_DIR:-$TOOL_DIR/logs}
mkdir -p "$LOG_DIR"
docker run --rm $TTY --network none --device "$DEVICE":/dev/touchbridge \
  --security-opt apparmor=unconfined \
  -v "$TOOL":/handoff/console.py:ro -v "$LOG_DIR":/logs \
  --entrypoint python "$IMAGE" /handoff/console.py --port /dev/touchbridge \
  --log /logs/console.log "$@"
