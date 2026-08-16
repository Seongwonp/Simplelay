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
{ "type": "command", "text": "우유 데우기", "source": "voice" }
{ "type": "confirm", "sequence_id": "seq_001", "approved": true }
{ "type": "emergency_stop" }
```

### ESP32 → 앱 상태

```json
{ "type": "suggestion", "sequence_id": "seq_001", "label": "우유 데우기", "steps": ["BT-08", "BT-03", "BT-05"] }
{ "type": "sensor", "current_ma": 320, "sound_db": 45, "status": "running", "completed_steps": 1 }
{ "type": "result", "sequence_id": "seq_001", "success": true }
```

---

## UART 프로토콜 (ESP32 ↔ RPi5)

- 보드레이트: 115200
- 포맷: JSON newline-delimited (`\n` 구분)

### ESP32 → RPi5

```json
{ "type": "intent", "text": "우유 데우기", "timestamp": 1723700000 }
{ "type": "sensor_log", "current_ma": 320, "sound_db": 45 }
```

### RPi5 → ESP32

```json
{ "type": "sequence", "id": "seq_001", "label": "우유 데우기", "buttons": ["BT-08", "BT-03", "BT-05"] }
{ "type": "abort" }
```

---

## UART 프로토콜 (RPi5 ↔ RPi4)

### RPi5 → RPi4

```json
{ "type": "execute", "sequence_id": "seq_001", "buttons": ["BT-08", "BT-03", "BT-05"] }
{ "type": "abort" }
```

### RPi4 → RPi5

```json
{ "type": "ack", "sequence_id": "seq_001", "step": "BT-08", "status": "done" }
{ "type": "result", "sequence_id": "seq_001", "success": true, "retry": 0 }
{ "type": "error", "sequence_id": "seq_001", "reason": "actuator_fail" }
```

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
