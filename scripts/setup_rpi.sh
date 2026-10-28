#!/usr/bin/env bash
# SimpleLay RPi5 초기 설정 스크립트
# Raspberry Pi OS Bookworm 64-bit 기준
#
# 사용법 (RPi5에 SSH 접속 후):
#   chmod +x setup_rpi.sh && sudo ./setup_rpi.sh
#
# 재실행 시 이미 설정된 단계는 건너뛴다.

set -euo pipefail

REPO_URL="https://github.com/Seongwonp/Simplelay.git"
REPO_DIR="/home/pi/SimpleLay"
SERVICE_NAME="simplelay"
LOG_FILE="/var/log/simplelay.log"
HOSTNAME_TARGET="simplelay"

# 색상 출력 헬퍼
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${YELLOW}[→]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && err "sudo로 실행해야 합니다: sudo ./setup_rpi.sh"

# 1. hostname
info "1/8  hostname 설정"

if [[ "$(hostname)" != "$HOSTNAME_TARGET" ]]; then
    hostnamectl set-hostname "$HOSTNAME_TARGET"
    # /etc/hosts 업데이트 (127.0.1.1 항목)
    sed -i "s/127\.0\.1\.1.*/127.0.1.1\t$HOSTNAME_TARGET/" /etc/hosts
    ok "hostname → $HOSTNAME_TARGET"
else
    ok "hostname 이미 $HOSTNAME_TARGET"
fi

# 2. 시스템 의존성 (avahi 포함 — update가 반드시 install보다 먼저)
#    출력을 /dev/null로 버리지 않는다: 신선한 이미지에서 조용히 죽으면
#    어느 단계에서 죽었는지조차 알 수 없었다.
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

# 3. 레포 clone / pull
info "3/8  레포 준비 ($REPO_DIR)"

if [[ -d "$REPO_DIR/.git" ]]; then
    sudo -u pi git -C "$REPO_DIR" pull --ff-only
    ok "git pull 완료"
else
    sudo -u pi git clone "$REPO_URL" "$REPO_DIR"
    ok "git clone 완료"
fi

# 4. Python 가상환경 + 의존성 설치
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

# 5. 로그 파일 + systemd 서비스
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
# 시연장 공유 Wi-Fi 방어 — 설정 시 폰 앱 설정에도 같은 키 입력.
# 미설정이면 이 기기(localhost, 키오스크)만 API를 쓸 수 있고 폰은 401을 받는다.
#SIMPLELAY_API_KEY=change-me
# 키 없이 LAN 전체에 여는 개발용 스위치 — 시연·실기기에서는 쓰지 않는다(기동 로그 경고)
#SIMPLELAY_ALLOW_UNAUTHENTICATED=1
# 실행 응답 대기 = 기저 + 버튼당(초). 실기기에서 버튼 1개 소요 시간(이동+
# 누름+검증+재시도)의 p95를 측정해 조정한다. 기본 30 / 6.
#SIMPLELAY_UART_BASE_TIMEOUT=30
#SIMPLELAY_UART_PER_BUTTON_TIMEOUT=6
# 부재 중 자동 제안 보류 (RPi4 카메라 감지기 연결 후)
#SIMPLELAY_PRESENCE_GATING=true
#
# ── 온디바이스 D-Bus 서비스 주소 ─────────────────────────────────────────
# 기기마다/빌드마다 다르므로 저장소에 담지 않는다. 기기에서 확인해 채울 것:
#   busctl list          <- 떠 있는 서비스 이름 확인
#   command -v <CLI이름> <- 호출용 CLI 실행 파일 확인
# SIMPLELAY_LLM_MODE=dbus 를 켜면서 아래를 비워두면 기동 시 어떤 값이 없는지
# 짚으며 실패한다(조용히 꺼진 채 도는 것보다 낫다).
#SIMPLELAY_DBUS_CLI=
#SIMPLELAY_DBUS_AGENT_SERVICE=
#SIMPLELAY_DBUS_VECTORDB_SERVICE=
#SIMPLELAY_DBUS_PERIPHERAL_SERVICE=
# 기동 시 유사도 계층에 규칙 예시(별칭 포함)를 넣는다. 저장소가 재부팅 후에도
# 유지되는지 확인 전이라 기본 꺼짐 — 유지된다면 매번 켜면 중복이 쌓인다.
#SIMPLELAY_VECTORDB_SEED=1
#
# ── 가전 노드 전송 (HTTP / ESP-NOW) ──────────────────────────────────────
# 등록되는 노드 주소의 의미가 달라진다: http = URL, espnow = MAC.
# 자동 감지는 하지 않는다 — 주소 모양으로 추측하면 오타 하나가 조용히 다른
# 전송을 타서 시연장에서 원인을 못 좁힌다.
# espnow로 켤 때는 게이트웨이 ESP32가 붙은 시리얼 포트도 함께 지정할 것.
#SIMPLELAY_NODE_TRANSPORT=espnow
#SIMPLELAY_GATEWAY_PORT=/dev/ttyAMA0
#SIMPLELAY_GATEWAY_BAUD=115200
#
# ── 키오스크 화면 ────────────────────────────────────────────────────────
# Flutter 키오스크 웹 빌드가 놓인 자리. 기본값은 리포 옆 kiosk-web/ 이라
# 보통은 건드릴 일이 없다(PC에서 scripts/deploy_kiosk.ps1로 복사한다).
#SIMPLELAY_KIOSK_WEB_DIR=/home/pi/SimpleLay/kiosk-web
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
ok "현재 Act 모드 확인: curl localhost:8000/health/detail → act_mode (공개 /health는 ok·version만)"

# 6. 로그 로테이션 (24/7 운영 — 로그 무한 증식 방지)
info "6/8  logrotate 설정"

cp "$REPO_DIR/scripts/simplelay.logrotate" /etc/logrotate.d/simplelay
ok "logrotate 설정 완료 (일 단위, 7개 보관, 압축)"

# 7. 터치스크린 키오스크 자동 실행 (건너뛰려면: SIMPLELAY_KIOSK=0 sudo ...)
#    cage(Wayland 키오스크 컴포지터)가 tty1에서 Chromium 전체화면을 띄운다.
#    Bookworm 기본 이미지 기준 — X11/데스크톱 불필요, 화면 절전 없음.
#    Flutter(elinux) 키오스크로 전환 시 유닛의 ExecStart만 교체하면 된다.
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
        # Flutter 키오스크 빌드는 PC에서 복사해 넣는다 — 아직 없으면 /kiosk가
        # 안내 화면을 띄우므로, 여기서 그 사실을 먼저 알려준다.
        if [[ ! -f "$REPO_DIR/kiosk-web/index.html" ]]; then
            echo -e "${YELLOW}[!]${NC} Flutter 키오스크 빌드가 아직 없습니다"
            echo    "    PC에서: scripts/deploy_kiosk.ps1 -PiHost $HOSTNAME_TARGET.local"
            echo    "    그때까지는 http://localhost:8000/ui 로 구형 화면 사용 가능"
        fi
    else
        echo -e "${YELLOW}[!]${NC} cage/chromium 설치 실패 — 키오스크 자동 실행은 건너뜀"
        echo    "    수동 확인: apt-get install cage chromium 후 재실행"
    fi
else
    info "7/8  키오스크 설치 건너뜀 (SIMPLELAY_KIOSK=0)"
fi

# 8. 동작 확인
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
echo "  → ok·version 응답이 오면 서버에 닿음(생존 확인만 — 준비 상태는 여기 없음)"
echo "  준비 상태·Act 모드는 인증 경로: curl -H \"X-API-Key: <키>\" http://simplelay.local:8000/health/detail"
echo ""
ok "설치 완료!"
