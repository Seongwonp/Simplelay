# firmware — ESP32 BLE↔UART 브릿지

명세: [../docs/esp32-firmware-spec.md](../docs/esp32-firmware-spec.md) · 재사용 경계: [../docs/reuse-boundary.md](../docs/reuse-boundary.md)

- ESP32: 폰 앱 BLE ↔ RPi5 UART 사이의 순수 릴레이 (GRBL 아님 — 그 설계는 폐기됨,
  자세한 사유는 [../docs/actuator-design.md](../docs/actuator-design.md))
- 안전: 물리 E-STOP 인터럽트 → RPi5에 `abort` 즉시 전달. 재시도 하드 리밋·Z 누름 깊이
  상한 등 나머지 안전 계층은 폐루프 컨트롤러(RPi4) 쪽 책임 — [../docs/closed-loop-design.md](../docs/closed-loop-design.md)

## ESP-NOW 게이트웨이 겸용 (본선 데모)

이 보드는 폰 BLE 폴백 브릿지이면서 **ESP-NOW 게이트웨이 역할을 겸한다**.

이유: ESP-NOW는 ESP32 라디오끼리만 통하는데 RPi5에는 그 라디오가 없다. 이미 UART로
붙어 있는 이 보드가 대신 쏴주면 전용 보드를 추가하지 않아도 된다(팀 결정).

```
RPi5 --UART--> (이 보드) --ESP-NOW--> 노드 ESP32 --UART--> RPi4
```

`include/config.h`의 `ESPNOW_GATEWAY_ENABLED`로 켠다(기본 꺼짐). 전용 보드로 분리하고
싶어지면 이 값만 0으로 두고 새 보드에서 1로 켜면 된다 — 나머지 코드는 그대로다.

### 프로토콜 (RPi5 ↔ 이 보드, 기존 UART JSON 라인에 얹음)

| 방향 | 메시지 |
|---|---|
| RPi5 → | `{"type":"node_execute","sequence_id":…,"mac":…,"buttons":[…]}` |
| RPi5 → | `{"type":"node_stop","mac":…}` |
| → RPi5 | `{"type":"node_result","sequence_id":…,"success":…,"retry":…}` |
| → RPi5 | `{"type":"node_error","sequence_id":…,"error":…}` |

**같은 UART에 BLE 브릿지 트래픽이 함께 흐른다.** RPi5 쪽
(`rpi/services/espnow_node_controller.py`)이 sequence_id로 자기 줄만 골라낸다.

### 겸용에서 주의할 점

- **BLE와 Wi-Fi 라디오를 함께 쓴다**(ESP32 coexistence). 지원되는 구성이지만
  시간 분할이라 지연에 지터가 생길 수 있다. NimBLE이라 RAM 여유는 있는 편
- 노드와 `ESPNOW_CHANNEL`·프레임 형식이 **정확히 같아야** 한다
  (`firmware-node/include/config.h`와 짝)
- 대기 시간은 계층마다 다르게 잡혀 있다 — 아래쪽이 먼저 포기해야 위쪽이 추측 대신
  실제 오류를 받는다: 노드(20s+6s/버튼) < 게이트웨이(25s+6s/버튼) < RPi5(30s+6s/버튼)

### 검증 상태

**미검증** — 이 개발 환경에 PlatformIO가 없어 컴파일조차 확인하지 못했다.
실기기에서 확인할 것:

- BLE 광고와 ESP-NOW가 실제로 동시에 도는지 (coexistence — 겸용의 유일한 진짜 위험)
- 부팅 로그의 `WiFi.macAddress()`를 노드의 `ESPNOW_GATEWAY_MAC`에 넣었는지
- 양쪽 채널이 같은지 (다르면 조용히 아무것도 안 온다)
- 버튼 20개 × 긴 라벨로 250바이트를 넘겨 **조각 분할 왕복**이 되는지
- 노드 전원을 끈 채 실행 → 게이트웨이가 RPi5보다 먼저 `node_error`를 주는지
- 대기 중인 `rid`와 다른 응답이 버려지는지(로그 `dropping node response for ...`)

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

