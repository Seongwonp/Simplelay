# 개발 로그 2026-09-30 — RPi5·RPi4 LAN 연결·배포, 모의 실행 왕복 확인

**결과:** RPi5 백엔드에서 `POST /execute "즉석밥 데워줘"` → LAN → RPi4 실행기(모의 모션) → 결과가 RPi5로 돌아왔다.
`/status`: `succeeded / success / mock / physical / reported`, RPi4 로그 `sequence … finished — success (retry=0)`.
**모터·센서는 아직 없다(실행 환경은 mock).** 두 보드 통신과 배포 경로를 확인한 것이다.

## 1. 구성

| 보드 | 주소 | 컨테이너 | 설정 |
|---|---|---|---|
| RPi5 (Pi 5 Model B) | 192.168.0.178 | `simplelay-backend`, host 네트워크 | `/mnt/rawdata/simplelay/env`(600): `SIMPLELAY_API_KEY`, `SIMPLELAY_ACT_MODE=uart`, `SIMPLELAY_UART_PORT=socket://192.168.0.81:7000` |
| RPi4 (Pi 4 Model B) | 192.168.0.81 | `simplelay-act`, TCP 7000 | 컨테이너 안 socat이 TCP 7000 ↔ `/tmp/vserial`, `rpi4.act_main`이 그 가상 시리얼을 연다 |

두 보드 모두 root SSH 키 접속, 같은 이미지(`simplelay-backend`)를 쓴다. RPi5의 8/31 이미지는 `simplelay-backend:0831`로 남겼다(되돌리기용).

## 2. 이 플랫폼에서 알게 된 것

- **`docker build`가 안 된다.** AppArmor docker-default 프로필을 못 올려 RUN 단계가 exit 185. → `deploy/build_on_device.sh`(apparmor=unconfined 컨테이너에서 설치 후 `docker commit`).
- **백엔드를 브리지 네트워크로 띄우면 키오스크가 401.** 같은 기기 키오스크 요청이 172.17.0.1로 보여 루프백 면제가 안 된다. → `run_backend.sh`를 `--network host`로.
- **RPi4 루트 파일시스템이 읽기 전용이라 `systemctl enable docker`가 안 된다.** 재부팅 뒤에는 `systemctl start docker`를 먼저 해야 컨테이너가 다시 뜬다(자동 기동은 미해결).
- BusyBox라 `head -c`·`curl`이 없다. 난수는 `dd if=/dev/urandom … | od`.
- 부팅 뒤 화면에 platform만 보이는 것은 플랫폼 홈 앱 창이 숨김이어서다. 키오스크 앱은 원격으로 시작한다. 화면 가장자리 터치는 창 관리자가 스와이프로 읽어 앱을 닫는다.
- 백엔드 `/kiosk/` 웹과 RPi5의 키오스크 앱(플랫폼 앱, 8/31 빌드)은 이번에 갱신하지 않았다.

## 3. 다시 배포하는 법

```
# 개발 PC
tar --force-local --exclude=__pycache__ --exclude=tests -czf ctx.tgz rpi rpi4 deploy .dockerignore
scp ctx.tgz root@192.168.0.178:/mnt/rawdata/simplelay-build/
# RPi5
cd /mnt/rawdata/simplelay-build && tar xzf ctx.tgz && sh deploy/build_on_device.sh && sh deploy/run_backend.sh
# 이미지를 RPi4로 (개발 PC에서 중계)
ssh root@192.168.0.178 'docker save simplelay-backend:latest | gzip -1' | ssh root@192.168.0.81 'gunzip | docker load'
# RPi4
sh /mnt/rawdata/run_act.sh
```

RPi5를 다시 띄우면 RPi4의 가상 시리얼 연결이 끊겨 `simplelay-act`가 스스로 재시작한다(설계). 그 뒤 RPi5가 먼저 붙었다면 RPi5 컨테이너를 한 번 더 재시작한다.

## 4. 다음

- 폰 앱에 API 키 입력(키는 RPi5 env 파일에만 있다) → 폰으로 실행.
- 키오스크 앱 최신 빌드를 RPi5에 올리기(플랫폼 앱 빌드 환경 필요), 부팅 자동 실행.
- RPi4 도커 자동 기동 방법 확인.
- 실제 UART 선이 오면 `LINK=uart sh run_act.sh`, RPi5 env의 `SIMPLELAY_UART_PORT=/dev/ttyAMA0`(컨테이너에 장치 전달 필요).
