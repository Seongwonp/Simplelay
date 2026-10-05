# SimpleLay 통신 프로토콜 명세

## 디바이스 역할

| 디바이스 | 역할 | 통신 |
|----------|------|------|
| Flutter App | Sense — 음성/터치 명령 수집, 루틴 확인 UI | BLE (← ESP32) |
| ESP32 | UI·Sensor 노드 — BLE 브릿지, LED UI, 센서 중계 | BLE ↔ App, UART → RPi5 |
| Raspberry Pi 5 | Interpret — LLM 의도 해석, 시퀀스 생성, 패턴 DB | UART ← ESP32; RPi4로는 가전별 ESP32 노드 경유(HTTP/ESP-NOW)가 기본, UART 직결은 개발·대체 경로(9/29 정리) |
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
{ "type": "estop_ack" }
```

`estop_ack`(2026-10-05): 콘센트 모듈 비상정지로 RPi4가 **걸린**(`estop_latched`) 뒤, 사람이 버튼을 풀고 해제를
확인했다는 뜻(RPi5 `POST /stop/ack`). RPi4는 모듈 `status`로 버튼을 확인해 풀렸을 때만 모듈에 `estop_reset`을 보내고
자기 걸림을 푼다. 답은 `estop_state` 하나(아래 "콘센트 모듈 링크" 절).

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

**정지 버튼 대기·보관(2026-09-30, 실물 미검증).** `execute`의 `hold`는 **선택** 필드다. 가전에
정지 버튼(mm)과 보관 위치가 등록돼 있을 때만 RPi5가 싣는다.

```json
{ "type": "execute", "sequence_id": "seq_004", "buttons": ["즉석밥", "시작"], "targets": { … },
  "hold": { "appliance_id": "microwave", "stop_button": "취소", "stop_x_mm": 200.0, "stop_y_mm": 150.0,
            "stop_presses": 2, "park_x_mm": 20.0, "park_y_mm": 185.0, "press_ms": 150 } }
{ "type": "abort" }                      // 정지 버튼 위 대기 중이면 = 정지 버튼 누름(가전 정지)
{ "type": "abort", "scope": "drive" }    // 구동부만 멈춘다 — 정지 버튼을 누르지 않는다
{ "type": "verify_pass", "sequence_id": "v_001",
  "targets": [ { "button": "즉석밥", "x_mm": 100.0, "y_mm": 60.0 },
               { "button": "보관 위치", "x_mm": 20.0, "y_mm": 185.0, "kind": "park" } ] }
```

- `hold`: `stop_presses` 1~3, 좌표는 0 이상 유한한 수, 정지 좌표와 보관 좌표가 같으면 안 된다. 하나라도
  어긋나면 `targets`와 같은 규칙으로 **메시지 전체를 무시**한다.
- 시퀀스가 성공하고 가전 동작이 확인되면(L3 `operation_confirmed=true`, 또는 RPi4가 모의) RPi4는 Z를 올린 채
  정지 버튼 위로 가서 기다린다. 확인이 없으면 대기하지 않고 그 사실만 보고한다.
- 대기 중 `abort`(scope 생략 = `appliance`)는 정지 버튼을 `stop_presses`번 누른다. 같은 대기에서 두 번째 요청은
  다시 누르지 않는다. `scope:"drive"`는 모션만 멈추고 대기를 잠근다.
- 대기 중 새 `execute`가 오면 대기를 풀고 실행한다. 누르거나 보관 이동 중이면 `error`(`hold_busy`).
- `verify_pass`: 좌표 위를 차례로 **이동만** 한다(실제 어댑터는 `move_to`만). 실행·대기 중이면 `error`
  (`busy`·`hold_active`), 모션 부품이 없으면 `verify_unavailable`.

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
{ "type": "error", "sequence_id": "seq_005", "reason": "motion_not_ready", "detail": "모션 MCU 연결 확인 전(…)" }
```

`error`의 `motion_not_ready`(2026-09-29): `SIMPLELAY_MOTION_MODE=serial`에서 모션 MCU 연결 확인(`status` 성공) 전에
`execute`가 오면 RPi4는 누름을 시도하지 않고 바로 이것으로 거절한다. RPi4는 배경에서 1→2→4…30 s 간격으로 다시
연결한다. 옛 RPi5는 `reason`을 문자열로만 기록한다.

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
- ~~멈춘 버튼·눌림 개수는 여전히 프레임에 없다(`retry`만 집계).~~ 2026-09-29부터 아래 `button_results`로 보낸다.

`result` 확장 필드(2026-09-29 추가, G1·G2) — 옛 RPi5는 모르는 키를 무시한다.

```json
{ "type": "result", "sequence_id": "seq_004", "success": true, "retry": 1, "outcome": "success",
  "button_results": [
    { "button": "즉석밥", "ok": true, "attempts": 2, "layer": null,
      "corrections": [ { "retry_number": 1, "xy_adjustment_required": true, "increase_press_depth": true } ] },
    { "button": "시작", "ok": true, "attempts": 1, "layer": null, "corrections": [] } ],
  "operation_confirmed": true, "operation_detail": "모의 전력 센서 — 시작 확정 …",
  "operation_source": "mock", "execution_mode": "mock" }
```

| 필드 | 값 | 뜻 |
|---|---|---|
| `button_results` | 배열(실제로 돈 버튼만, 요청 시퀀스의 앞부분) | 버튼마다 `ok`·`attempts`(재시도 포함 누름 수, 1 이상)·`layer`(실패 층 `L1`/`L2`/`L3`, 성공이면 null)·`corrections`(재시도 누름마다의 정성 보정) |
| `operation_confirmed` | `true` / `false` / `null` | L3(가전 동작) 판정. **`null` = 판정기 없음(`SIMPLELAY_L3_MODE=off`) 또는 판정 전 정지** — "안 돌았다"(`false`)와 다르다 |
| `operation_detail` | 문자열 / `null` | 판정 사유 한 줄 |
| `operation_source` | `real` / `mock` / `null` | 판정 입력이 실물 전력 센서인가, 합성 파형(모의)인가 |
| `execution_mode` | `real` / `mock` / `unknown` | RPi4 모션 어댑터가 스스로 밝힌 실행 환경 |

- RPi5는 `button_results`를 **엄격하게** 읽는다: 버튼 이름이 요청 순서와 다르거나, 성공이라면서 전 버튼을
  덮지 않거나, 마지막이 아닌 칸이 실패면 **통째로 버리고** 종전처럼 집계 `retry`로 합성한다(성공이면 마지막
  버튼에 싣는다 — 어느 버튼이 재시도했는지는 모름).
- 재시도 수는 `/history`·CSV `retry_count`(버튼별 `attempts - 1`의 합), `/status`·SSE `last_retry_count`로
  나간다. 버튼 결과가 없으면(ThinQ 단계 등) `last_retry_count`는 `null`이다(0으로 지어내지 않음).
- L3는 `/status`·SSE `last_operation_confirmed`·`last_operation_source`·`last_operation_detail`,
  `/history`·CSV `operation_confirmed`로 나간다.
- **확인 수준(`confirmation`)을 `operation_confirmed`로 올리는 것은 `operation_confirmed=true` +
  `operation_source=real`뿐이다.** `mock`의 `true`는 `reported`로 남는다(합성 입력은 가열 근거가 아님).
  `source`가 없으면 `mock`으로 본다.
- RPi5의 UART 컨트롤러는 실행 환경을 모르므로(`unknown`) `execution_mode` 보고를 이번 실행의 모드로 쓴다.
  시뮬레이터처럼 스스로 `mock`이라고 밝힌 컨트롤러는 보고로 `real`이 되지 않는다.
- 시나리오 `cook_then_air`의 **일반(실물) 제안은 `execution_mode=real` + L3 실물 확인일 때만** 생긴다.
  모의 실행은 종전대로 시연 제안(`is_demo`)이다.
- RPi4 `SIMPLELAY_L3_MODE`: `off`(기본, `null`) · `mock`(합성 전력 파형, `SIMPLELAY_L3_MOCK_OUTCOME=
  confirmed|unconfirmed`) · `real`(CT·ADS1115 리더가 아직 없어 **기동 거절**). 시뮬레이터도 같은 변수를 읽는다.

`progress`(2026-09-29 추가, 선택) — RPi4가 **누름 시도의 단계마다** 보내는 진행 보고. **결과가 아니다.**
실모드 디지털 트윈(`GET /twin`)과 세션 기록(`SIMPLELAY_SESSION_LOG_PATH`)이 쓴다.

```json
{ "type": "progress", "sequence_id": "seq_004", "n": 1, "phase": "move", "button": "즉석밥", "step_index": 0,
  "attempt": 1, "target": { "x_mm": 10.0, "y_mm": 20.0 }, "correction": null,
  "execution_mode": "real", "t_monotonic_ns": 1234567890123 }
{ "type": "progress", "sequence_id": "seq_004", "n": 2, "phase": "press", "button": "즉석밥", "step_index": 0,
  "attempt": 1, "ok": true, "position": { "a_counts": 300, "b_counts": -100, "z_counts": 0,
  "x_mm": 10.0, "y_mm": 20.0, "source": "mcu_event", "t_monotonic_ns": 1234567990123 }, ... }
{ "type": "progress", "sequence_id": "seq_004", "n": 3, "phase": "verify", "button": "즉석밥", "attempt": 1, "pressed": false, ... }
{ "type": "progress", "sequence_id": "seq_004", "n": 4, "phase": "retry", "button": "즉석밥", "attempt": 2,
  "correction": { "retry_number": 1, "xy_adjustment_required": true, "increase_press_depth": true }, ... }
```

| phase | 언제 | 추가 필드 |
|---|---|---|
| `retry` | 재시도 누름 직전(보정 요청) | `correction`(정성 값, 거리 없음) |
| `move` | 누름 명령을 모션 어댑터에 넘기기 직전 | `target`(명령 좌표 mm, 없으면 null), `correction` |
| `press` | 어댑터가 반환(이동·Z 누름·복귀 끝) 또는 예외 | `ok`, `error`(실패 시), `position`(MCU 위치 보고가 있을 때만) |
| `verify` | L1 누름 검증 직후 | `pressed` |
| `accept` | L2 수용 확인 직후(검증기가 있을 때만) | `passed` |

- 공통: `n`(이 실행 안 순번 1..), `step_index`(시퀀스 칸), `attempt`(그 버튼의 누름 횟수), `execution_mode`
  (RPi4 어댑터 선언), `t_monotonic_ns`(**RPi4의** `time.monotonic_ns()` — 원시 기록기 `t_monotonic_ns`·모션 줄
  기록 `mono_ns=`와 같은 시각축).
- `position`은 모션 MCU가 엔코더 카운트를 보고했을 때만 있다(아래 MCU `position` 이벤트·`status` 응답).
  `x_mm`·`y_mm`는 RPi4에 기구 값이 있을 때만 계산하고, 없으면 null(카운트만). **지어내지 않는다.**
- 순서: 같은 실행의 `progress`는 모두 `result`보다 **먼저** 도착한다(RPi4가 결과 전에 쓴다).
- **하위 호환:** 옛 RPi5 `ActClient`는 `result`/`error`/`alert`/`alert_cleared` 밖의 `type`을 무시하고, ESP32
  노드 펌웨어(`firmware-node`)도 모르는 `type`을 무시한다(둘 다 코드 확인). 그래서 **기본 켜짐**이며
  RPi4 `SIMPLELAY_ACT_PROGRESS=0`으로 끈다. 새 RPi5도 `progress`로 실행을 끝내지 않는다 — 결과는 `result`뿐.
- 트래픽: 버튼 하나(재시도 없음)에 3줄, 한 줄 약 250~400바이트. 115200bps에서 누름당 수십 ms 미만.

RPi5 세션 기록(2026-09-29): RPi5 `ActClient`는 보내고 받은 **모든 줄**을 프레임 탭(`rpi/services/link_tap.py`)에
남긴다 — 링 버퍼(최근 2000개) + `SIMPLELAY_SESSION_LOG_PATH`가 있으면 JSONL 이어 쓰기(`{date}` 치환으로 하루 한
파일, `SIMPLELAY_SESSION_LOG_MAX_BYTES`·`_BACKUPS` 크기 회전). 한 줄 = `{"kind":"frame","n","t_wall",
"t_monotonic_ns"(RPi5 시각),"direction":"hub_to_act"|"act_to_hub","type","sequence_id","message"}`. 키 이름에
key·token·secret·password·authorization·cookie가 들어간 값과 설정된 API 키·개발자 토큰 문자열은 `[redacted]`.

정지 대기·확인 주행 보고(2026-09-30): 둘 다 `progress` 프레임이라 옛 RPi5는 무시한다. 결과가 아니다.

```json
{ "type": "progress", "sequence_id": "seq_004", "n": 3, "phase": "hold", "hold_state": "hovering_stop",
  "stop_outcome": null, "detail": "'취소' 위에서 Z를 올린 채 기다리는 중이에요", "stop_button": "취소",
  "stop_presses": 2, "presses_done": 0, "stop": {"x_mm": 200.0, "y_mm": 150.0},
  "park": {"x_mm": 20.0, "y_mm": 185.0}, "target": {…}, "park_reason": null, "appliance_id": "microwave",
  "probe_source": "mock", "sim_phase": "waiting_above_stop", "execution_mode": "mock", "t_monotonic_ns": 0 }
{ "type": "progress", "sequence_id": "v_001", "n": 2, "phase": "verify", "index": 0, "button": "즉석밥",
  "kind": "button", "status": "reached", "target": {"x_mm": 100.0, "y_mm": 60.0}, "detail": "…" }
{ "type": "verify_result", "sequence_id": "v_001", "ok": true,
  "targets": [ { "index": 0, "button": "즉석밥", "status": "reached", … } ], "execution_mode": "mock" }
```

- `hold_state`: `hovering_stop` | `stopping` | `parking` | `parked` | `fault` | `released` | null(대기 안 함).
- `stop_outcome`: `stopped`(누른 뒤 전력 하강 확인 — 모의에서는 모의 가전이 꺼짐) | `requested_unconfirmed`
  (확인 시간 안에 하강 없음, 전력 리더가 없으면 늘 이것) | `drive_fault`(구동부 이상으로 누르지 못함) | null.
- `verify` 단계 `status`: `moving` | `reached`(모션이 도착을 응답 — 버튼 위인지는 사람이 확인) | `failed` | `skipped`.

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
{ "id": 7, "cmd": "ping" }
{ "id": 8, "cmd": "limits" }
```

### MCU → RPi4

```json
{ "id": 1, "ok": true, "state": "idle", "homed": false, "a": 0, "b": 0, "z": 0, "alarm": null, "z_mode": "motor", "z_on_max_ms": null }
{ "id": 3, "ok": true }
{ "id": 3, "ok": false, "error": "stall" }
{ "event": "ready", "fw": "firmware-motion", "protocol": "line-json/v0", "reset": "poweron", "z_mode": "motor", "z_on_max_ms": null }
{ "event": "alarm", "reason": "limit", "z_retract": "not_needed" }
{ "event": "press_start" }
{ "event": "press_end" }
{ "id": 7, "ok": true }
{ "id": 8, "ok": true, "raw": { "x": false, "y": true, "z": false }, "debounced": { "x": false, "y": false, "z": false } }
```

- `ping`(heartbeat, 2026-09-29 추가): RPi4는 `home`·`move`·`press` 응답을 기다리는 동안
  `SIMPLELAY_MOTION_HEARTBEAT_MS`(기본 500ms, `0`/`off`면 끔)마다 자기 `id`를 단 `ping`을 보낸다. MCU는
  진행 중 동작을 건드리지 않고 바로 `ok`로 답한다. **받은 줄이면 무엇이든** MCU 워치독을 갱신하므로
  `firmware-motion`의 `HOST_WATCHDOG_MS`를 명령 기한(원점 복귀 최장 20 s 자리표시자)과 무관하게 2 s로 줄였다
  (`HOST_HEARTBEAT_MS`의 3배 미만이면 빌드 오류, 값은 `TODO(HW 실측)`). `ping` 응답은 `id`가 달라 진행 중
  명령의 응답으로 오인되지 않는다. 조회(`status`·`limits`)에는 `ping`을 섞지 않는다(워치독은 동작 중에만 돈다).
- `limits`(2026-09-29 추가): X·Y·Z 원점/리밋 입력의 즉시 판독(`raw`)과 디바운스 값(`debounced`). `true` = 활성
  (눌림·단선, `LIMIT_ACTIVE_LEVEL` 기준). 움직이지 않고 동작 중에도 바로 답한다. 첫날 배선 확인은 조그 CLI
  `limits` 명령으로 스위치를 하나씩 눌러 해당 축만 바뀌는지 본다.

- `position` 이벤트(2026-09-29 추가, 선택): `{ "event": "position", "a": 300, "b": -100, "z": 0 }` — 엔코더 카운트.
  `firmware-motion`은 이동·누름 중 `POSITION_EVENT_MS`(100ms)마다, 끝날 때 `ok` 응답 직전에 한 번 보낸다.
  RPi4 `SerialMotionClient.last_position`이 이것(또는 `status` 응답·`ok` 응답에 실린 정수 `a`·`b`)을 쥐고,
  기구 값이 있으면 mm로 바꿔 progress 프레임 `position`으로 RPi5에 넘긴다. 보내지 않는 MCU면 RPi5 트윈은
  "명령 기준 추정"으로 그린다.

- `ready` 이벤트(2026-09-29 추가): 펌웨어가 부팅을 마치면 한 줄 보낸다. `reset` = 직전 리셋 이유(`poweron`·`sw`·`panic`·
  `task_wdt`·`int_wdt`·`wdt`·`brownout`·`ext`·`other`). FireBeetle ESP32는 USB 시리얼 DTR/RTS로 자동 리셋되므로 RPi4는
  DTR/RTS를 내린 채(dsrdtr·rtscts 끔) 포트를 열고, `connect()`에서 부트 로그(JSON 아닌 줄)를 버리며 이 줄을 기다리거나
  `status`를 backoff(0.2 s→1 s)로 `SIMPLELAY_MOTION_CONNECT_TIMEOUT_S`(기본 5 s)까지 재시도한다. 동작 중에 `ready`가
  오면 MCU가 재시작한 것 — 진행 중 명령은 실패, 재홈 전까지 이동·누름 거절. 조회 중이면 같은 요청을 새 `id`로 다시 보낸다.
- `alarm`의 `z_retract`(2026-09-29 추가): 알람 때 Z가 눌린 쪽이면 MCU가 XY는 제동하고 Z만 위로 한도(`Z_RETRACT_MS`)
  안에서 올린 뒤 끊는다. 값 `not_needed`·`done`·`timeout`·`stalled`·`skipped`(워치독 `host_timeout` 부류·원점 모름 —
  즉시 차단)·`stopped`(후퇴 중 `stop`). 후퇴가 필요한 알람은 이벤트와 `ok:false`가 후퇴 뒤에 온다.
- `z_mode`(2026-10-05 추가): `ready`·`status`에 Z 누름 방식 `motor`|`solenoid`(펌웨어 빌드 플래그 `Z_MODE`). 솔레노이드는
  `duration` 누름만 받는다 — 켜짐 = `drive_ms + dwell_ms`, 상한(`SOLENOID_ON_MAX_MS`)을 넘으면 `soft_limit`, 직전 꺼짐 뒤
  냉각 시간 안이면 `z_cooldown`, `depth`는 `z_unsupported`. 솔레노이드의 `status`·`position` `z`는 켜짐 1/꺼짐 0, `limits` `z`는
  항상 `false`, 알람 때는 즉시 끈다(`z_retract` `done`|`not_needed`). RPi4는 `z_mode`가 `solenoid`면 `depth` 누름을 보내기 전에
  거절하고, `z_unsupported`·`z_cooldown`은 위치를 잃지 않은 거절로 다뤄 재홈을 요구하지 않는다. `z_mode`가 없는 MCU면 제한하지 않는다.
- 2026-10-05 리뷰 L6: `ready`·`status`의 `z_on_max_ms`는 솔레노이드 한 번 켜짐 상한(`SOLENOID_ON_MAX_MS`, 모터면 `null`) —
  RPi4는 `drive_ms + dwell_ms`가 이것을 넘는 누름을 보내기 전에 거절한다. `z_cooldown` 거절은
  `{"id":…,"ok":false,"error":"z_cooldown","retry_ms":N}`(남은 냉각 시간). RPi4는 그만큼(+50 ms, 상한 2 s — 넘으면 바로 거절)
  기다렸다가 누름을 **한 번** 다시 보낸다(`retry_ms`가 없으면 `SIMPLELAY_MOTION_Z_COOLDOWN_BACKOFF_MS`, 기본 500).
  알람 이벤트 없이 온 `soft_limit` 거절 응답은 움직이기 전 범위 검사라 알람·재홈으로 다루지 않는다(움직이다 넘으면 `alarm`
  이벤트가 먼저 온다).
- 위치 일치 검사(2026-10-05, RPi4 선택): `SIMPLELAY_MOTION_POSITION_TOLERANCE_COUNTS`(기본 꺼짐, 측정 필요)를 주면 `move`의
  `ok` 뒤 그 요청 동안 받은 `position`(`a`·`b`)이 명령과 허용 오차 넘게 다르거나 보고가 없을 때 이동을 실패로 끝내고 재홈 전까지
  거절한다. 엔코더가 모터 축에 있어 풀리–벨트 미끄럼은 이것으로 보이지 않는다 — MCU가 목표에 못 닿고 `ok`를 보낸 경우를 잡는다.
- 응답은 동작이 **끝난 뒤** 보낸다(홈 완료·도착·Z 복귀). `id` 없는 줄은 자발 이벤트다.
- `alarm` 이벤트나 `ok:false`를 받으면 RPi4는 해당 동작을 실패로 끝내고 알람 상태로 둔다.
- 기한 초과 시 RPi4는 `stop`을 보내고 위치를 믿지 않는다(재홈 전까지 이동·누름 거절).
- `stop`은 다른 스레드에서 즉시 보낸다. 보낸 것은 '명령 전송'까지이며, MCU 정지 보고·물리 정지 확인은
  별도 단계로 실물에서 재야 한다. MCU는 호스트 줄이 `HOST_WATCHDOG_MS`(2 s 자리표시자) 동안 없으면 스스로 멈추고
  `alarm`(`host_timeout`) 이벤트 뒤 대기 명령에 `ok:false`를 보낸다(실측 전).
- 수치 예시는 형식 설명용이다. 카운트 값은 시험용 임의 기구 값으로 계산한 것이며 실물 값이 아니다.

---

## 콘센트 모듈 링크 (RPi4 ↔ ESP32 콘센트 모듈) — **컴파일·가짜 출력 수준, 실물 미검증**

2026-10-05 추가. 9/30 하드웨어 방향 확정(ESP32 = 콘센트 모듈, CT 전력 → RPi4 직접, 물리 비상정지는 모듈의
버튼과 가전 전원 릴레이)에 맞춘 규약이다. 펌웨어 `firmware-outlet/`, 호스트 `rpi/verifier/outlet.py`, 실행 가능한
기준 `rpi/tools/fake_outlet.py`, 명령 표 `firmware-outlet/protocol_table.json`(`rpi/tests/test_outlet_protocol.py`가
셋을 대조). CT·릴레이·버튼을 붙여 돌려 본 적이 없다.

- 포맷: 줄 단위 JSON(`\n`), USB 시리얼 **115200 고정**(`SIMPLELAY_OUTLET_BAUD`를 같은 값으로). 모션 MCU 링크와 같은 전송 계층.
- 프로토콜 이름 `line-json/outlet-v0`. 요청 `id`로 응답을 짝짓는다. `id` 없는 줄은 자발 이벤트.

### RPi4 → 모듈

```json
{ "id": 1, "cmd": "status" }
{ "id": 2, "cmd": "ping" }
{ "id": 3, "cmd": "relay_on" }
{ "id": 4, "cmd": "relay_off" }
{ "id": 5, "cmd": "estop_reset" }
{ "id": 6, "cmd": "rate", "hz": 10 }
```

### 모듈 → RPi4

```json
{ "id": 1, "ok": true, "relay": "off", "estop": false, "button": false, "rate_hz": 10, "ct": "ads1115", "cal": "placeholder", "uptime_ms": 5230 }
{ "id": 3, "ok": false, "error": "estop_latched" }
{ "event": "ready", "fw": "firmware-outlet", "protocol": "line-json/outlet-v0", "reset": "poweron", "relay": "off", "ct": "ads1115", "ct_ok": true, "estop": false }
{ "event": "power", "t_ms": 5300, "seq": 52, "watts": 3.1, "irms_a": 0.014, "vrms_est": 220.0, "ct_mv": 0.47, "n": 80, "err": 0, "relay": "on" }
{ "event": "estop", "source": "button", "t_ms": 9120, "relay": "off" }
{ "event": "fault", "reason": "ct_init" }
```

- `power`: 기본 10 Hz(`rate`, 1~20). `watts`는 **추정값** = CT 실효 전류(보정 배율·잡음 바닥 적용) × `vrms_est`
  (설정 상수, 측정 아님) × 설정 역률. 보정 값은 전부 자리표시자(`status.cal = "placeholder"`) — 절대값은 근거가 아니다.
  L3는 기준선 대비 변화로 판정한다. CT 초기화가 실패하면 `fault`(`ct_init`)만 보내고 `power`를 내지 않는다(0 W를 지어내지 않는다).
- 시각: RPi4는 모듈 `t_ms`를 호스트 단조 시각에 맞춰(`anchor = 수신 시각 − t_ms/1000`) 샘플 시각으로 쓴다. 다시 맞추는 것은
  첫 샘플, `ready` 배너 뒤 첫 샘플, `seq`가 작은 값(≤5)으로 되돌아간 샘플뿐이다. 그 밖에 `t_ms`·`seq`가 늘지 않은 줄(중복·
  순서 뒤바뀜)은 버리고 신선도도 갱신하지 않는다(2026-10-05 리뷰 L1).
- 창 품질(2026-10-05 리뷰 M1): 모듈은 창 샘플이 기대치의 `CT_MIN_WINDOW_PCT`(50 %) 미만인 창을 보고하지 않고 `seq`만 늘린다.
  RPi4는 `n` < `SIMPLELAY_OUTLET_MIN_SAMPLES`(기본 20) 또는 `err/n` > `SIMPLELAY_OUTLET_MAX_ERR_RATIO`(기본 0.1)인 줄, `n`이
  없는 줄을 버린다(신선한 샘플로 세지 않는다). 기준값은 측정 필요.
- 끊김: 마지막 `power` 수신 뒤 `SIMPLELAY_OUTLET_STALE_MS`(기본 1000)가 지나면 RPi4 센서는 `PowerSensorStale`을 던진다 →
  L3는 'L3 판정 불가 — 전력 센서를 읽지 못함'으로 안전 정지(자동 재입력 없음).
- 생존(2026-10-05 리뷰 M2): RPi4는 어떤 줄이든(ping·status 응답 포함) 받은 시각을 남기고, `SIMPLELAY_OUTLET_OFFLINE_MS`
  (기본 3000) 넘게 아무것도 받지 못하면 모듈 무응답으로 본다 — 그동안 `execute`·`verify_pass`는 `error`(`outlet_offline`)로
  거절한다(물리 비상정지 이벤트를 볼 수 없으므로). 읽기에서 포트 오류(USB 빠짐)가 나면 0.5→1→2→4→5 s 간격으로 다시 연다.
  `SIMPLELAY_OUTLET_STATUS_POLL_MS`(기본 2000)마다 `status`를 물어 `estop` 표시를 반영한다(이벤트 줄을 잃어도 걸림을 놓치지 않게).
- **릴레이 기본 = 꺼짐(fail-safe).** 부팅·재부팅 뒤 가전 전원은 끊긴 채이고 `relay_on`이 있어야 켠다
  (`SIMPLELAY_OUTLET_RELAY_ON_START=1`이면 RPi4가 시작 때 보낸다. 기본은 보내지 않는다).
- **물리 비상정지**: 버튼(NC, 눌림·단선 = 활성)이 연속 `ESTOP_TRIP_SAMPLES` 활성이면 모듈이 **그 자리에서** 릴레이를 연다
  (호스트·시리얼과 무관). 그 뒤 `estop` 이벤트를 한 번 보낸다. 걸린 동안 `relay_on`은 `estop_latched`, 버튼이 눌린 채면
  `estop_reset`은 `estop_active`. 해제해도 릴레이는 꺼진 채 — 다시 켜려면 `relay_on`.
- **걸림 보존**(2026-10-05 리뷰 H2): 모듈은 걸림을 RTC 메모리(리셋·워치독·패닉을 넘어 남음)와 NVS(전원이 꺼져도 남음)에
  적어 두고, 재부팅 뒤에도 걸린 채로 시작한다(릴레이 꺼짐, `relay_on` 거절). `ready`와 `status`의 `estop`이 true다.
  RPi4는 이것을 받으면 자기도 걸린다. `SIMPLELAY_OUTLET_RELAY_ON_START=1`이어도 걸려 있거나 확인하지 못하면 `relay_on`을 보내지 않는다.
- RPi4는 `estop`을 받으면(또는 `ready`·`status`가 걸림을 보고하면) **걸린다**(`estop_latched`): 실행 중 시퀀스를 `abort`와
  같은 정지 경로로 멈추고(모션 MCU `stop`도 즉시), 정지 버튼 대기 중이면 구동부만 멈춘다(전원이 이미 끊겨 정지 버튼을 누르지
  않는다). 걸린 동안 `execute`·`verify_pass`는 `{"type":"error","reason":"estop_latched","detail":…}`로 거절한다 — 쉬는 중에
  걸렸어도, 정지 대기 해제를 기다리는 사이에 걸렸어도 같다. RPi5에는 `{"type":"alert","kind":"outlet_estop","source":…}`와
  `{"type":"estop_state","latched":true,"source":…,"reason":null,"detail":…}`.
- 해제: RPi5 `POST /stop/ack` → `{"type":"estop_ack"}` → RPi4가 모듈 `status`로 버튼을 확인한다. 버튼이 눌린 채면
  `estop_reset`을 보내지 않고 `estop_state {latched:true, reason:"estop_button_pressed"}`, 모듈이 답하지 않으면
  `reason:"outlet_unreachable"`, 확인 중 다시 걸리면 `estop_retriggered`. 풀리면 `estop_state {latched:false}` — 가전 릴레이는
  꺼진 채다(켜기는 별도).
- RPi5: `GET /status`의 `estop_latched`·`estop_detail`, 내장 가전 준비 상태(`GET /appliances`)의 `can_execute=false`와 사유
  "비상정지가 걸려 있어요 — …", 실행 요청은 412(준비 안 됨). `POST /stop/ack`는 다른 제어 API와 같은 인증을 탄다
  (응답 `{ok, latched, reason, detail}`; 걸림을 보고하지 않는 실행기면 409, RPi4 무응답이면 504).
- 호스트 침묵: 모듈은 기본적으로 호스트가 조용해도 릴레이를 두고(`HOST_SILENCE_RELAY_OFF 0`), 1로 빌드하면 `HOST_SILENCE_MS`
  뒤 릴레이를 열고 `host_timeout`을 보낸다. RPi4는 `ping`을 `SIMPLELAY_OUTLET_HEARTBEAT_MS`(기본 1000)마다 보낸다.

### RPi4 → RPi5 추가 프레임

- `progress {phase:"power_tail", power_tail:{status, tail_s, tail_mean_w, tail_max_w, pre_baseline_w, post_baseline_w,
  finished_at_s, returned_at_s, band_w, samples, source, detail}, operation_source}` — L3가 동작 시작을 확인한 실행 뒤,
  완료 판정(전력 ≤ `off_max_w`가 `off_confirm_s` 유지) → 대기 전력 띠로 복귀하기까지의 잔여 전류 꼬리(피드백 ③). 기록용이며
  판정이 아니다. 정의·기준값은 `rpi/verifier/power_tail.py`(`SIMPLELAY_TAIL_*`, 전부 측정 필요). RPi5 `ActClient.last_power_tail`.
  원시 기록기(`SIMPLELAY_RECORDER_PATH`)에는 `event=power_tail` 행과 `tail_*`·`pre/post_baseline_w` 열로 남는다.

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
