#!/usr/bin/env bash
# SimpleLay RPi5 초기 설정 스크립트
# Raspberry Pi OS Bookworm 64-bit 기준
#
# 사용법 (RPi5에 SSH 접속 후):
#   chmod +x setup_rpi.sh && sudo ./setup_rpi.sh
#
# 재실행 안전: 이미 설정된 단계는 건너뜀

set -euo pipefail

REPO_URL="https://github.com/Seongwonp/Simplelay.git"
REPO_DIR="/home/pi/SimpleLay"
SERVICE_NAME="simplelay"
LOG_FILE="/var/log/simplelay.log"
HOSTNAME_TARGET="simplelay"

# ── 색상 출력 헬퍼 ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${YELLOW}[→]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && err "sudo로 실행해야 합니다: sudo ./setup_rpi.sh"

# ─────────────────────────────────────────────────────────────────────────────
# 1. hostname + avahi-daemon (simplelay.local mDNS)
# ─────────────────────────────────────────────────────────────────────────────
info "1/6  hostname + avahi-daemon 설정"

if [[ "$(hostname)" != "$HOSTNAME_TARGET" ]]; then
    hostnamectl set-hostname "$HOSTNAME_TARGET"
    # /etc/hosts 업데이트 (127.0.1.1 항목)
    sed -i "s/127\.0\.1\.1.*/127.0.1.1\t$HOSTNAME_TARGET/" /etc/hosts
    ok "hostname → $HOSTNAME_TARGET"
else
    ok "hostname 이미 $HOSTNAME_TARGET"
fi

apt-get install -y --no-install-recommends avahi-daemon libnss-mdns >/dev/null 2>&1
systemctl enable --now avahi-daemon >/dev/null 2>&1
ok "avahi-daemon 활성화"

# ─────────────────────────────────────────────────────────────────────────────
# 2. 시스템 의존성
# ─────────────────────────────────────────────────────────────────────────────
info "2/6  시스템 패키지 설치"

apt-get update -qq
apt-get install -y --no-install-recommends \
    git \
    python3 python3-pip python3-venv \
    python3-gpiozero \
    libgpiod2 \
    >/dev/null 2>&1

ok "시스템 패키지 설치 완료"

# ─────────────────────────────────────────────────────────────────────────────
# 3. 레포 clone / pull
# ─────────────────────────────────────────────────────────────────────────────
info "3/6  레포 준비 ($REPO_DIR)"

if [[ -d "$REPO_DIR/.git" ]]; then
    sudo -u pi git -C "$REPO_DIR" pull --ff-only
    ok "git pull 완료"
else
    sudo -u pi git clone "$REPO_URL" "$REPO_DIR"
    ok "git clone 완료"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Python 가상환경 + 의존성 설치
# ─────────────────────────────────────────────────────────────────────────────
info "4/6  Python 가상환경 + 의존성"

VENV="$REPO_DIR/.venv"

if [[ ! -d "$VENV" ]]; then
    sudo -u pi python3 -m venv "$VENV" --system-site-packages
    ok "가상환경 생성"
fi

# pip 최신화
sudo -u pi "$VENV/bin/pip" install --upgrade pip --quiet

# 프로젝트 기본 의존성 (editable 설치)
sudo -u pi "$VENV/bin/pip" install -e "$REPO_DIR" --quiet
ok "기본 의존성 설치"

# RPi5 GPIO 전용 패키지
# adafruit-circuitpython-dht는 BLINKA_LGPIO=1 환경에서 lgpio 백엔드 사용
sudo -u pi "$VENV/bin/pip" install \
    "adafruit-blinka>=8" \
    "adafruit-circuitpython-dht>=3.7" \
    "lgpio>=0.2" \
    --quiet
ok "GPIO 패키지 설치 (adafruit-dht, lgpio)"

# ─────────────────────────────────────────────────────────────────────────────
# 5. 로그 파일 + systemd 서비스
# ─────────────────────────────────────────────────────────────────────────────
info "5/6  systemd 서비스 설치"

touch "$LOG_FILE"
chown pi:pi "$LOG_FILE"
ok "로그 파일 생성 ($LOG_FILE)"

cp "$REPO_DIR/scripts/simplelay.service" /etc/systemd/system/simplelay.service
systemctl daemon-reload
systemctl enable simplelay
systemctl restart simplelay
ok "simplelay.service 활성화 + 시작"

# ─────────────────────────────────────────────────────────────────────────────
# 6. 동작 확인
# ─────────────────────────────────────────────────────────────────────────────
info "6/6  동작 확인 (10초 대기)"
sleep 10

echo ""
echo "── 서비스 상태 ──────────────────────────────────────────────────────────"
systemctl status simplelay --no-pager -l | head -20

echo ""
echo "── /health 응답 ─────────────────────────────────────────────────────────"
if curl -sf http://localhost:8000/health | python3 -m json.tool; then
    ok "서버 응답 정상"
else
    err "서버 응답 없음 — 로그 확인: sudo tail -50 $LOG_FILE"
fi

echo ""
echo "── mDNS 확인 (같은 WiFi 기기에서 실행하세요) ──────────────────────────"
echo "  curl http://simplelay.local:8000/health"
echo "  → 응답 오면 앱/키오스크 자동 연결 가능"
echo ""
ok "설치 완료!"
