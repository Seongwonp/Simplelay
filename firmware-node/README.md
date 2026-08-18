# firmware-node — 가전별 Act 노드의 ESP32 (RPi5 ↔ RPi4 무선 창구)

아키텍처: [../docs/architecture.md](../docs/architecture.md)의 "확정 아키텍처(다중 노드)" ·
프로토콜: [../docs/protocol.md](../docs/protocol.md)의 "UART 프로토콜 (RPi5 ↔ RPi4)" (이 노드가
그 프로토콜을 RPi4 쪽 그대로 이어받아 무선으로 중계한다)

- 가전마다 이 ESP32 + RPi4가 한 세트로 붙는다. 이 둘 사이(`ACT_UART_*`, `Serial2`)는
  유선 UART — RPi4가 이미 구현해둔 `execute`/`abort` → `result`/`error`/`alert`/
  `alert_cleared` 프로토콜(`rpi4/services/act_executor.py`)을 그대로 이어받는다.
- 이 노드와 중앙 허브(RPi5) 사이가 무선 구간. **지금은 개발용 HTTP만 구현**
  (`rpi/services/esp_node_controller.py`의 `EspNodeController`가 클라이언트,
  이 펌웨어가 `POST /execute` 서버) — 본선 데모용 ESP-NOW는 아직 없음. 인터페이스
  (`ExecuteHandler`/`AlertsHandler` 콜백)는 전송 방식과 무관하게 고정해뒀으니,
  ESP-NOW 구현체를 추가할 땐 `http_server.*` 옆에 `espnow_transport.*`를 새로
  만들고 `main.cpp`의 등록부만 바꾸면 된다.
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
