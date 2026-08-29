# firmware-node — 가전별 Act 노드의 ESP32 (RPi5 ↔ RPi4 무선 창구)

아키텍처: [../docs/architecture.md](../docs/architecture.md)의 "확정 아키텍처(다중 노드)" ·
프로토콜: [../docs/protocol.md](../docs/protocol.md)의 "UART 프로토콜 (RPi5 ↔ RPi4)" (이 노드가
그 프로토콜을 RPi4 쪽 그대로 이어받아 무선으로 중계한다)

- 가전마다 이 ESP32 + RPi4가 한 세트로 붙는다. 이 둘 사이(`ACT_UART_*`, `Serial2`)는
  유선 UART — RPi4가 이미 구현해둔 `execute`/`abort` → `result`/`error`/`alert`/
  `alert_cleared` 프로토콜(`rpi4/services/act_executor.py`)을 그대로 이어받는다.
- 이 노드와 중앙 허브(RPi5) 사이가 무선 구간. 전송이 두 가지고 `config.h`의
  `ESPNOW_ENABLED`로 고른다(자동 폴백 없음 — 어느 쪽으로 도는지 모호하면 시연장에서
  원인을 못 좁힌다):
  - **개발용 HTTP** (`0`, 기본): `rpi/services/esp_node_controller.py`의
    `EspNodeController`가 클라이언트, 이 펌웨어가 `POST /execute` 서버
  - **본선 데모용 ESP-NOW** (`1`): 공유기를 아예 거치지 않아 시연장 Wi-Fi 혼잡과 무관
  - 실행 로직(`ExecuteHandler`/`AlertsHandler`, `transport.h`)은 양쪽이 똑같이 쓴다 —
    `main.cpp`의 실행 코드는 전송에 묶여 있지 않다

### ⚠️ ESP-NOW는 게이트웨이 ESP32가 있어야 성립한다

ESP-NOW는 ESP32 라디오끼리만 통한다. **RPi5는 ESP-NOW를 직접 쓸 수 없다.**
실제 경로는 이렇게 된다:

```
RPi5 --UART--> ESP32 게이트웨이 --ESP-NOW--> 이 노드 --UART--> RPi4
```

즉 RPi5 쪽에도 ESP32가 한 대 필요하다. 전용 보드를 두지 않고 **폰 BLE 폴백 브릿지
ESP32가 그 역할을 겸한다**(팀 결정). 게이트웨이 쪽은 `firmware/`에, RPi5 쪽 컨트롤러는
`rpi/services/espnow_node_controller.py`에 있다.

### HTTP에서 그대로 옮겨오지 못한 것 두 가지

"전송만 갈아끼우면 된다"가 여기서는 정확히 성립하지 않았다:

1. **한 프레임 250바이트 상한** — 상한(버튼 20개 × 라벨 40자)의 최악 본문이 약
   2.5KB다. 한글이 UTF-8 3바이트라 글자 수로 세면 3배 과소평가한다(처음에 800바이트로
   잘못 잡아 버퍼가 모자랐다). 4바이트 머리(`msg_id`/`조각번호`/`조각수`/`종류`)를
   붙여 쪼개 보내고 노드에서 다시 붙인다. 조각이 유실되면 3초 뒤 버리고 버퍼를 비운다.
2. **포트가 없다** — HTTP는 긴급 정지를 별도 포트로 분리했지만(단일 스레드 WebServer가
   실행 처리 중 새 연결을 못 받으므로) ESP-NOW엔 포트 개념이 없어 프레임 종류로
   구분한다. 수신이 콜백이라 실행 대기 중에도 즉시 도착한다 — 이 점은 폴링보다 낫다.
- WiFi 자격증명은 `include/config.h`에 하드코딩(개발 전용) — 프로비저닝 방식은
  아직 미정.
- `firmware/`(폰 앱 BLE 폴백 브릿지)와는 별개의 PlatformIO 프로젝트다. 역할이
  겹치지 않고(하나는 BLE, 하나는 WiFi+UART-to-RPi4), ESP32라는 칩만 같을 뿐
  물리적으로 다른 개체 여러 대가 된다 — 자세한 구분은 architecture.md 참고.

## 빌드/플래시 (PlatformIO)

```
pio run                 # 빌드만
pio run -t upload       # 빌드 + 플래시
pio device monitor      # 시리얼 로그 (WiFi 연결 상태, execute 처리 로그 등)
```

`config.h`의 `WIFI_SSID`/`WIFI_PASSWORD`를 실제 값으로 바꾼 뒤 빌드할 것.

## 빌드

PlatformIO Core로 컴파일한다. 보드가 없어도 `run`은 컴파일만 하므로 검증에 쓸 수 있다.

```powershell
# 설치 (한 번만). install.platformio.org는 DNS 레코드가 없어져 쓸 수 없다 -- PyPI로 받는다.
# PlatformIO Core는 Python 3.14를 아직 지원하지 않으므로 3.11로 전용 venv를 만든다.
py -3.11 -m venv "$env:USERPROFILE\.pio-venv"
& "$env:USERPROFILE\.pio-venv\Scripts\pip.exe" install platformio

# 빌드
& "$env:USERPROFILE\.pio-venv\Scripts\pio.exe" run -d <이 디렉터리>
```

## 검증 상태

**컴파일 검증됨** (2026-08-29, espressif32@7.0.1 = Arduino-ESP32 코어 3.x, 경고 0건).
`ESPNOW_ENABLED`가 0이어도 런타임 분기라 `espnow_transport.cpp`는 함께 컴파일된다.

**실기기 동작은 여전히 미검증.** 실제 ESP32 + RPi4를 붙여서 `pio run -t upload` 후
`curl -X POST http://<노드IP>:8080/execute -d '{"buttons":["시작"]}'`로
end-to-end 확인 필요.

> 첫 컴파일에서 오류 2종이 나왔다(`min(int, size_t)` 타입 불일치, const 문서에서
> 가변 `JsonArray` 추출). **둘 다 오늘 고친 부분이 아니라 원래 있던 것**이다 --
> 정적 검사로는 안 잡히는 종류라, 컴파일 없이 리뷰만 반복한 대가였다.

ESP-NOW 경로는 그 위에 확인할 것이 더 있다:

- 수신 콜백 시그니처는 코어 3.x의 `recv_info` 분기를 탄다(빌드로 확인). 2.x 분기는
  `platformio.ini`가 플랫폼 버전을 고정하지 않아 남겨둔 보험이다
- `ESPNOW_GATEWAY_MAC`을 실제 게이트웨이 MAC으로 채워야 한다(현재 전부 0). 게이트웨이
  부팅 로그의 `WiFi.macAddress()`로 확인
- 양쪽 `ESPNOW_CHANNEL`이 같아야 한다 — 다르면 조용히 아무것도 안 온다
- **조각 분할 왕복 검증**: 버튼 20개 × 긴 라벨로 250바이트를 넘겨 실제로 쪼개지고
  다시 붙는지. 여기가 HTTP엔 없던 유일한 신규 로직이라 제일 먼저 깨질 곳이다
- 조각 유실 시 3초 뒤 버퍼가 비워지고 다음 요청이 정상 처리되는지
- 게이트웨이가 요청에 실어 보낸 `rid`가 응답에 그대로 돌아오는지

- **정지 프레임이 대상 rid를 싣는다.** 앞 실행의 늦은 정지가 다음 실행을 끊지 않는지,
  그리고 대상 없는 정지(물리 E-STOP·앱 긴급 정지)는 무엇이 돌든 멈추는지
- **조각 송신이 콜백 기반**으로 바뀌었다. 노드 전원을 끈 채 실행 → 25초 마감이 아니라
  즉시 오류가 올라오는지(송신 콜백의 ESP_NOW_SEND_FAIL)

### 동시성 (8/29 2차 수리 이후 새로 생긴 확인 항목)

재조립 상태를 `RxState` + `portMUX_TYPE` 스핀락으로 바꿨다. 수신 콜백(Wi-Fi 태스크)과
`poll()`(Arduino loop 태스크)이 서로 다른 코어에서 돌 수 있어서 `volatile`로는 부족했다.
전부 **실기기에서만 확인 가능한 것들**이다:

- **실행이 블로킹하는 동안에도 정지 프레임이 통하는지.** 상태 기계가 정지까지 막으면
  이 프로젝트에서 가장 위험한 실패 모드가 된다 — 정지는 재조립을 거치지 않고
  `_handleFrame` 맨 앞에서 처리되게 해뒀지만, 실물로 눌러서 확인할 것
- **처리 중 도착한 프레임이 버려지는지**(로그 `frame dropped -- still handling`).
  버려지는 게 맞다: 한 번에 한 요청만 다루고, 덮어쓰면 실행 중인 버튼 라벨이 바뀐다
- **뒤늦은 조각·다른 msgId가 진행 중인 재조립을 뺏지 않는지**
  (로그 `assembling msg N` / `already handled`)
- `esp_now_register_recv_cb` 콜백이 **ISR이 아니라 Wi-Fi 태스크 컨텍스트**에서
  불리는지. 그 전제로 `portENTER_CRITICAL`을 쓴다(ESP-IDF v4+에서는 ISR판과 같은
  매크로라 문제없을 것으로 보지만, 실제 코어 버전에서 확인해야 한다)
- 임계구역 안에서 로그·핸들러·`delay()`를 부르지 않는다는 규칙이 유지되는지
  (스핀락이라 그동안 다른 코어가 멈춘다) — 코드 수정 시 함께 볼 것

