# SimpleLay 통신 프로토콜 명세

## 디바이스 역할

| 디바이스 | 역할 | 통신 |
|----------|------|------|
| Flutter App | Sense — 음성/터치 명령 수집, 루틴 확인 UI | BLE (← ESP32) |
| ESP32 | UI·Sensor 노드 — BLE 브릿지, LED UI, 센서 중계 | BLE ↔ App, UART → RPi5 |
| Raspberry Pi 5 | Interpret — LLM 의도 해석, 시퀀스 생성, 패턴 DB | UART ← ESP32, RPi4와는 별도 UART(확정) |
| Raspberry Pi 4 | Act — 액추에이터 제어, 폐루프 검증 | UART ← RPi5, GPIO |

---

## BLE 프로토콜 (App ↔ ESP32)

```
Service UUID    : 0000FFE0-0000-1000-8000-00805F9B34FB
Characteristic  : 0000FFE1-0000-1000-8000-00805F9B34FB
```

### 앱 → ESP32 명령

```json
{ "type": "command", "text": "즉석밥 데우기", "source": "voice" }
{ "type": "confirm", "sequence_id": "seq_001", "approved": true }
{ "type": "emergency_stop" }
```

### ESP32 → 앱 상태

```json
{ "type": "suggestion", "sequence_id": "seq_001", "label": "즉석밥 데우기", "steps": ["BT-08", "BT-05"] }
{ "type": "sensor", "current_ma": 320, "sound_db": 45, "status": "running", "completed_steps": 1 }
{ "type": "result", "sequence_id": "seq_001", "success": true }
```

---

## UART 프로토콜 (ESP32 ↔ RPi5)

- 보드레이트: 115200
- 포맷: JSON newline-delimited (`\n` 구분)

### ESP32 → RPi5

```json
{ "type": "intent", "text": "즉석밥 데우기", "timestamp": 1723700000 }
{ "type": "sensor_log", "current_ma": 320, "sound_db": 45 }
```

### RPi5 → ESP32

```json
{ "type": "sequence", "id": "seq_001", "label": "즉석밥 데우기", "buttons": ["BT-08", "BT-05"] }
{ "type": "abort" }
```

---

## UART 프로토콜 (RPi5 ↔ RPi4)

### RPi5 → RPi4

```json
{ "type": "execute", "sequence_id": "seq_001", "buttons": ["BT-08", "BT-03", "BT-05"] }
{ "type": "abort" }
{ "type": "inject_failure", "button_index": 0, "attempts": 1 }
{ "type": "clear_failure" }
```

`execute`의 `targets`는 **선택** 필드다(2026-09-28). 보정(`PUT /appliances/{id}/calibration`)으로
갠트리 좌표가 기록된 버튼만 싣는다. 좌표가 하나도 없으면 키 자체를 넣지 않는다 —
종전 `execute` 줄과 바이트까지 같다.

```json
{ "type": "execute", "sequence_id": "seq_002", "buttons": ["즉석밥", "시작"],
  "targets": { "즉석밥": { "x_mm": 42.0, "y_mm": 18.5 },
               "시작":   { "x_mm": 60.0, "y_mm": 120.0, "press_ms": 150 } } }
```

- 키는 `buttons`에 있는 이름이어야 한다. `x_mm`·`y_mm`는 유한한 수, `press_ms`는 선택(1 이상 정수).
- 하나라도 어긋나면(시퀀스에 없는 버튼, 한쪽 좌표만, 문자열·NaN) RPi4는 **메시지 전체를 무시**한다 —
  틀린 좌표 하나가 엉뚱한 버튼을 누르게 하므로 일부만 받아들이지 않는다.
- RPi4가 mock 모션이면 좌표는 기록만 되고 동작은 종전과 같다. 실제 모션 어댑터(`SIMPLELAY_MOTION_MODE=serial`)는
  좌표 없는 버튼이 **하나라도** 있으면 아무것도 누르기 전에 거절하고 `error`(`actuator_fail`)로 답한다.
- 수치 예시는 형식 설명용이며 실물 좌표가 아니다.

`inject_failure`/`clear_failure`는 리허설 장치(POST/DELETE /demo/inject-failure)의
UART 전달판 — 검증이 RPi4에서 일어나는 실기기 구성에서도 "일부러 실패시켜도
스스로 재시도" 장면을 같은 API로 연출한다. abort처럼 응답 없는 단방향.

### RPi4 → RPi5

```json
{ "type": "ack", "sequence_id": "seq_001", "step": "BT-08", "status": "done" }
{ "type": "result", "sequence_id": "seq_001", "success": true, "retry": 0, "outcome": "success" }
{ "type": "result", "sequence_id": "seq_002", "success": false, "retry": 0, "outcome": "stopped" }
{ "type": "result", "sequence_id": "seq_003", "success": false, "retry": 2, "outcome": "safety_stop" }
{ "type": "error", "sequence_id": "seq_001", "reason": "actuator_fail" }
```

`result`의 `outcome`(2026-09-29 추가) — **어떻게 끝났는지**. 예전에는 정지 요청으로 멈춘 것과
검증 실패로 안전 정지한 것이 모두 `success=false` 하나라 RPi5가 둘을 가를 수 없었다.

| outcome | 뜻 | success |
|---|---|---|
| `success` | 시퀀스를 끝까지 성공 | `true` |
| `stopped` | `abort`(긴급 정지)를 받아 버튼·재시도 경계에서 멈춤. 실패가 아니다 | `false` |
| `safety_stop` | 재시도 소진·L2/L3 불확인·센서 불가로 RPi4가 스스로 안전 정지 | `false` |
| `failed` | 그 밖의 실패(이유 불명) | `false` |

- **하위 호환:** `success`는 그대로 보낸다. 옛 RPi5는 `outcome`을 무시한다. `outcome`이 없는 옛 RPi4의
  `success=false`는 RPi5가 `failed`로 적는다 — 정지로 추측하지 않는다.
- 모르는 값이거나 `success`와 모순(`success=true`인데 `stopped` 등)이면 RPi5는 `outcome`을 버리고
  `success`만 믿는다.
- RPi5는 이 값을 `/status`·SSE `status` 이벤트의 `last_outcome`, `/history`·CSV의 `outcome`으로 내보낸다.
  `last_status`(`succeeded`/`safety_stopped`/`failed`)는 옛 클라이언트용으로 종전 값을 유지한다.
- **물리 정지 확인이 아니다.** 실행 루프가 멈춘 이유일 뿐, 모터가 실제로 멈췄다는 보고는 별도다.
- 멈춘 버튼·눌림 개수는 여전히 프레임에 없다(`retry`만 집계).

`result`/`error`/`ack`는 모두 RPi5가 보낸 `execute`에 대한 응답이다. 아래 두 개는
유일하게 RPi5가 요청하지 않아도 RPi4가 스스로 보내는 메시지 — 마이크가 물려 있는
RPi4 쪽에서 화재/가스 경보음을 감지했을 때 즉시 푸시된다(승인 절차 없음, 기존
"제안"과는 다른 클래스). `DangerSoundMonitor` → `ActExecutor.report_danger_sound()`가
엣지 트리거로 보낸다 — 같은 상태가 계속되는 동안은 재전송하지 않는다.

```json
{ "type": "alert", "kind": "danger_sound", "band_energy_ratio": 0.77, "mean_period_seconds": 0.42 }
{ "type": "alert_cleared", "kind": "danger_sound" }
```

---

## 모션 MCU 링크 (RPi4 ↔ 모션 MCU) — 뼈대, **실물 미검증**

2026-09-28 추가. 제어 MCU·펌웨어·통신 방식(UART/USB)이 아직 미정이라, RPi4 쪽 어댑터
(`rpi/controller/serial_motion.py`)가 기대하는 **제안 계약**이다. MCU 펌웨어가 정해지면 이 절과
어댑터를 함께 고친다. 메모리 파이프와 가짜 MCU로만 시험했다.

- 포맷: 줄 단위 JSON(`
`). 보드레이트는 펌웨어가 정한다(기본값 없음, `SIMPLELAY_MOTION_BAUD`).
- G-code 대신 JSON: 다른 링크와 같은 도구를 쓰고, 엔코더 DC 모터용 필드(모터별 카운트·누름 방식·오류 코드)를
  비표준 G-code 확장 없이 싣는다. 요청 `id`로 응답을 짝지어 시간 초과로 버린 요청의 늦은 응답을 걸러낸다.
- 좌표 변환은 RPi4가 한다: XY mm → CoreXY 벨트 ΔA·ΔB → 엔코더 카운트(`rpi/controller/kinematics.py`).
  MCU는 모터별 목표 카운트를 받는다. `x_mm`·`y_mm`는 MCU 측 리밋 검사·로그용으로 함께 보낸다.
- Z는 변환 기구가 미정이라 mm를 쓰지 않는다 — Z 엔코더 카운트(`depth`) 또는 구동 시간(`duration`).

### RPi4 → MCU

```json
{ "id": 1, "cmd": "status" }
{ "id": 2, "cmd": "home" }
{ "id": 3, "cmd": "move", "a": 500, "b": 167, "x_mm": 10.0, "y_mm": 5.0 }
{ "id": 4, "cmd": "press", "mode": "depth", "z_counts": 40, "dwell_ms": 100 }
{ "id": 5, "cmd": "press", "mode": "duration", "drive_ms": 120, "dwell_ms": 100 }
{ "id": 6, "cmd": "stop" }
```

### MCU → RPi4

```json
{ "id": 1, "ok": true, "state": "idle", "homed": false, "a": 0, "b": 0, "z": 0, "alarm": null }
{ "id": 3, "ok": true }
{ "id": 3, "ok": false, "error": "stall" }
{ "event": "alarm", "reason": "limit" }
{ "event": "press_start" }
{ "event": "press_end" }
```

- 응답은 동작이 **끝난 뒤** 보낸다(홈 완료·도착·Z 복귀). `id` 없는 줄은 자발 이벤트다.
- `alarm` 이벤트나 `ok:false`를 받으면 RPi4는 해당 동작을 실패로 끝내고 알람 상태로 둔다.
- 기한 초과 시 RPi4는 `stop`을 보내고 위치를 믿지 않는다(재홈 전까지 이동·누름 거절).
- `stop`은 다른 스레드에서 즉시 보낸다. 보낸 것은 '명령 전송'까지이며, MCU 정지 보고·물리 정지 확인은
  별도 단계로 실물에서 재야 한다. MCU는 호스트 신호가 끊기면 스스로 멈춰야 한다(워치독 주기는 측정 필요).
- 수치 예시는 형식 설명용이다. 카운트 값은 시험용 임의 기구 값으로 계산한 것이며 실물 값이 아니다.

---

## 버튼 맵 JSON 포맷

`docs/button-maps/<appliance>.json` 에 가전별 저장.

```json
{
  "appliance": "microwave",
  "model": "generic",
  "grid": { "rows": 4, "cols": 3 },
  "buttons": [
    { "id": "BT-01", "label": "10초", "x": 0, "y": 0 },
    { "id": "BT-02", "label": "30초", "x": 1, "y": 0 },
    { "id": "BT-05", "label": "시작",  "x": 2, "y": 3 },
    { "id": "BT-06", "label": "취소",  "x": 1, "y": 3 }
  ]
}
```
