#!/bin/bash
# SimpleLay 터치스크린 키오스크 실행 스크립트
# RPi 5 부팅 시 자동 실행 (systemd or autostart)
#
# 설치:
#   chmod +x kiosk.sh
#   mkdir -p ~/.config/autostart
#   cp simplelay-kiosk.desktop ~/.config/autostart/
#
# 또는 /etc/rc.local 에 추가:
#   /home/pi/SimpleLay/rpi/touchscreen/kiosk.sh &

# 디스플레이 설정
export DISPLAY=:0

# 화면 절전 비활성화
xset s off
xset -dpms
xset s noblank

# 마우스 커서 숨기기 (unclutter 필요: sudo apt install unclutter)
unclutter -idle 0 &

# FastAPI 서버가 준비될 때까지 대기
until curl -sf http://localhost:8000/health > /dev/null; do
  echo "FastAPI 서버 대기 중..."
  sleep 2
done

# Chromium 키오스크 모드로 터치스크린 UI 열기
chromium-browser \
  --noerrdialogs \
  --disable-infobars \
  --kiosk \
  --no-first-run \
  --overscroll-history-navigation=0 \
  --disable-pinch \
  --touch-events=enabled \
  --disable-restore-session-state \
  "http://localhost:8000/ui"
