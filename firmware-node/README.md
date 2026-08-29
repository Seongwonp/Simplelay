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

## 검증 상태

이 펌웨어는 아직 **실기기로 빌드/플래시/검증되지 않았음** — Arduino/ESP32 API
지식을 바탕으로 작성했지만, PlatformIO 툴체인이 이 개발 환경에 없어서 컴파일
자체를 확인 못 했다. 실제 ESP32 + RPi4를 붙여서 `pio run -t upload` 후
`curl -X POST http://<노드IP>:8080/execute -d '{"buttons":["시작"]}'`로
end-to-end 확인 필요.

ESP-NOW 경로는 그 위에 확인할 것이 더 있다:

- 수신 콜백 시그니처가 Arduino-ESP32 코어 3.x에서 바뀌었다(`mac` → `recv_info`).
  양쪽 다 컴파일되게 `ESP_ARDUINO_VERSION_MAJOR`로 갈라뒀지만 **실제로 어느 코어로
  빌드되는지 확인 필요** (`platformio.ini`가 플랫폼 버전을 고정하지 않았다)
- `ESPNOW_GATEWAY_MAC`을 실제 게이트웨이 MAC으로 채워야 한다(현재 전부 0). 게이트웨이
  부팅 로그의 `WiFi.macAddress()`로 확인
- 양쪽 `ESPNOW_CHANNEL`이 같아야 한다 — 다르면 조용히 아무것도 안 온다
- **조각 분할 왕복 검증**: 버튼 20개 × 긴 라벨로 250바이트를 넘겨 실제로 쪼개지고
  다시 붙는지. 여기가 HTTP엔 없던 유일한 신규 로직이라 제일 먼저 깨질 곳이다
- 조각 유실 시 3초 뒤 버퍼가 비워지고 다음 요청이 정상 처리되는지
