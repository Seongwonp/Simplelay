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
# 1. hostname
# ─────────────────────────────────────────────────────────────────────────────
info "1/8  hostname 설정"

if [[ "$(hostname)" != "$HOSTNAME_TARGET" ]]; then
    hostnamectl set-hostname "$HOSTNAME_TARGET"
    # /etc/hosts 업데이트 (127.0.1.1 항목)
    sed -i "s/127\.0\.1\.1.*/127.0.1.1\t$HOSTNAME_TARGET/" /etc/hosts
    ok "hostname → $HOSTNAME_TARGET"
else
    ok "hostname 이미 $HOSTNAME_TARGET"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. 시스템 의존성 (avahi 포함 — update가 반드시 install보다 먼저)
#    출력을 /dev/null로 버리지 않는다: 신선한 이미지에서 조용히 죽으면
#    어느 단계에서 죽었는지조차 알 수 없었다.
# ─────────────────────────────────────────────────────────────────────────────
info "2/8  시스템 패키지 설치"

apt-get update -qq
apt-get install -y --no-install-recommends -qq \
    git \
    python3 python3-pip python3-venv \
    python3-gpiozero \
    libgpiod2 \
    avahi-daemon libnss-mdns \
    logrotate \
    espeak-ng

systemctl enable --now avahi-daemon
ok "시스템 패키지 설치 완료 (avahi-daemon 활성화 포함)"

# ─────────────────────────────────────────────────────────────────────────────
# 3. 레포 clone / pull
# ─────────────────────────────────────────────────────────────────────────────
info "3/8  레포 준비 ($REPO_DIR)"

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
info "4/8  Python 가상환경 + 의존성"

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
info "5/8  systemd 서비스 설치"

touch "$LOG_FILE"
chown pi:pi "$LOG_FILE"
ok "로그 파일 생성 ($LOG_FILE)"

# SQLite와 키오스크 설정이 함께 쓰는 데이터 디렉터리 (둘 다 pi가 써야 한다)
mkdir -p "$REPO_DIR/data"
chown pi:pi "$REPO_DIR/data"
ok "데이터 디렉터리 준비 ($REPO_DIR/data)"

# 기기별 확정 설정 파일 — 최초 1회 주석 템플릿 생성(기존 파일은 보존)
if [[ ! -f /etc/simplelay/environment ]]; then
    mkdir -p /etc/simplelay
    cat > /etc/simplelay/environment <<'ENVEOF'
# SimpleLay 기기별 설정 — 수정 후: sudo systemctl restart simplelay
# RPi4 실연결 시 반드시 주석 해제 (기본 local = mock 폐루프, 실물 안 움직임!)
#SIMPLELAY_ACT_MODE=uart
#SIMPLELAY_UART_PORT=/dev/ttyAMA0
# 시연장 공유 Wi-Fi 방어 — 설정 시 폰 앱 설정에도 같은 키 입력
#SIMPLELAY_API_KEY=change-me
# 실행 응답 대기 = 기저 + 버튼당(초). 실기기에서 버튼 1개 소요 시간(이동+
# 누름+검증+재시도)의 p95를 측정해 조정한다. 기본 30 / 6.
#SIMPLELAY_UART_BASE_TIMEOUT=30
#SIMPLELAY_UART_PER_BUTTON_TIMEOUT=6
# 부재 중 자동 제안 보류 (RPi4 카메라 감지기 연결 후)
#SIMPLELAY_PRESENCE_GATING=true
ENVEOF
    ok "/etc/simplelay/environment 템플릿 생성 (ACT 모드·API 키는 여기서 확정)"
else
    ok "/etc/simplelay/environment 기존 파일 유지"
fi

cp "$REPO_DIR/scripts/simplelay.service" /etc/systemd/system/simplelay.service
systemctl daemon-reload
systemctl enable simplelay
systemctl restart simplelay
ok "simplelay.service 활성화 + 시작 (Restart=always)"
ok "현재 Act 모드 확인: curl localhost:8000/health → act_mode"

# ─────────────────────────────────────────────────────────────────────────────
# 6. 로그 로테이션 (24/7 운영 — 로그 무한 증식 방지)
# ─────────────────────────────────────────────────────────────────────────────
info "6/8  logrotate 설정"

cp "$REPO_DIR/scripts/simplelay.logrotate" /etc/logrotate.d/simplelay
ok "logrotate 설정 완료 (일 단위, 7개 보관, 압축)"

# ─────────────────────────────────────────────────────────────────────────────
# 7. 터치스크린 키오스크 자동 실행 (건너뛰려면: SIMPLELAY_KIOSK=0 sudo ...)
#    cage(Wayland 키오스크 컴포지터)가 tty1에서 Chromium 전체화면을 띄운다.
#    Bookworm 기본 이미지 기준 — X11/데스크톱 불필요, 화면 절전 없음.
#    Flutter(elinux) 키오스크로 전환 시 유닛의 ExecStart만 교체하면 된다.
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${SIMPLELAY_KIOSK:-1}" == "1" ]]; then
    info "7/8  키오스크 자동 실행 설치"

    if apt-get install -y --no-install-recommends -qq cage chromium; then
        cp "$REPO_DIR/scripts/simplelay-kiosk.service" \
            /etc/systemd/system/simplelay-kiosk.service
        systemctl daemon-reload
        # getty가 tty1을 잡고 있으면 cage가 세션을 못 연다
        systemctl disable getty@tty1.service || true
        systemctl enable simplelay-kiosk
        systemctl restart simplelay-kiosk || true
        # 부팅 기본 타깃이 graphical이어야 WantedBy=graphical.target이 발동
        systemctl set-default graphical.target >/dev/null || true
        ok "simplelay-kiosk.service 활성화 (재부팅 후에도 자동 실행)"
    else
        echo -e "${YELLOW}[!]${NC} cage/chromium 설치 실패 — 키오스크 자동 실행은 건너뜀"
        echo    "    수동 확인: apt-get install cage chromium 후 재실행"
    fi
else
    info "7/8  키오스크 설치 건너뜀 (SIMPLELAY_KIOSK=0)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 8. 동작 확인
# ─────────────────────────────────────────────────────────────────────────────
info "8/8  동작 확인 (10초 대기)"
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
