# deploy — 보드 빌드·배포

> 역할: RPi5 허브 백엔드·RPi4 실행기·키오스크 감시를 **보드 위 컨테이너**로 세우는 스크립트. 이미지는 하나(`simplelay-backend`)를 두 보드가 같이 쓴다.

현행 배포 방식이다. 옛 systemd 방식(`scripts/setup_rpi.sh`)은 [scripts/README](../scripts/README.md) 참고.
결선 당일 절차·장애 대응은 [결선 운영 런북](../docs/결선-운영-런북.md), 환경 변수 목록은 [환경 변수](../docs/환경변수.md).

## 파일

| 파일 | 무엇 | 어디서 |
| --- | --- | --- |
| [`build_on_device.sh`](build_on_device.sh) | 보드 안에서 이미지 만들기. 보드의 보안 프로필 때문에 `docker build`의 실행 단계가 실패해서, 기동과 같은 옵션의 컨테이너 안에서 설치하고 커밋한다 | RPi5 |
| [`backend.Dockerfile`](backend.Dockerfile) | 같은 이미지의 기준 정의(개발 PC에서 arm64로 빌드할 때). 의존성을 바꾸면 `build_on_device.sh`도 같이 고친다 | 개발 PC |
| [`run_backend.sh`](run_backend.sh) | 허브 백엔드 컨테이너 기동(`rpi.main`). 데이터·env는 보드의 데이터 폴더(저장소 밖) | RPi5 |
| [`run_act.sh`](run_act.sh) | 실행기 컨테이너 기동(`rpi4.act_main`). 컨테이너 안 socat이 TCP 7000을 가상 시리얼로 바꾼다. env에 적힌 모션·콘센트 USB 장치를 넘긴다 | RPi4 |
| [`act-v3.env.example`](act-v3.env.example) | RPi4 env에 합칠 등록 ID 결속 예시(비밀값 없음) | RPi4 |
| [`kiosk_watchdog.py`](kiosk_watchdog.py) · [`run_kiosk_watchdog.sh`](run_kiosk_watchdog.sh) | 키오스크 앱 부팅 자동 실행·감시(꺼지면 다시 켬). 버스 이름·앱 ID는 보드 env에만 둔다 | RPi5 |
| [`run_netfix.sh`](run_netfix.sh) | 재부팅 뒤 기본 경로가 Wi-Fi(wlan0)가 아니면 wlan0 기본 경로만 앞세운다(15초마다 확인, 다른 경로는 안 지움). [런북 §5-5-1](../docs/결선-운영-런북.md) | RPi5 |
| `run_stt.sh` · `stt/stt_server.py` | 호스트 마이크와 whisper.cpp를 쓰는 키오스크 말하기 서버. 컨테이너는 `nsenter`로 호스트 서버를 실행한다 | RPi5 |

## 절차 (2026-10-15 현행)

1. **소스 묶기(개발 PC):** 배포할 커밋에서 `git archive HEAD rpi rpi4 deploy .dockerignore`로 묶어 RPi5의 빌드 폴더에 푼다.
2. **이미지 만들기(RPi5):** `sh deploy/build_on_device.sh` — `docker build`는 쓰지 않는다(위 표).
3. **허브 기동(RPi5):** `deploy/run_backend.sh`를 보드에 복사해 실행한다(보드에 상주시키지 않고 매번 복사).
4. **이미지 옮기기(RPi4):** RPi5의 이미지를 `docker save | gzip` → RPi4에서 `gunzip | docker load`.
   Windows 개발 PC를 거칠 때는 Windows OpenSSH로 파이프한다 — PowerShell 5.1 파이프는 바이너리를 깨뜨린다.
5. **실행기 기동(RPi4):** 보드의 데이터 폴더에 둔 `run_act.sh`로 세운다. RPi4 재부팅 뒤에는 도커 서비스를 먼저 시작해야 한다.
6. **되돌리기:** 바꾸기 전 이미지에 날짜 태그(예: `simplelay-backend:1014`)를 붙여 둔다. env를 고칠 때는 `env.bak-날짜-이유`로 백업한다.
7. **확인:** 허브 재시작 → `/health/detail` 준비 확인 → 실행·정지 확인. 준비 전에는 실행하지 않는다(런북 §5-2).

**같은 커밋으로 배포한다.** RPi4·RPi5(·폰·키오스크)가 다른 커밋이면 자동 실행이 늘 보류되고 정지 보고가 '보냄'에 머문다.

## 키오스크 말하기

RPi5에서 `sh deploy/run_stt.sh`를 한 번 실행하면 `simplelay-stt` 컨테이너가 재부팅 뒤에도 다시 뜬다. 서버는 호스트의 `127.0.0.1:8091`에만 바인딩한다.

- `SIMPLELAY_STT_MODEL`: 호스트 whisper.cpp 모델 경로. 기본값은 `/mnt/rawdata/simplelay/stt/ggml-base-q8_0.bin`.
- `SIMPLELAY_STT_SOURCE`: PulseAudio 입력 이름. 비우면 기본 입력을 쓴다.
- 백엔드의 `SIMPLELAY_STT_URL`: STT 서버 주소. 기본값은 `http://127.0.0.1:8091`; `off`면 말하기를 끈다.

배포 스크립트가 `deploy/stt/stt_server.py`를 `/mnt/rawdata/simplelay/stt/stt_server.py`로 복사한다. 녹음 파일은 요청마다 임시 폴더에 만들고 응답 전에 지운다.

## 키오스크 앱

키오스크 설치 파일은 **저장소 밖의 로컬 전용 플랫폼 빌드 환경**에서 만든다(빌드 환경·산출물은 커밋하지 않는다).
웹 빌드(브라우저 시뮬레이터용 `/kiosk`)는 [`scripts/deploy_kiosk.ps1`](../scripts/deploy_kiosk.ps1)이 개발 PC에서 만들어 복사한다.

## 링크·인증 주의

- 링크 키 `SIMPLELAY_LINK_KEY`는 두 보드 env에 같은 값으로 둔다. 없으면 실행기와 `SIMPLELAY_ACT_MODE=uart` 허브가 기동을 거절한다.
- TCP 7000은 같은 망에 열려 있다 — RPi4 env의 `SIMPLELAY_LINK_ALLOW_FROM`(RPi5 주소)으로 받는 주소를 좁힌다. 핫스팟처럼 주소가 바뀌는 망에서는 이 값과 RPi5의 `SIMPLELAY_UART_PORT`를 같이 고친다.
