# Flutter 키오스크를 웹으로 빌드해 라즈베리파이로 복사한다.
#
# 라즈베리파이에는 Flutter 툴체인이 없어서 기기에서 빌드할 수 없다. 그렇다고 36MB짜리
# 빌드 산출물을 git에 넣으면 빌드할 때마다 쌓이므로, PC에서 만들어 복사하는 쪽을 택했다.
#
# 백엔드가 이걸 /kiosk에서 서빙하고(rpi/main.py의 mount_kiosk), cage+Chromium이
# 그 주소를 연다. **같은 오리진이라 CORS 문제가 없다** -- 백엔드에 CORS 미들웨어가
# 없어서 다른 포트로 띄우면 /status·/events 호출이 전부 막힌다.
#
# 사용법:
#   .\scripts\deploy_kiosk.ps1                      # simplelay.local 로
#   .\scripts\deploy_kiosk.ps1 -PiHost 192.168.0.42 # 주소 직접 지정
#   .\scripts\deploy_kiosk.ps1 -SkipBuild           # 이미 빌드했으면 복사만

param(
    [string]$PiHost   = "simplelay.local",
    [string]$PiUser   = "pi",
    [string]$RemoteDir = "/home/pi/SimpleLay/kiosk-web",
    [string]$FlutterBin = "C:\flutter\flutter\bin\flutter.bat",
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$kioskDir = Join-Path $repo "rpi5-touchscreen-app"
$buildDir = Join-Path $kioskDir "build\web"

if (-not $SkipBuild) {
    Write-Host "[1/3] Flutter 웹 빌드..." -ForegroundColor Yellow
    Push-Location $kioskDir
    try {
        # 백엔드는 산출물을 /kiosk/ 아래에만 마운트한다(rpi/main.py). base href를
        # 빼면 index.html이 루트(/)에서 main.dart.js·자산을 찾아 첫 화면이 404로
        # 깨진다 — 수동으로 고친 산출물이 아니라 이 스크립트가 재현 가능해야 한다.
        & $FlutterBin build web --release --base-href /kiosk/
        if ($LASTEXITCODE -ne 0) { throw "flutter build web 실패" }
    } finally {
        Pop-Location
    }
} else {
    Write-Host "[1/3] 빌드 건너뜀 (-SkipBuild)" -ForegroundColor DarkGray
}

$indexHtml = Join-Path $buildDir "index.html"
if (-not (Test-Path $indexHtml)) {
    throw "빌드 산출물이 없습니다: $buildDir"
}
# -SkipBuild로 예전 산출물을 복사하는 경우도 막는다 — base href가 /kiosk/가
# 아니면 기기에서 흰 화면이 된다.
if (-not (Select-String -Path $indexHtml -Pattern '<base href="/kiosk/">' -SimpleMatch -Quiet)) {
    throw "index.html의 base href가 /kiosk/ 가 아닙니다 — -SkipBuild 없이 다시 빌드하세요"
}

$target = "${PiUser}@${PiHost}"

Write-Host "[2/3] $target 에 디렉터리 준비..." -ForegroundColor Yellow
# 남은 옛 파일이 새 빌드와 섞이지 않게 비우고 다시 만든다
ssh $target "rm -rf '$RemoteDir' && mkdir -p '$RemoteDir'"
if ($LASTEXITCODE -ne 0) { throw "ssh 실패 — 주소와 SSH 키를 확인하세요" }

Write-Host "[3/3] 복사 중 (약 36MB)..." -ForegroundColor Yellow
# build/web 의 *내용물*을 옮긴다 (web/ 한 겹이 더 생기지 않게)
scp -r "$buildDir\*" "${target}:$RemoteDir/"
if ($LASTEXITCODE -ne 0) { throw "scp 실패" }

Write-Host ""
Write-Host "완료. 기기에서 확인:" -ForegroundColor Green
Write-Host "  sudo systemctl restart simplelay simplelay-kiosk"
Write-Host "  curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8000/kiosk/"
Write-Host ""
Write-Host "화면이 느리면 구형 HTML 키오스크로 되돌릴 수 있습니다:" -ForegroundColor DarkGray
Write-Host "  sudo systemctl edit simplelay-kiosk   # ExecStart 의 /kiosk 를 /ui 로"
